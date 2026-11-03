"""
Profit-rate curve construction.

A zero curve stores continuously compounded zero profit rates at
pillar maturities, measured in years from an anchor date. Rates are
linearly interpolated between pillars and held flat outside them.
`bootstrap` builds the curve from market instruments: discount
(zero-coupon) sukuk pin their own pillar directly, and coupon sukuk
are added shortest-first, each new pillar solved from the instrument
price with earlier cash flows discounted on the curve built so far.
`calibration_report` runs the same calibration and reports the
solve status and repricing residual of every instrument.

Two conventions are stated rather than left implicit:

- The discount factor at the anchor is exactly 1: a cash flow on
  the anchor date is worth its amount. The zero *rate* at t = 0 is
  not defined by the pillar set, and `zero_rate` rejects t <= 0.
- Interpolated forwards are not constrained to be positive. A
  steeply falling segment of zero rates implies negative forwards
  over that segment, and `forward_rate` reports them as they are.
  The curve is an interpolation of quoted zeros, not a positive-rate
  term-structure model; constraining it would make genuinely
  falling published curves (the IILM curve falls from 6m to 12m)
  impossible to represent.
"""

using Dates

"""
    ZeroCurve(anchor, pillars, zeros)

`pillars` are year fractions from `anchor`: finite, positive and
strictly increasing (a repeated pillar would make the interpolation
divide by the zero gap between the two). `zeros` are continuously
compounded annual rates and must be finite; they may repeat, since
a flat segment is a legitimate shape.
"""
struct ZeroCurve
    anchor::Date
    pillars::Vector{Float64}
    zeros::Vector{Float64}

    function ZeroCurve(anchor::Date, pillars::Vector{Float64},
                       zeros::Vector{Float64})
        length(pillars) == length(zeros) ||
            throw(ArgumentError("pillars and zeros must match in length"))
        all(isfinite, pillars) ||
            throw(ArgumentError("pillars must be finite year fractions"))
        all(p -> p > 0, pillars) ||
            throw(ArgumentError("pillars must be positive year fractions"))
        all(pillars[i] < pillars[i + 1] for i in 1:(length(pillars) - 1)) ||
            throw(ArgumentError("pillars must be strictly increasing"))
        all(isfinite, zeros) ||
            throw(ArgumentError("zero rates must be finite"))
        return new(anchor, pillars, zeros)
    end
end

"""
    zero_rate(curve, t)

Continuously compounded zero rate at year fraction `t`: linear
interpolation between pillars, flat extrapolation beyond them.
`t` must be positive: the rate at t = 0 is not defined by the
pillar set (the discount factor there is defined instead, and
is exactly 1).
"""
function zero_rate(curve::ZeroCurve, t::Real)
    t = float(t)
    t <= 0 && throw(ArgumentError("t must be positive"))
    p, z = curve.pillars, curve.zeros
    isempty(p) && throw(ArgumentError("curve has no pillars"))
    t <= p[1] && return z[1]
    t >= p[end] && return z[end]
    i = searchsortedlast(p, t)
    w = (t - p[i]) / (p[i + 1] - p[i])
    return z[i] * (1 - w) + z[i + 1] * w
end

"""
    discount(curve, t) / discount(curve, date)

Discount factor: `exp(-r(t) * t)`. At `t = 0` (the anchor date)
the factor is exactly 1. With a `Date`, the year fraction is
measured from the curve anchor with Actual/365.
"""
function discount(curve::ZeroCurve, t::Real)
    t = float(t)
    t < 0 && throw(ArgumentError("t must not be negative"))
    t == 0 && return 1.0
    return exp(-zero_rate(curve, t) * t)
end

function discount(curve::ZeroCurve, d::Date)
    return discount(curve, yearfrac(curve.anchor, d, :actual_365))
end

"""
    forward_rate(curve, t1, t2)

Continuously compounded forward profit rate between year fractions
`t1` and `t2`. The result is negative when the curve falls steeply
enough between the two times; that is the interpolation speaking,
and it is reported rather than floored at zero.
"""
function forward_rate(curve::ZeroCurve, t1::Real, t2::Real)
    t1, t2 = float(t1), float(t2)
    0 < t1 < t2 || throw(ArgumentError("need 0 < t1 < t2"))
    r1, r2 = zero_rate(curve, t1), zero_rate(curve, t2)
    return (r2 * t2 - r1 * t1) / (t2 - t1)
end

