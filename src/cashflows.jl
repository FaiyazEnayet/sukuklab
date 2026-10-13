"""
Cash-flow modeling for fixed-profit-rate sukuk.

A sukuk certificate represents ownership in an underlying arrangement
and pays periodic profit distributions plus principal at maturity.
Two common mechanics are modeled here:

- Ijara (lease-based): the SPV owns an asset and leases it to the
  obligor. Certificate holders receive periodic rental distributions
  and the principal when the asset is repurchased at maturity. The
  cash-flow shape is a bullet: coupons each period, face at the end.
- Murabaha (deferred sale): the SPV buys an asset and sells it to the
  obligor at cost plus an agreed profit, payable later. With a bullet
  structure the shape matches ijara. With installments, the deferred
  sale price (cost plus total profit) is split into equal payments.

The `structure` field records which mechanic a schedule follows. It
changes nothing about the arithmetic beyond the payment shape.
"""

using Dates

"""
    CashFlow(date, amount)

A single dated cash flow.
"""
struct CashFlow
    date::Date
    amount::Float64
end

"""
    SukukTerms(name, face, profit_rate, issue, maturity, freq, structure; amortizing=false)

Terms of a fixed-profit-rate sukuk. `profit_rate` is the annual rate
as a decimal, `freq` the number of distributions per year (1, 2, 3,
4, 6 or 12), `structure` a label such as "ijara", "murabaha" or
"wakala". With `amortizing=true` the deferred sale price is paid in
equal installments (murabaha-style); otherwise the structure is a
bullet with principal at maturity.
"""
struct SukukTerms
    name::String
    face::Float64
    profit_rate::Float64
    issue::Date
    maturity::Date
    freq::Int
    structure::String
    amortizing::Bool

    function SukukTerms(name, face, profit_rate, issue, maturity, freq,
                        structure; amortizing=false)
        face = float(face)
        profit_rate = float(profit_rate)
        face <= 0 && throw(ArgumentError("face must be positive"))
        profit_rate < 0 && throw(ArgumentError("profit_rate cannot be negative"))
        maturity <= issue && throw(ArgumentError("maturity must be after issue"))
        freq in (1, 2, 3, 4, 6, 12) ||
            throw(ArgumentError("freq must divide 12 (1, 2, 3, 4, 6 or 12)"))
        return new(String(name), face, profit_rate, issue, maturity,
                   freq, String(structure), amortizing)
    end
end

"""
    yearfrac(d1, d2, daycount)

Year fraction between dates. `:thirty_360` uses the US 30/360
convention, `:actual_365` divides the actual day count by 365.
"""
function yearfrac(d1::Date, d2::Date, daycount::Symbol)
    d2 >= d1 || throw(ArgumentError("d2 must not precede d1"))
    if daycount === :thirty_360
        y1, m1, day1 = year(d1), month(d1), day(d1)
        y2, m2, day2 = year(d2), month(d2), day(d2)
        day1 = min(day1, 30)
        day2 = day2 == 31 && day1 == 30 ? 30 : min(day2, 30)
        return ((y2 - y1) * 360 + (m2 - m1) * 30 + (day2 - day1)) / 360
    elseif daycount === :actual_365
        return Dates.value(d2 - d1) / 365
    else
        throw(ArgumentError("unknown day-count convention: $daycount"))
    end
end

"""
    distribution_dates(terms)

Scheduled distribution dates from issue to maturity, one per period.
The maturity date is always the final date.
"""
function distribution_dates(terms::SukukTerms)
    step = Month(12 ÷ terms.freq)
    dates = Date[]
    d = terms.issue + step
    while d < terms.maturity
        push!(dates, d)
        d += step
    end
    push!(dates, terms.maturity)
    return dates
end

"""
    payment_schedule(terms) -> Vector{CashFlow}

Full cash-flow schedule. Bullet structures pay the periodic profit
distribution each period and face plus the last distribution at
maturity. Amortizing (murabaha installment) structures split the
total deferred sale price, face plus total profit, into equal
installments.
"""
function payment_schedule(terms::SukukTerms)
    dates = distribution_dates(terms)
    n = length(dates)
    if terms.amortizing
        total = terms.face * (1 + terms.profit_rate *
                              yearfrac(terms.issue, terms.maturity, :actual_365))
        installment = total / n
        return [CashFlow(d, installment) for d in dates]
    else
        dist = terms.face * terms.profit_rate / terms.freq
        cfs = [CashFlow(d, dist) for d in dates]
        cfs[end] = CashFlow(dates[end], dist + terms.face)
        return cfs
    end
end

"""
    remaining_cashflows(cfs, settlement) -> Vector{CashFlow}

Cash flows dated after `settlement`: the ones a buyer settling on
that date will actually receive. Earlier cash flows already belong
to the seller.
"""
function remaining_cashflows(cfs::Vector{CashFlow}, settlement::Date)
    return [cf for cf in cfs if cf.date > settlement]
end

"""
    accrued_profit(terms, settlement; daycount=:thirty_360)

Profit accrued since the previous distribution date, for a
settlement date strictly after issue. Zero on or after maturity.
"""
function accrued_profit(terms::SukukTerms, settlement::Date;
                        daycount::Symbol=:thirty_360)
    settlement <= terms.issue &&
        throw(ArgumentError("settlement must be after issue"))
    settlement >= terms.maturity && return 0.0
    dates = distribution_dates(terms)
    prev = terms.issue
    nxt = dates[1]
    for d in dates
        if d <= settlement
            prev = d
        else
            nxt = d
            break
        end
    end
    period = yearfrac(prev, nxt, daycount)
    period <= 0 && return 0.0
    coupon = terms.face * terms.profit_rate / terms.freq
    return coupon * yearfrac(prev, settlement, daycount) / period
end
