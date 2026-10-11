"""
Portfolio helpers for sukuk holdings.

Aggregates are market-value weighted, the standard convention: a
holding twice as large counts twice as much in the portfolio yield,
duration and convexity.
"""

"""
    Holding(name, market_value, ytm, mod_duration, convexity)

One position, with its risk measures already computed (see
`analytics.jl`).
"""
struct Holding
    name::String
    market_value::Float64
    ytm::Float64
    mod_duration::Float64
    convexity::Float64

    function Holding(name, market_value, ytm, mod_duration, convexity)
        market_value = float(market_value)
        market_value < 0 && throw(ArgumentError("market_value cannot be negative"))
        return new(String(name), market_value, float(ytm),
                   float(mod_duration), float(convexity))
    end
end

"""
    portfolio_value(holdings)

Total market value.
"""
portfolio_value(holdings::Vector{Holding}) = sum(h.market_value for h in holdings)

function _weights(holdings::Vector{Holding})
    isempty(holdings) && throw(ArgumentError("no holdings given"))
    total = portfolio_value(holdings)
    total <= 0 && throw(ArgumentError("portfolio has no positive market value"))
    return [h.market_value / total for h in holdings]
end

"""
    weighted_ytm(holdings)

Market-value-weighted average yield to maturity.
"""
function weighted_ytm(holdings::Vector{Holding})
    w = _weights(holdings)
    return sum(w[i] * holdings[i].ytm for i in eachindex(holdings))
end

"""
    weighted_duration(holdings)

Market-value-weighted average modified duration, in years.
"""
function weighted_duration(holdings::Vector{Holding})
    w = _weights(holdings)
    return sum(w[i] * holdings[i].mod_duration for i in eachindex(holdings))
end

"""
    weighted_convexity(holdings)

Market-value-weighted average convexity, in years squared.
"""
function weighted_convexity(holdings::Vector{Holding})
    w = _weights(holdings)
    return sum(w[i] * holdings[i].convexity for i in eachindex(holdings))
end