"""
    par_rate(curve, T, m) -> Float64

Annual profit rate (compounded `m` times) of a par bullet sukuk
maturing in `T` years: the rate at which price equals face.
"""
function par_rate(curve::ZeroCurve, T::Real, m::Int)
    T = float(T)
    T <= 0 && throw(ArgumentError("T must be positive"))
    m < 1 && throw(ArgumentError("m must be a positive integer"))
    n = round(Int, m * T)
    n < 1 && throw(ArgumentError("T too short for frequency m"))
    annuity = sum(discount(curve, i / m) / m for i in 1:n)
    annuity <= 0 && throw(ArgumentError("curve gives no positive annuity"))
    return (1 - discount(curve, T)) / annuity
end

# Quote-set validation shared by `bootstrap` and
# `calibration_report`. Returns the instruments ordered by final
# maturity. Malformed input is a contract violation and throws;
# whether a well-formed set has a solution is a separate question,
# answered by the solve (and reported by `calibration_report`).
function _validate_instruments(instruments, anchor::Date)
    isempty(instruments) && throw(ArgumentError("no instruments given"))
    for (cfs, price) in instruments
        isempty(cfs) &&
            throw(ArgumentError("an instrument has no cash flows"))
        (isfinite(price) && price > 0) || throw(ArgumentError(
            "quoted prices must be positive and finite"))
        dates = [cf.date for cf in cfs]
        all(dates[i] < dates[i + 1] for i in 1:(length(dates) - 1)) ||
            throw(ArgumentError(
                "cash flows must be in strictly increasing date order"))
        for cf in cfs
            (isfinite(cf.amount) && cf.amount > 0) || throw(ArgumentError(
                "cash-flow amounts must be positive and finite"))
            cf.date < anchor && throw(ArgumentError(
                "cash flow dated $(cf.date) precedes the curve anchor $anchor"))
        end
    end
    ordered = sort(instruments, by=x -> x[1][end].date)
    length(ordered[1][1]) == 1 ||
        throw(ArgumentError("first instrument must be a discount instrument"))
    maturities = [inst[1][end].date for inst in ordered]
    length(unique(maturities)) == length(maturities) || throw(ArgumentError(
        "duplicate instrument maturity: two quotes share a maturity " *
        "date, and the sequential solver fits one pillar per maturity " *
        "(no joint-fit method is selected)"))
    return ordered
end

# Zero rate at the new pillar `T` for one instrument, given the
# pillars solved so far. A discount instrument pins its rate
# directly; a coupon instrument is solved by repricing the full
# instrument on the candidate curve that includes the new pillar.
function _solve_pillar(pillars, zeros, anchor::Date, cfs, price)
    T = yearfrac(anchor, cfs[end].date, :actual_365)
    T <= 0 && throw(ArgumentError("instrument matures at or before anchor"))
    if length(cfs) == 1
        d = price / cfs[1].amount
        0 < d <= 1 || throw(ArgumentError("discount price out of range"))
        return -log(d) / T
    end
    times = [yearfrac(anchor, cf.date, :actual_365) for cf in cfs]
    amounts = [cf.amount for cf in cfs]
    function pv_at(z_new)
        trial = ZeroCurve(anchor, [pillars; T], [zeros; z_new])
        s = 0.0
        for (a, t) in zip(amounts, times)
            s += a * discount(trial, t)
        end
        return s
    end
    return _bisect_zero(z -> pv_at(z) - price)
end

"""
    bootstrap(instruments, anchor) -> ZeroCurve

Build a zero curve from `(cashflows, price)` pairs, processed in
order of final maturity. The first instrument must be a discount
(single cash flow) instrument. Each later instrument contributes one
new pillar at its final maturity, solved so the curve reprices the
instrument exactly.

For coupon instruments the new pillar is found by root-solving the
full instrument present value on the candidate curve that already
includes the new pillar. This matters because linear zero-rate
interpolation means the new pillar changes discount factors for
intermediate dates between the previous last pillar and the new one;
freezing those coupons on the old curve would leave a repricing error.

Exactness scope: the solver is exact for the instruments it
calibrates, and only in that sense. Each new pillar sits at a later
maturity than every cash flow of the instruments already fitted, so
adding it cannot change their discount factors, and every
calibrating instrument reprices on the final curve (the residuals
are exposed by `calibration_report`). It is not a joint fit: every
quote must be consumed, one pillar per maturity, and duplicate
maturity quotes are rejected rather than averaged. A well-formed
quote set with no solution (a price below what the already-fitted
pillars force the instrument to be worth) is rejected with the
failing instrument identified.
"""
function bootstrap(instruments::Vector{Tuple{Vector{CashFlow},Float64}},
                   anchor::Date)
    ordered = _validate_instruments(instruments, anchor)
    pillars = Float64[]
    zeros = Float64[]
    for (cfs, price) in ordered
        z = try
            _solve_pillar(pillars, zeros, anchor, cfs, price)
        catch err
            err isa ArgumentError || rethrow()
            throw(ArgumentError(
                "no curve fits the instrument maturing " *
                "$(cfs[end].date) at its quoted price: $(err.msg)"))
        end
        push!(pillars, yearfrac(anchor, cfs[end].date, :actual_365))
        push!(zeros, z)
    end
    return ZeroCurve(anchor, pillars, zeros)
