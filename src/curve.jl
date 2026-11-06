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
solve status and repricing residual of every instrument. The
fitted pillars can also be read through two further interpolation
schemes (`LogDiscountCurve`, `SmoothCurve`), and
`interpolation_model_risk` compares all three on calibration,
held-out tenors, forwards and stressed long-dated prices, because
a handful of short pillars does not identify the long curve and
the differences between schemes are the honest measure of that.

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

# ---------------------------------------------------------------------------
# Interpolation model risk.
#
# A bootstrapped curve is only observed at its pillars. Between them,
# and everywhere beyond the last one, the curve is whatever the
# interpolation scheme says it is, and with sparse short-tenor data
# (the January 2026 IILM record has four pillars, all inside a year)
# the scheme choice can move a long-dated price far more than any
# calibration residual suggests. The types and the report below exist
# to measure that gap instead of hiding it: three schemes fitted to
# the same pillars, compared on calibration, on held-out tenors, on
# forward-rate behavior, and on the prices of long reference
# instruments under pillar perturbations.
# ---------------------------------------------------------------------------

# Shared validation for the discount-factor schemes: the same pillar
# rules as ZeroCurve, plus strictly positive finite discount factors.
# Discount factors above 1 are accepted: they are what a negative
# zero rate means, and whether negative rates are acceptable is a
# policy decision for the caller (see interpolation_model_risk),
# not something a constructor should silently rule out.
function _validate_discounts(pillars, discounts)
    length(pillars) == length(discounts) ||
        throw(ArgumentError("pillars and discounts must match in length"))
    all(isfinite, pillars) ||
        throw(ArgumentError("pillars must be finite year fractions"))
    all(p -> p > 0, pillars) ||
        throw(ArgumentError("pillars must be positive year fractions"))
    all(pillars[i] < pillars[i + 1] for i in 1:(length(pillars) - 1)) ||
        throw(ArgumentError("pillars must be strictly increasing"))
    all(d -> isfinite(d) && d > 0, discounts) ||
        throw(ArgumentError("discount factors must be positive and finite"))
    return nothing
end

"""
    LogDiscountCurve(anchor, pillars, discounts)
    LogDiscountCurve(curve::ZeroCurve)

Zero curve stored as discount factors at the pillars, with the
log discount factor linearly interpolated between pillars: the
forward rate is piecewise constant, one value per segment. Before
the first pillar the segment runs from the anchor (discount factor
exactly 1 there); beyond the last pillar the final segment's
forward continues unchanged. Constructed from a `ZeroCurve`, it
carries the same pillars and the same discount factors at them;
the two schemes differ only between and beyond the pillars.
"""
struct LogDiscountCurve
    anchor::Date
    pillars::Vector{Float64}
    discounts::Vector{Float64}

    function LogDiscountCurve(anchor::Date, pillars::Vector{Float64},
                              discounts::Vector{Float64})
        _validate_discounts(pillars, discounts)
        return new(anchor, pillars, discounts)
    end
end

function LogDiscountCurve(curve::ZeroCurve)
    return LogDiscountCurve(curve.anchor, curve.pillars,
                            exp.(-curve.zeros .* curve.pillars))
end

function _log_discount(curve::LogDiscountCurve, t::Float64)
    p, d = curve.pillars, curve.discounts
    t <= p[1] && return log(d[1]) * (t / p[1])
    if t >= p[end]
        slope = length(p) == 1 ? log(d[1]) / p[1] :
            (log(d[end]) - log(d[end - 1])) / (p[end] - p[end - 1])
        return log(d[end]) + slope * (t - p[end])
    end
    i = searchsortedlast(p, t)
    w = (t - p[i]) / (p[i + 1] - p[i])
    return log(d[i]) * (1 - w) + log(d[i + 1]) * w
end

