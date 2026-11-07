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

# ---------------------------------------------------------------------------
# Portfolio stress scenarios.
#
# The holdings above are priced off deterministic schedules: neither
# the structure label nor the cash flows say anything about default,
# collateral or legal risk. This section layers two explicit what-if
# devices over the curve pricing path: a twist of the zero curve, and
# a stylized hazard/recovery overlay on the remaining cash flows.
# A scenario loss is then attributed to the curve move alone, the
# modeled credit component alone, and the interaction of the two.
# ---------------------------------------------------------------------------

"""
    HazardOverlay(hazard, recovery)

A stylized credit overlay on a sukuk's remaining cash flows: a
constant hazard rate `hazard` (per year) and a recovery fraction
`recovery` of each flow's amount, paid instead of the flow when
default occurs first. A flow at time `t` years after settlement is
weighted by

    1 - (1 - recovery) * (1 - exp(-hazard * t)),

the survival probability `exp(-hazard * t)` plus recovery on the
defaulted share. Zero hazard makes the overlay inert at any
recovery, and recovery of 1 makes it inert at any hazard.

Both parameters are model assumptions chosen by the analyst. They
are **not** estimated from market data, and in particular not from
the January 2026 IILM auction record in `data/iilm_2026-01.json`:
that record holds observed clearing profit rates for the four
auctioned series and no default or recovery history, so nothing in
it calibrates this overlay. The overlay answers "what if losses
like this happened", never "what losses the market expects".
"""
struct HazardOverlay
    hazard::Float64
    recovery::Float64

    function HazardOverlay(hazard::Real, recovery::Real)
        hazard = float(hazard)
        recovery = float(recovery)
        isfinite(hazard) ||
            throw(ArgumentError("hazard must be finite"))
        hazard < 0 &&
            throw(ArgumentError("hazard cannot be negative"))
        isfinite(recovery) ||
            throw(ArgumentError("recovery must be finite"))
        0 <= recovery <= 1 ||
            throw(ArgumentError("recovery must lie in [0, 1]"))
        return new(hazard, recovery)
    end
end

# Expected payment fraction of a flow `t` years after settlement
# under the overlay. Written in this form so the two inert cases are
# exact, not approximate: hazard 0 gives exp(0) == 1 and the fraction
# is 1 whatever the recovery, and recovery 1 zeroes the second term
# whatever the hazard.
_overlay_fraction(overlay::HazardOverlay, t::Float64) =
    1 - (1 - overlay.recovery) * (1 - exp(-overlay.hazard * t))

"""
    stressed_price(ctx, terms, overlay)

Full price at settlement of `terms` under the curve context `ctx`
with the credit `overlay` applied to the remaining cash flows: each
flow is weighted by the overlay's expected payment fraction and
discounted on the context curve, rescaled to settlement exactly as
in `price`. With zero hazard, or with unit recovery, the result is
the unstressed `price` to the last bit.
"""
function stressed_price(ctx::ValuationContext{ZeroCurve},
                        terms::SukukTerms, overlay::HazardOverlay)
    ctx.settlement < terms.issue &&
        throw(ArgumentError("settlement must not precede issue"))
    curve = ctx.basis
    remaining = remaining_cashflows(payment_schedule(terms),
                                    ctx.settlement)
    df_settle = discount(curve, ctx.settlement)
    total = 0.0
    for cf in remaining
        t = yearfrac(ctx.settlement, cf.date, :actual_365)
        total += cf.amount * _overlay_fraction(overlay, t) *
                 discount(curve, cf.date)
    end
    return total / df_settle
end

"""
    CurveTwist(short_bps, long_bps)

A twist of the zero curve: the short end moves by `short_bps`
basis points and the long end by `long_bps`, with the shift at
each pillar interpolated linearly in pillar time between the first
and last pillars. Equal ends give a parallel shift; a single-pillar
curve takes the short-end shift. Both ends at zero leave the curve
unchanged.
"""
struct CurveTwist
    short_bps::Float64
    long_bps::Float64

    function CurveTwist(short_bps::Real, long_bps::Real)
        short_bps = float(short_bps)
        long_bps = float(long_bps)
        isfinite(short_bps) ||
            throw(ArgumentError("short_bps must be finite"))
        isfinite(long_bps) ||
            throw(ArgumentError("long_bps must be finite"))
        return new(short_bps, long_bps)
    end
end