end

"""
    calibration_report(instruments, anchor) -> NamedTuple

Run the sequential calibration of `bootstrap` and report how it
went, instead of only returning the curve or throwing. The result
carries:

- `status`: `:exact` when every instrument repriced to within
  1e-8 of its quoted price, `:approximate` when the solve completed
  but a residual exceeded that tolerance, or `:infeasible` when an
  instrument had no solution at its quoted price.
- `curve`: the fitted `ZeroCurve`, or `nothing` when infeasible.
- `rows`: one row per instrument attempted, in maturity order,
  with `maturity`, `quoted_price`, `model_price`, `residual`
  (absolute, in quoted price units) and a per-instrument `status`.
  The instrument that made the set infeasible is the last row,
  marked `:infeasible` with `NaN` model price and residual.
- `max_residual`: the largest residual over the fitted rows
  (`NaN` when nothing was fitted).
- `message`: a short statement of the outcome.

Malformed quote sets (empty schedules, unordered or duplicated
cash-flow dates, non-positive amounts, cash flows before the
anchor, duplicate maturities, non-positive or non-finite prices)
are rejected with the same validation errors as `bootstrap`; they
are contract violations, not calibration outcomes.
"""
function calibration_report(instruments::Vector{Tuple{Vector{CashFlow},Float64}},
                            anchor::Date)
    ordered = _validate_instruments(instruments, anchor)
    pillars = Float64[]
    zeros = Float64[]
    rows = NamedTuple[]
    for (cfs, price) in ordered
        maturity = cfs[end].date
        z = try
            _solve_pillar(pillars, zeros, anchor, cfs, price)
        catch err
            err isa ArgumentError || rethrow()
            push!(rows, (maturity=maturity, quoted_price=price,
                         model_price=NaN, residual=NaN,
                         status=:infeasible))
            fitted = [r.residual for r in rows if !isnan(r.residual)]
            return (status=:infeasible, curve=nothing, rows=rows,
                    max_residual=isempty(fitted) ? NaN : maximum(fitted),
                    message="no curve fits the instrument maturing " *
                            "$maturity at its quoted price: $(err.msg)")
        end
        push!(pillars, yearfrac(anchor, maturity, :actual_365))
        push!(zeros, z)
        curve = ZeroCurve(anchor, pillars, zeros)
        model = sum(cf.amount * discount(curve, cf.date) for cf in cfs)
        residual = abs(model - price)
        push!(rows, (maturity=maturity, quoted_price=price,
                     model_price=model, residual=residual,
                     status=residual <= 1e-8 ? :exact : :approximate))
    end
    curve = ZeroCurve(anchor, pillars, zeros)
    max_residual = maximum(r.residual for r in rows)
    status = max_residual <= 1e-8 ? :exact : :approximate
    message = status == :exact ?
        "all $(length(rows)) instruments repriced within 1e-8 " *
        "of their quoted prices" :
        "calibration completed with a largest repricing residual " *
        "of $max_residual"
    return (status=status, curve=curve, rows=rows,
            max_residual=max_residual, message=message)
end

"""
    _bisect_zero(f; lo, hi, tol, maxiter)

Bisection root finder for a continuous strictly decreasing `f`.
The bracket expands automatically until `f(lo) > 0 > f(hi)`.
"""
function _bisect_zero(f; lo=-1.0, hi=5.0, tol=1e-12, maxiter=200)
    flo, fhi = f(lo), f(hi)
    for _ in 1:50
        (flo > 0 && fhi < 0) && break
        if flo <= 0
            lo -= (hi - lo)
        else
            hi += (hi - lo)
        end
        flo, fhi = f(lo), f(hi)
    end
    (flo > 0 && fhi < 0) ||
        throw(ArgumentError("could not bracket root for curve bootstrap"))
    for _ in 1:maxiter
        mid = (lo + hi) / 2
        fmid = f(mid)
        (abs(fmid) < tol || (hi - lo) < tol) && return mid
        if fmid > 0
            lo = mid
        else
            hi = mid
        end
    end
    return (lo + hi) / 2
end
