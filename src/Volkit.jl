"""
Volkit: fixed-income analytics for sukuk, in Julia.

Cash-flow modeling for ijara, murabaha and wakala structures,
profit-rate curve bootstrapping, yield and duration analytics, and
portfolio aggregation. One clean import, no derivatives anywhere.
"""
module Volkit

include("sukuk.jl")
include("cashflows.jl")
include("curve.jl")
include("analytics.jl")
include("portfolio.jl")

export sukuk_price, sukuk_ytm,
    CashFlow, SukukTerms, yearfrac, distribution_dates, payment_schedule,
    remaining_cashflows, accrued_profit,
    ZeroCurve, zero_rate, discount, forward_rate, par_rate, bootstrap,
    price_from_cashflows, ytm_from_price, current_yield,
    macaulay_duration, modified_duration, convexity, dv01,
    price_under_shift,
    Holding, portfolio_value, weighted_ytm, weighted_duration,
    weighted_convexity

end
