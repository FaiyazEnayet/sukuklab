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
    SukukTerms(name, face, profit_rate, issue, maturity, freq, structure; amortizing=false, adjustment=:unadjusted)

Terms of a fixed-profit-rate sukuk. `profit_rate` is the annual rate
as a decimal, `freq` the number of distributions per year (1, 2, 3,
4, 6 or 12), `structure` a label such as "ijara", "murabaha" or
"wakala". With `amortizing=true` the deferred sale price is paid in
equal installments (murabaha-style); otherwise the structure is a
bullet with principal at maturity.

`adjustment` declares the business-day convention for payment dates:
`:unadjusted` (the default; payment dates are the contractual grid
dates), `:following`, `:modified_following` or `:preceding`.
Adjustments are weekend-only; no holiday calendar is modeled, and a
convention applies only when the terms declare it.
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
    adjustment::Symbol

    function SukukTerms(name, face, profit_rate, issue, maturity, freq,
                        structure; amortizing=false, adjustment=:unadjusted)
        face = float(face)
        profit_rate = float(profit_rate)
        face <= 0 && throw(ArgumentError("face must be positive"))
        profit_rate < 0 && throw(ArgumentError("profit_rate cannot be negative"))
        maturity <= issue && throw(ArgumentError("maturity must be after issue"))
        freq in (1, 2, 3, 4, 6, 12) ||
            throw(ArgumentError("freq must divide 12 (1, 2, 3, 4, 6 or 12)"))
        adjustment in (:unadjusted, :following, :modified_following,
                       :preceding) ||
            throw(ArgumentError("unknown business-day adjustment: $adjustment"))
        return new(String(name), face, profit_rate, issue, maturity,
                   freq, String(structure), amortizing, adjustment)
    end
end

"""
    DayCount

Day-count conventions for year fractions. `Thirty360` is the US
30/360 bond basis; `Actual365` divides the actual day count by 365.
The symbols `:thirty_360` and `:actual_365` name the same conventions
and are accepted anywhere a `DayCount` is.
"""
@enum DayCount Thirty360 Actual365

function DayCount(s::Symbol)
    s === :thirty_360 && return Thirty360
    s === :actual_365 && return Actual365
    throw(ArgumentError("unknown day-count convention: $s"))
end

# US 30/360 bond basis: a 31st counts as the 30th; the second date's
# 31st counts as the 30th only when the (adjusted) first date is the
# 30th or 31st; a first date on the last day of February counts as
# the 30th, and a second date on the last day of February counts as
# the 30th only when the first date is also the last day of February.
function _yearfrac_thirty_360(d1::Date, d2::Date)
    y1, m1, dd1 = year(d1), month(d1), day(d1)
    y2, m2, dd2 = year(d2), month(d2), day(d2)
    feb_end_1 = m1 == 2 && dd1 == daysinmonth(d1)
    feb_end_2 = m2 == 2 && dd2 == daysinmonth(d2)
    dd1 = (dd1 == 31 || feb_end_1) ? 30 : dd1
    dd2 = ((dd2 == 31 && dd1 >= 30) || (feb_end_2 && feb_end_1)) ? 30 : dd2
    return ((y2 - y1) * 360 + (m2 - m1) * 30 + (dd2 - dd1)) / 360
end

"""
    yearfrac(d1, d2, daycount)

Year fraction between dates under the given day-count convention
(a `DayCount`, or the symbols `:thirty_360` / `:actual_365`).
"""
function yearfrac(d1::Date, d2::Date, daycount::DayCount)
    d2 >= d1 || throw(ArgumentError("d2 must not precede d1"))
    if daycount === Thirty360
        return _yearfrac_thirty_360(d1, d2)
    else
        return Dates.value(d2 - d1) / 365
    end
end

yearfrac(d1::Date, d2::Date, daycount::Symbol) =
    yearfrac(d1, d2, DayCount(daycount))

"""
    is_end_of_month(d)

True when `d` is the last day of its month. A schedule anchored on
an end-of-month issue date stays on month ends: every generated
period date is an end-of-month date.
"""
is_end_of_month(d::Date) = day(d) == daysinmonth(d)

"""
    adjust_date(d, adjustment)

Payment date for a contractual grid date `d` under a business-day
convention declared on the terms. Weekend-only: `:following` moves
a Saturday or Sunday to the next Monday, `:preceding` to the
previous Friday, and `:modified_following` follows unless that
would cross into the next month, in which case it precedes.
"""
function adjust_date(d::Date, adjustment::Symbol)
    adjustment === :unadjusted && return d
    wd = dayofweek(d)
    if adjustment === :following
        return wd == Saturday ? d + Day(2) : wd == Sunday ? d + Day(1) : d
    elseif adjustment === :preceding
        return wd == Saturday ? d - Day(1) : wd == Sunday ? d - Day(2) : d
    elseif adjustment === :modified_following
        f = adjust_date(d, :following)
        return month(f) == month(d) ? f : adjust_date(d, :preceding)
    end
    throw(ArgumentError("unknown business-day adjustment: $adjustment"))
end

