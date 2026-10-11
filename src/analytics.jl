"""
Yield and risk analytics for profit-rate instruments.

All measures are computed from an explicit cash-flow schedule, so
they apply to any structure in `cashflows.jl`: bullet ijara and
wakala sukuk, installment murabaha, or anything else that produces
dated cash flows. Yields are nominal annual rates compounded `m`
times per year, the market convention for quoted sukuk yields.
"""

using Dates

"""
    price_from_cashflows(cfs, y, anchor; m=2)

Present value of `cfs` at nominal annual yield `y` compounded `m`
times. Times are measured from `anchor` with Actual/365.
"""
function price_from_cashflows(cfs::Vector{CashFlow}, y::Real, anchor::Date;
                              m::Int=2)
    m < 1 && throw(ArgumentError("m must be a positive integer"))
    yp = float(y) / m
    pv = 0.0
    for cf in cfs
        t = yearfrac(anchor, cf.date, :actual_365)
        t < 0 && throw(ArgumentError("cash flow before anchor"))
        pv += cf.amount / (1 + yp)^(m * t)
    end
    return pv
end

"""
    ytm_from_price(cfs, price, anchor; m=2)

Nominal annual yield implied by `price`, by bisection. Returns NaN
when the price lies outside the attainable range.
"""
function ytm_from_price(cfs::Vector{CashFlow}, price::Real, anchor::Date;
                        m::Int=2)
    price = float(price)
    price <= 0 && return NaN
    f(y) = price_from_cashflows(cfs, y, anchor; m=m) - price
    lo, hi = -0.99, 5.0
    flo, fhi = f(lo), f(hi)
    (flo < 0) == (fhi < 0) && return NaN
    for _ in 1:200
        mid = (lo + hi) / 2
        fmid = f(mid)
        (fmid < 0) == (flo < 0) ? (lo = mid; flo = fmid) : (hi = mid)
        hi - lo < 1e-12 && break
    end
    return (lo + hi) / 2
end

"""
    current_yield(annual_distribution, price)

Annual distributions divided by price. A running snapshot, not a
maturity measure.
"""
function current_yield(annual_distribution::Real, price::Real)
    annual_distribution = float(annual_distribution)
    price = float(price)
    price <= 0 && throw(ArgumentError("price must be positive"))
    return annual_distribution / price
end

"""
    macaulay_duration(cfs, y, anchor; m=2)

Present-value-weighted average time to receipt, in years.
"""
function macaulay_duration(cfs::Vector{CashFlow}, y::Real, anchor::Date;
                           m::Int=2)
    p = price_from_cashflows(cfs, y, anchor; m=m)
    p <= 0 && throw(ArgumentError("non-positive present value"))
    yp = float(y) / m
    weighted = 0.0
    for cf in cfs
        t = yearfrac(anchor, cf.date, :actual_365)
        weighted += t * cf.amount / (1 + yp)^(m * t)
    end
    return weighted / p
end

"""
    modified_duration(cfs, y, anchor; m=2)

Price sensitivity: the fractional price change per unit change in
yield. Equals Macaulay duration divided by `(1 + y/m)`.
"""
function modified_duration(cfs::Vector{CashFlow}, y::Real, anchor::Date;
                           m::Int=2)
    return macaulay_duration(cfs, y, anchor; m=m) / (1 + float(y) / m)
end

"""
    convexity(cfs, y, anchor; m=2)

Second-order price sensitivity to yield changes, in years squared.
Positive for standard bullet structures: the duration
approximation understates price gains and overstates losses.
"""
function convexity(cfs::Vector{CashFlow}, y::Real, anchor::Date; m::Int=2)
    p = price_from_cashflows(cfs, y, anchor; m=m)
    p <= 0 && throw(ArgumentError("non-positive present value"))
    yp = float(y) / m
    acc = 0.0
    for cf in cfs
        t = yearfrac(anchor, cf.date, :actual_365)
        acc += t * (t + 1 / m) * cf.amount / (1 + yp)^(m * t)
    end
    return acc / (p * (1 + yp)^2)
end

"""
    dv01(cfs, y, anchor; m=2)

Absolute price change for a one basis point rise in yield.
"""
function dv01(cfs::Vector{CashFlow}, y::Real, anchor::Date; m::Int=2)
    p = price_from_cashflows(cfs, y, anchor; m=m)
    return modified_duration(cfs, y, anchor; m=m) * p * 1e-4
end

"""
    price_under_shift(cfs, y, bps, anchor; m=2)

Reprice the cash flows after a parallel shift of `bps` basis points
in the yield.
"""
function price_under_shift(cfs::Vector{CashFlow}, y::Real, bps::Real,
                           anchor::Date; m::Int=2)
    return price_from_cashflows(cfs, float(y) + float(bps) / 1e4, anchor; m=m)
end
