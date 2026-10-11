"""
Profit-rate curve construction.

A zero curve stores continuously compounded zero profit rates at
pillar maturities, measured in years from an anchor date. Rates are
linearly interpolated between pillars and held flat outside them.
`bootstrap` builds the curve from market instruments: discount
(zero-coupon) sukuk pin their own pillar directly, and coupon sukuk
are added shortest-first, each new pillar solved from the instrument
price with earlier cash flows discounted on the curve built so far.
"""

using Dates

"""
    ZeroCurve(anchor, pillars, zeros)

`pillars` are year fractions from `anchor`, strictly increasing and
positive. `zeros` are continuously compounded annual rates.
"""
struct ZeroCurve
    anchor::Date
    pillars::Vector{Float64}
    zeros::Vector{Float64}

    function ZeroCurve(anchor::Date, pillars::Vector{Float64},
                       zeros::Vector{Float64})
        length(pillars) == length(zeros) ||
            throw(ArgumentError("pillars and zeros must match in length"))
        all(p -> p > 0, pillars) ||
            throw(ArgumentError("pillars must be positive year fractions"))
        issorted(pillars) ||
            throw(ArgumentError("pillars must be strictly increasing"))
        return new(anchor, pillars, zeros)
    end
end

"""
    zero_rate(curve, t)

Continuously compounded zero rate at year fraction `t`: linear
interpolation between pillars, flat extrapolation beyond them.
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

Discount factor: `exp(-r(t) * t)`. With a `Date`, the year fraction
is measured from the curve anchor with Actual/365.
"""
discount(curve::ZeroCurve, t::Real) = exp(-zero_rate(curve, t) * t)

function discount(curve::ZeroCurve, d::Date)
    return discount(curve, yearfrac(curve.anchor, d, :actual_365))
end

"""
    forward_rate(curve, t1, t2)

Continuously compounded forward profit rate between year fractions
`t1` and `t2`.
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

"""
    bootstrap(instruments, anchor) -> ZeroCurve

Build a zero curve from `(cashflows, price)` pairs, processed in
order of final maturity. The first instrument must be a discount
(single cash flow) instrument. Each later instrument contributes one
new pillar at its final maturity, solved so the curve reprices the
instrument exactly.
"""
function bootstrap(instruments::Vector{Tuple{Vector{CashFlow},Float64}},
                   anchor::Date)
    isempty(instruments) && throw(ArgumentError("no instruments given"))
    ordered = sort(instruments, by=x -> x[1][end].date)
    length(ordered[1][1]) == 1 ||
        throw(ArgumentError("first instrument must be a discount instrument"))
    pillars = Float64[]
    zeros = Float64[]
    curve = ZeroCurve(anchor, pillars, zeros)
    for (cfs, price) in ordered
        price <= 0 && throw(ArgumentError("price must be positive"))
        T = yearfrac(anchor, cfs[end].date, :actual_365)
        T <= 0 && throw(ArgumentError("instrument matures at or before anchor"))
        if length(cfs) == 1
            d = price / cfs[1].amount
            0 < d <= 1 || throw(ArgumentError("discount price out of range"))
            z = -log(d) / T
        else
            pv_known = sum(cf.amount *
                           discount(curve, yearfrac(anchor, cf.date, :actual_365))
                           for cf in cfs[1:(end - 1)])
            d_last = (price - pv_known) / cfs[end].amount
            0 < d_last <= 1 ||
                throw(ArgumentError("implied discount factor out of range"))
            z = -log(d_last) / T
        end
        push!(pillars, T)
        push!(zeros, z)
    end
    return ZeroCurve(anchor, pillars, zeros)
end