"""
    twist_curve(curve, twist)

A copy of `curve` with every pillar's zero rate moved by the
twist's interpolated shift at that pillar. The anchor and pillars
are unchanged, and `curve` itself is not modified.
"""
function twist_curve(curve::ZeroCurve, twist::CurveTwist)
    p, z = curve.pillars, curve.zeros
    isempty(p) && throw(ArgumentError("curve has no pillars"))
    length(p) == 1 &&
        return ZeroCurve(curve.anchor, copy(p),
                         [z[1] + twist.short_bps / 1e4])
    span = p[end] - p[1]
    zeros = [z[i] + (twist.short_bps +
                     (twist.long_bps - twist.short_bps) *
                     (p[i] - p[1]) / span) / 1e4
             for i in eachindex(p)]
    return ZeroCurve(curve.anchor, copy(p), zeros)
end

"""
    StressScenario(twist, overlay)

One portfolio stress scenario: a `CurveTwist` of the pricing curve
combined with a `HazardOverlay` on the cash flows. The no-argument
form is the empty scenario (no twist, zero hazard) and reprices
every instrument at its base price.
"""
struct StressScenario
    twist::CurveTwist
    overlay::HazardOverlay
end

StressScenario() = StressScenario(CurveTwist(0.0, 0.0),
                                  HazardOverlay(0.0, 0.0))

"""
    StressResult(base_price, stressed_price, rate_loss, credit_loss, interaction_loss, total_loss)

The outcome of one scenario on one instrument: the base and
stressed full prices, and the loss attribution. `rate_loss` is the
loss from the curve twist alone (overlay off), `credit_loss` the
loss from the overlay alone (curve untwisted), and
`interaction_loss` the remainder, so the three sum to
`total_loss`, the base price minus the stressed price. A component
is negative when that leg of the scenario gains money on its own
(a downward twist, for instance).
"""
struct StressResult
    base_price::Float64
    stressed_price::Float64
    rate_loss::Float64
    credit_loss::Float64
    interaction_loss::Float64
    total_loss::Float64
end

"""
    stress_scenario(ctx, terms, scenario)

Stress one instrument under `scenario` in the curve context `ctx`
and attribute the loss. The stressed price applies the twist and
the overlay together; the two single-leg prices behind the
attribution apply each on its own.
"""
function stress_scenario(ctx::ValuationContext{ZeroCurve},
                         terms::SukukTerms, scenario::StressScenario)
    base = price(ctx, terms)
    twisted = ValuationContext(ctx.settlement,
                               twist_curve(ctx.basis, scenario.twist);
                               daycount=ctx.daycount)
    rate_price = price(twisted, terms)
    credit_price = stressed_price(ctx, terms, scenario.overlay)
    stressed = stressed_price(twisted, terms, scenario.overlay)
    rate_loss = base - rate_price
    credit_loss = base - credit_price
    total_loss = base - stressed
    interaction_loss = total_loss - rate_loss - credit_loss
    return StressResult(base, stressed, rate_loss, credit_loss,
                        interaction_loss, total_loss)
end

"""
    PortfolioStress(results, base_value, stressed_value, rate_loss, credit_loss, interaction_loss, total_loss)

The outcome of one scenario on a whole portfolio: one
`StressResult` per instrument, in the order the instruments were
given, and the portfolio totals, which are the sums of the
per-instrument figures with the same attribution split.
"""
struct PortfolioStress
    results::Vector{StressResult}
    base_value::Float64
    stressed_value::Float64
    rate_loss::Float64
    credit_loss::Float64
    interaction_loss::Float64
    total_loss::Float64
end

"""
    stress_scenario(ctx, terms::Vector, scenario)

Stress every instrument in `terms` under `scenario` and aggregate
the per-instrument results into a `PortfolioStress`.
"""
function stress_scenario(ctx::ValuationContext{ZeroCurve},
                         terms::Vector{SukukTerms},
                         scenario::StressScenario)
    isempty(terms) && throw(ArgumentError("no instruments given"))
    results = [stress_scenario(ctx, t, scenario) for t in terms]
    return PortfolioStress(results,
                           sum(r.base_price for r in results),
                           sum(r.stressed_price for r in results),
                           sum(r.rate_loss for r in results),
                           sum(r.credit_loss for r in results),
                           sum(r.interaction_loss for r in results),
                           sum(r.total_loss for r in results))
end