"""
    SmoothCurve(anchor, pillars, discounts)
    SmoothCurve(curve::ZeroCurve)

A smooth zero curve: the log discount factor is a monotone cubic
Hermite interpolant (Fritsch-Carlson) through the anchor (log
discount exactly 0) and the pillar log discounts, so the curve is
continuously differentiable and its instantaneous forward rate
varies smoothly instead of jumping at pillars. The constraint in
the construction is monotonicity: where the pillar log discounts
fall segment by segment, the interpolant falls with them, so
smoothness alone cannot manufacture a rising discount factor (a
negative forward) out of falling ones. Where the pillars themselves
imply negative forwards, the interpolant reports them like every
other scheme; nothing is floored. Beyond the last pillar the log
discount continues at the end slope (a constant instantaneous
forward). At least two pillars are required: with one there is no
segment for the smoothness to constrain.
"""
struct SmoothCurve
    anchor::Date
    pillars::Vector{Float64}
    discounts::Vector{Float64}
    nodes::Vector{Float64}
    log_discounts::Vector{Float64}
    slopes::Vector{Float64}

    function SmoothCurve(anchor::Date, pillars::Vector{Float64},
                         discounts::Vector{Float64})
        _validate_discounts(pillars, discounts)
        length(pillars) >= 2 || throw(ArgumentError(
            "a smooth curve needs at least two pillars"))
        nodes = [0.0; pillars]
        log_discounts = [0.0; log.(discounts)]
        slopes = _monotone_cubic_slopes(nodes, log_discounts)
        return new(anchor, pillars, discounts, nodes, log_discounts, slopes)
    end
end

function SmoothCurve(curve::ZeroCurve)
    return SmoothCurve(curve.anchor, curve.pillars,
                       exp.(-curve.zeros .* curve.pillars))
end

# Fritsch-Carlson derivatives for a monotone cubic Hermite
# interpolant: weighted harmonic means of the segment slopes at
# interior nodes (zero where the slope changes sign), and the
# standard limited one-sided estimate at the ends. Where the data
# are monotone segment by segment, these derivatives keep the
# interpolant monotone on every segment.
function _monotone_cubic_slopes(xs, ys)
    n = length(xs) - 1
    s = [(ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) for i in 1:n]
    m = zeros(n + 1)
    m[1] = _fc_endpoint(xs[2] - xs[1], xs[3] - xs[2], s[1], s[2])
    m[end] = _fc_endpoint(xs[end] - xs[end - 1],
                          xs[end - 1] - xs[end - 2], s[end], s[end - 1])
    for j in 2:n
        sl, sr = s[j - 1], s[j]
        if sl * sr <= 0
            m[j] = 0.0
        else
            hl = xs[j] - xs[j - 1]
            hr = xs[j + 1] - xs[j]
            w1 = 2 * hr + hl
            w2 = hr + 2 * hl
            m[j] = (w1 + w2) / (w1 / sl + w2 / sr)
        end
    end
    return m
end

# One-sided endpoint derivative: the secant-based estimate from
# the two nearest segments, set to zero when it would reverse the
# first segment's direction and limited to three times that
# segment's slope when the segments change sign.
function _fc_endpoint(h1, h2, s1, s2)
    s1 == 0 && return 0.0
    d = ((2 * h1 + h2) * s1 - h1 * s2) / (h1 + h2)
    sign(d) != sign(s1) && return 0.0
    if sign(s1) != sign(s2) && abs(d) > 3 * abs(s1)
        return 3 * s1
    end
    return d
end

function _log_discount(curve::SmoothCurve, t::Float64)
    xs, ys, m = curve.nodes, curve.log_discounts, curve.slopes
    t >= xs[end] && return ys[end] + m[end] * (t - xs[end])
    i = searchsortedlast(xs, t)
    h = xs[i + 1] - xs[i]
    u = (t - xs[i]) / h
    u2 = u * u
    u3 = u2 * u
    return (2 * u3 - 3 * u2 + 1) * ys[i] +
           (u3 - 2 * u2 + u) * h * m[i] +
           (-2 * u3 + 3 * u2) * ys[i + 1] +
           (u3 - u2) * h * m[i + 1]
end