"""
    DistributionPeriod(start, finish, date, regular)

One period of a distribution schedule. `start` and `finish` are the
unadjusted contractual boundaries (the previous period's finish, or
the issue date, and the grid date or the maturity date); `date` is
the payment date after any business-day adjustment declared on the
terms. `regular` is true when the period spans exactly one grid
step; a shorter final period is an irregular stub.
"""
struct DistributionPeriod
    start::Date
    finish::Date
    date::Date
    regular::Bool
end

"""
    distribution_periods(terms) -> Vector{DistributionPeriod}

The schedule as explicit periods. Dates are generated from the
unadjusted contractual anchor: period k ends at `issue + k` steps,
computed in one step from the issue date, never by stepping from an
already-clamped date (which drifts: a monthly schedule issued on
the 30th would otherwise pay on the 28th from March onward). When
the maturity date falls between grid dates, the final period is a
stub marked `regular=false`.
"""
function distribution_periods(terms::SukukTerms)
    step = Month(12 ÷ terms.freq)
    periods = DistributionPeriod[]
    start = terms.issue
    k = 1
    while true
        grid = terms.issue + step * k
        if grid >= terms.maturity
            push!(periods, DistributionPeriod(start, terms.maturity,
                                              adjust_date(terms.maturity,
                                                          terms.adjustment),
                                              grid == terms.maturity))
            break
        end
        push!(periods, DistributionPeriod(start, grid,
                                          adjust_date(grid, terms.adjustment),
                                          true))
        start = grid
        k += 1
    end
    dates = [p.date for p in periods]
    all(dates[i] < dates[i + 1] for i in 1:(length(dates) - 1)) ||
        throw(ArgumentError("business-day adjustment $(terms.adjustment) " *
                            "collapses the schedule: payment dates are " *
                            "not strictly increasing"))
    return periods
end

"""
    distribution_dates(terms)

Scheduled distribution dates from issue to maturity, one per
period: the periods' payment dates. The maturity date is always
the final unadjusted period end.
"""
function distribution_dates(terms::SukukTerms)
    return [p.date for p in distribution_periods(terms)]
end

# Distribution amount of one bullet period, before principal. A
# regular period pays the fixed periodic distribution; a stub pays
# its actual 30/360 fraction of a year at the profit rate.
function _period_distribution(terms::SukukTerms, p::DistributionPeriod)
    p.regular && return terms.face * terms.profit_rate / terms.freq
    return terms.face * terms.profit_rate *
           yearfrac(p.start, p.finish, Thirty360)
end

function _round_payment(amount::Float64, rounding::Symbol)
    rounding === :none && return amount
    rounding === :cent && return round(amount, RoundNearestTiesUp; digits=2)
    throw(ArgumentError("unknown payment rounding policy: $rounding"))
end

"""
    payment_schedule(terms; rounding=:none) -> Vector{CashFlow}

Full cash-flow schedule. Bullet structures pay the periodic profit
distribution each period and face plus the last distribution at
maturity; a final stub period pays its accrued fraction instead of
a full distribution. Amortizing (murabaha installment) structures
split the total deferred sale price, face plus total profit, into
equal installments.

Rounding policy: amounts are carried at full precision by default
(`rounding=:none`). With `rounding=:cent` each payment is rounded
to cents (ties up) at payment time; for installments, the rounding
residual is absorbed by the final payment so the schedule still
sums to the deferred sale price. Principal itself is not rounded.
"""
function payment_schedule(terms::SukukTerms; rounding::Symbol=:none)
    rounding in (:none, :cent) ||
        throw(ArgumentError("unknown payment rounding policy: $rounding"))
    periods = distribution_periods(terms)
    n = length(periods)
    if terms.amortizing
        total = terms.face * (1 + terms.profit_rate *
                              yearfrac(terms.issue, terms.maturity,
                                       Actual365))
        amounts = fill(total / n, n)
        if rounding === :cent
            amounts = _round_payment.(amounts, :cent)
            amounts[end] = _round_payment(amounts[end] +
                                          (total - sum(amounts)), :cent)
        end
        return [CashFlow(p.date, a) for (p, a) in zip(periods, amounts)]
    else
        cfs = [CashFlow(p.date,
                        _round_payment(_period_distribution(terms, p),
                                       rounding))
               for p in periods]
        cfs[end] = CashFlow(periods[end].date, cfs[end].amount + terms.face)
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

Profit accrued in the period containing `settlement`: the period's
scheduled distribution (the fixed periodic amount for a regular
period, the accrued fraction for a stub) scaled by the elapsed
share of the period under `daycount`. Zero on a distribution date
and on or after maturity.
"""
function accrued_profit(terms::SukukTerms, settlement::Date;
                        daycount=:thirty_360)
    settlement <= terms.issue &&
        throw(ArgumentError("settlement must be after issue"))
    settlement >= terms.maturity && return 0.0
    periods = distribution_periods(terms)
    i = findlast(p -> p.start <= settlement < p.finish, periods)
    p = periods[i]
    period = yearfrac(p.start, p.finish, daycount)
    period <= 0 && return 0.0
    return _period_distribution(terms, p) *
           yearfrac(p.start, settlement, daycount) / period
end