# The discount / zero-rate / forward interface for the two
# discount-factor schemes, with the same conventions as ZeroCurve:
# the discount factor at the anchor is exactly 1, the zero rate at
# t = 0 is undefined, and forwards are reported as they come out,
# negative values included.
for T in (:LogDiscountCurve, :SmoothCurve)
    @eval begin
        function discount(curve::$T, t::Real)
            t = float(t)
            t < 0 && throw(ArgumentError("t must not be negative"))
            t == 0 && return 1.0
            return exp(_log_discount(curve, t))
        end

        function discount(curve::$T, d::Date)
            return discount(curve, yearfrac(curve.anchor, d, :actual_365))
        end

        function zero_rate(curve::$T, t::Real)
            t = float(t)
            t <= 0 && throw(ArgumentError("t must be positive"))
            return -_log_discount(curve, t) / t
        end

        function forward_rate(curve::$T, t1::Real, t2::Real)
            t1, t2 = float(t1), float(t2)
            0 < t1 < t2 || throw(ArgumentError("need 0 < t1 < t2"))
            r1, r2 = zero_rate(curve, t1), zero_rate(curve, t2)
            return (r2 * t2 - r1 * t1) / (t2 - t1)
        end
    end
end

function _scheme_curve(name::Symbol, anchor::Date, pillars, zeros)
    if name === :linear_zero
        return ZeroCurve(anchor, pillars, zeros)
    elseif name === :log_discount
        return LogDiscountCurve(anchor, pillars, exp.(-zeros .* pillars))
    elseif name === :smooth
        return SmoothCurve(anchor, pillars, exp.(-zeros .* pillars))
    end
    throw(ArgumentError("unknown interpolation scheme: $name"))
end

# Price of a bullet reference instrument: face 100, annual payments
# of 100 * rate, principal back at year T. Priced on year fractions
# directly; for a curve whose pillars end inside a year, almost all
# of this price is extrapolation, which is the point of the stress.
function _bullet_price(curve, T::Int, rate::Float64)
    total = 0.0
    for k in 1:T
        amount = k == T ? 100.0 * (1 + rate) : 100.0 * rate
        total += amount * discount(curve, float(k))
    end
    return total
end

# Forward rates sampled over consecutive points of a fixed grid:
# the pillars, their midpoints, and 2y/5y/10y where those lie
# beyond the last pillar. Returns (minimum, maximum).
function _forward_range(curve, pillars)
    pts = copy(pillars)
    for i in 1:(length(pillars) - 1)
        push!(pts, (pillars[i] + pillars[i + 1]) / 2)
    end
    for t in (2.0, 5.0, 10.0)
        t > pillars[end] && push!(pts, t)
    end
    sort!(unique!(pts))
    fwds = [forward_rate(curve, pts[i], pts[i + 1])
            for i in 1:(length(pts) - 1)]
    return (minimum(fwds), maximum(fwds))
end

"""
    interpolation_model_risk(instruments, anchor;
        shifts=(-0.0025, -0.0010, 0.0010, 0.0025), bump=0.0025,
        negative_forward_policy=:allow) -> NamedTuple

Assess how much of a bootstrapped curve is data and how much is
interpolation choice. The quote set is bootstrapped as usual, and
the fitted pillars are then read through three schemes:

- `:linear_zero`: the library `ZeroCurve` (zero rates linear
  between pillars, flat beyond them).
- `:log_discount`: a `LogDiscountCurve` (log discount factors
  linear between pillars, so forwards are piecewise constant; the
  last segment's forward continues beyond the last pillar).
- `:smooth`: a `SmoothCurve` (monotone cubic log discounts; the
  end slope continues beyond the last pillar).

The report carries `anchor`, the fitted `pillars` and `zeros`, one
entry per scheme in `schemes`, `held_out` rows, cross-scheme
`stress` rows, the `negative_forward_policy` in force, and a
`message` summarizing the largest divergences. Each scheme entry
carries:

- `calibration_rows` and `max_calibration_residual`: the exact
  repricing residual of every calibrating instrument under that
  scheme. All three schemes pass through the fitted pillars by
  construction, so these residuals are at solver tolerance; the
  report states them rather than letting "exact calibration"
  imply the curve is identified.
- `min_forward` / `max_forward`: sampled forward rates over the
  pillars, their midpoints and 2y/5y/10y beyond the last pillar,
  and `has_negative_forward`.
- `policy_status`: `:ok`, or `:violates_policy` when the policy
  (below) rejects negative forwards and this scheme implies one.
- `long_zero_rates`: the zero rate at 2, 5 and 10 years. Past the
  last pillar these are pure extrapolation, one answer per scheme.
- `stress`: per reference instrument (5y and 10y annual bullets at
  a 4% profit rate, face 100), the price on the fitted curve and
  the minimum, maximum and range over perturbation scenarios:
  every zero shifted in parallel by each of `shifts`, and each
  single pillar's zero bumped by plus or minus `bump`.

`held_out` rows are leave-one-out: each instrument is removed, the
rest are refitted, and the removed instrument is repriced under
each scheme (`quoted_price`, `predicted_price`, `price_error` per
100 face for discount instruments). When the reduced set cannot be
bootstrapped at all (removing the only discount instrument leaves
a set the sequential solver cannot start from), or a scheme cannot
be built on the reduced pillars (the smooth scheme needs at least
two), the row is marked `:not_identified` with `NaN` prices rather
than being dropped or fitted some other way.

Negative-forward policy: `negative_forward_policy` is the explicit
model policy for this report. Under `:allow` (the default, and the
library convention documented at the top of this file) negative
forwards are reported as they come out and every scheme's status
is `:ok`. Under `:reject`, a scheme whose sampled forwards go
negative is flagged `:violates_policy`. No scheme floors, caps or
otherwise edits a forward under either policy; the policy only
decides what the report does with the fact.

What this cannot do: with a few short pillars, no comparison of
interpolators identifies the long curve, and the held-out errors
and stress ranges are expected to be large. That is the finding,
not a defect in the comparison.
"""
function interpolation_model_risk(
        instruments::Vector{Tuple{Vector{CashFlow},Float64}},
        anchor::Date;
        shifts=(-0.0025, -0.0010, 0.0010, 0.0025),
        bump::Real=0.0025,
        negative_forward_policy::Symbol=:allow)
    negative_forward_policy in (:allow, :reject) || throw(ArgumentError(
        "negative_forward_policy must be :allow or :reject"))
    (isfinite(bump) && bump > 0) ||
        throw(ArgumentError("bump must be positive and finite"))
    all(s -> isfinite(s) && s != 0, shifts) ||
        throw(ArgumentError("shifts must be finite and nonzero"))
    base = bootstrap(instruments, anchor)
    pillars, zeros = base.pillars, base.zeros
    length(pillars) >= 2 || throw(ArgumentError(
        "interpolation model risk needs at least two fitted pillars"))
    names = (:linear_zero, :log_discount, :smooth)
    stress_specs = ((label="5y annual bullet, 4% profit rate",
                     maturity=5.0, years=5, rate=0.04),
                    (label="10y annual bullet, 4% profit rate",
                     maturity=10.0, years=10, rate=0.04))
    scenarios = Vector{Float64}[]
    for s in shifts
        push!(scenarios, zeros .+ s)
    end
    for i in eachindex(zeros)
        for sgn in (1.0, -1.0)
            z = copy(zeros)
            z[i] += sgn * bump
            push!(scenarios, z)
        end
    end
    scheme_rows = NamedTuple[]
    base_prices = Dict{Symbol,Vector{Float64}}()
    for name in names
        curve = _scheme_curve(name, anchor, pillars, zeros)
        cal_rows = NamedTuple[]
        for (cfs, price) in instruments
            model = sum(cf.amount * discount(curve, cf.date) for cf in cfs)
            push!(cal_rows, (maturity=cfs[end].date, quoted_price=price,
                             model_price=model,
                             residual=abs(model - price)))
        end
        max_residual = maximum(r.residual for r in cal_rows)
        fmin, fmax = _forward_range(curve, pillars)
        has_negative = fmin < 0
        status = negative_forward_policy === :reject && has_negative ?
            :violates_policy : :ok
        long_rows = [(time=t, zero_rate=zero_rate(curve, t))
                     for t in (2.0, 5.0, 10.0)]
        stress_rows = NamedTuple[]
        prices = Float64[]
        for spec in stress_specs
            base_price = _bullet_price(curve, spec.years, spec.rate)
            push!(prices, base_price)
            all_prices = [base_price]
            for z in scenarios
                scen_curve = _scheme_curve(name, anchor, pillars, z)
                push!(all_prices,
                      _bullet_price(scen_curve, spec.years, spec.rate))
            end
            push!(stress_rows, (label=spec.label, maturity=spec.maturity,
                                base_price=base_price,
                                scenario_min=minimum(all_prices),
                                scenario_max=maximum(all_prices),
                                scenario_range=maximum(all_prices) -
                                               minimum(all_prices)))
        end
        base_prices[name] = prices
        push!(scheme_rows, (name=name,
                            max_calibration_residual=max_residual,
                            calibration_rows=cal_rows,
                            min_forward=fmin, max_forward=fmax,
                            has_negative_forward=has_negative,
                            policy_status=status,
                            long_zero_rates=long_rows,
                            stress=stress_rows))
    end
    stress_top = NamedTuple[]
    for (k, spec) in enumerate(stress_specs)
        ps = [base_prices[n][k] for n in names]
        push!(stress_top, (label=spec.label, maturity=spec.maturity,
                           prices=(linear_zero=ps[1], log_discount=ps[2],
                                   smooth=ps[3]),
                           spread=maximum(ps) - minimum(ps),
                           max_deviation_from_linear_zero=
                               maximum(abs.(ps .- ps[1]))))
    end
    held_out = NamedTuple[]
    for (idx, (cfs, price)) in enumerate(instruments)
        maturity = cfs[end].date
        t = yearfrac(anchor, maturity, :actual_365)
        rest = [instruments[j] for j in eachindex(instruments) if j != idx]
        sub = try
            bootstrap(rest, anchor)
        catch err
            err isa ArgumentError || rethrow()
            nothing
        end
        sub_curves = Dict{Symbol,Any}()
        if sub !== nothing
            for name in names
                sub_curves[name] = try
                    _scheme_curve(name, anchor, sub.pillars, sub.zeros)
                catch err
                    err isa ArgumentError || rethrow()
                    nothing
                end
            end
        end
        for name in names
            scen_curve = get(sub_curves, name, nothing)
            if scen_curve === nothing
                push!(held_out, (scheme=name, maturity=maturity, time=t,
                                 quoted_price=price, predicted_price=NaN,
                                 price_error=NaN, status=:not_identified))
            else
                predicted = sum(cf.amount * discount(scen_curve, cf.date)
                                for cf in cfs)
                push!(held_out, (scheme=name, maturity=maturity, time=t,
                                 quoted_price=price,
                                 predicted_price=predicted,
                                 price_error=abs(predicted - price),
                                 status=:ok))
            end
        end
    end
    fitted = [r.price_error for r in held_out if r.status == :ok]
    max_loo = isempty(fitted) ? NaN : maximum(fitted)
    max_cal = maximum(s.max_calibration_residual for s in scheme_rows)
    spread10 = stress_top[2].spread
    message = "all three schemes reprice the calibrating instruments " *
        "with a largest residual of $max_cal; away from the " *
        "pillars they diverge: largest held-out pricing error " *
        "$max_loo per 100 face, and a $spread10 spread across " *
        "schemes on the 10y reference price"
    return (anchor=anchor, pillars=pillars, zeros=zeros,
            schemes=scheme_rows, held_out=held_out, stress=stress_top,
            negative_forward_policy=negative_forward_policy,
            message=message)
end
