"""
Quote-aware risk: from published quotes, through recalibration, to value.

A bootstrapped curve is fitted to quotes, so a quote move does not
just reprice one instrument: it refits the curve, and every pillar
the refit moves reprices everything valued on the curve. This file
answers the question in that order: how much does each quote move
each calibrated zero rate, and how much does it move a target
sukuk's value?

The calibration is the sequential bootstrap of `curve.jl`, read as
a system of residual equations, one per instrument:

    F_i(z, q) = PV_i(z) - P_i(q_i) = 0

where `z` is the vector of zero rates at the pillars, `q` is the
vector of quotes, `PV_i(z)` is the model price of instrument `i`
on the curve with pillars `z`, and `P_i(q_i)` is the price its
quote implies. The residual Jacobian `J = dF/dz` is derived
analytically from the linear zero-rate interpolation (each cash
flow contributes through the interpolation weights of its date),
and the quote sensitivities follow by implicit differentiation:

    dz/dq = -J^(-1) * dF/dq

which is valid exactly when `J` is nonsingular. The condition
number of `J` is always reported, and a singular `J` is reported
with a failure flag and NaN sensitivities, never a fitted number.

Two conventions are stated rather than left implicit:

- Quote to price. A `:price` quote is a quoted price per the
  instrument's face: the price is the quote, and dP/dq is 1. A
  `:simple_act_365_rate` quote is a published simple annualized
  profit rate under Actual/365, the convention of the IILM record
  in `marketdata.jl`: price = face / (1 + r * T) with `T` the
  Actual/365 year fraction from the curve anchor to the
  instrument's final maturity, and dP/dq is
  -face * T / (1 + r * T)^2. A rate quote therefore applies to the
  whole instrument price as one simple discount, whatever the
  instrument's own cash-flow shape; for a coupon instrument that
  is a modeling choice, stated here, not a market fact.
- DV01. `zero_dv01` is the fall in the target value per one basis
  point rise in one pillar's zero rate, holding the other pillars
  fixed. `quote_dv01` is the fall in the target value per one
  basis point rise in one quote, through recalibration: the quote
  moves every pillar the calibration moves, and the value moves
  with all of them. One basis point of a rate quote is 1e-4 of
  rate; one basis point of a price quote is 0.01 price units
  (0.01% of a 100 face). The two DV01s are different quantities
  and are never mixed: a quote that moves two pillars has a quote
  DV01 no single zero-node DV01 can reproduce.

Automatic differentiation is used experimentally, and only where
it can reach. `pv_at_zeros` is a small generic present-value
function over plain vectors, written so ForwardDiff can
differentiate it with respect to the zero rates; it is the
differentiable pricing component, and the tests compare its
ForwardDiff Jacobian against the analytic residual Jacobian.
ForwardDiff is deliberately not run through the `ZeroCurve`
constructor, which is typed Float64, or through the bisection
solver, which branches on values: the implicit differentiation
above is the route from quotes to zeros, and the analytic
Jacobian is the object the differentiation checks.
"""

using Dates
using LinearAlgebra

"""
    QuoteInput(kind, value; face=100.0)

One published quote for one calibrating instrument. `kind` is
`:price` (the quote is a quoted price per `face`) or
`:simple_act_365_rate` (the quote is a published simple annualized
profit rate under Actual/365). `face` must be positive and finite.
A price quote must be positive and finite; a rate quote must lie
in (0, 1), the range the auction record loader enforces.
"""
struct QuoteInput
    kind::Symbol
    value::Float64
    face::Float64

    function QuoteInput(kind::Symbol, value::Real; face::Real=100.0)
        kind in (:price, :simple_act_365_rate) ||
            throw(ArgumentError("unknown quote kind: $kind"))
        v = float(value)
        f = float(face)
        (isfinite(f) && f > 0) ||
            throw(ArgumentError("quote face must be positive and finite"))
        if kind === :price
            (isfinite(v) && v > 0) ||
                throw(ArgumentError("quoted price must be positive and finite"))
        else
            (isfinite(v) && 0 < v < 1) ||
                throw(ArgumentError(
                    "simple-rate quote must lie in (0, 1), got $v"))
        end
        return new(kind, v, f)
    end
end

"""
    quote_price(quote, maturity, anchor) -> Float64

The price a quote implies for an instrument maturing at
`maturity`, on a curve anchored at `anchor`. A `:price` quote is
the price itself. A `:simple_act_365_rate` quote `r` gives
`face / (1 + r * T)` with `T` the Actual/365 year fraction from
the anchor to the maturity date.
"""
function quote_price(q::QuoteInput, maturity::Date, anchor::Date)
    if q.kind === :price
        return q.value
    end
    T = yearfrac(anchor, maturity, :actual_365)
    return q.face / (1 + q.value * T)
end

"""
    quote_price_derivative(quote, maturity, anchor) -> Float64

dP/dq for a quote: the change in the implied price per unit move
in the quote. It is 1 for a `:price` quote, and
`-face * T / (1 + r * T)^2` for a `:simple_act_365_rate` quote,
with `T` the Actual/365 year fraction from the anchor to the
maturity date.
"""
function quote_price_derivative(q::QuoteInput, maturity::Date, anchor::Date)
    if q.kind === :price
        return 1.0
    end
    T = yearfrac(anchor, maturity, :actual_365)
    return -q.face * T / (1 + q.value * T)^2
end

# One basis point of a quote, in quote units: 1e-4 of rate for a
# simple-rate quote, 0.01 price units for a price quote.
function _quote_bump_unit(q::QuoteInput)
    return q.kind === :price ? 0.01 : 1e-4
end

"""
    auction_quotes(record; face=100.0) -> Vector{QuoteInput}

The quotes of an auction record, in instrument order: each
series' published profit rate as a `:simple_act_365_rate` quote,
under the record's own convention.
"""
function auction_quotes(record::AuctionRecord; face::Real=100.0)
    return QuoteInput[QuoteInput(:simple_act_365_rate, i.profit_rate;
                                 face=face)
                      for i in record.instruments]
end

# Linear-interpolation weights of the pillars at year fraction `t`:
# the weight each pillar's zero rate carries in the interpolated
# zero rate at `t`. At or before the first pillar the first pillar
# carries it all; at or past the last pillar the last one does; at
# t = 0 the discount factor is 1 whatever the curve, so no pillar
# carries anything. Between pillars the two neighbours share it in
# proportion to distance.
function _interp_weights(pillars::Vector{Float64}, t::Float64)
    n = length(pillars)
    w = zeros(n)
    t == 0 && return w
    t <= pillars[1] && (w[1] = 1.0; return w)
    t >= pillars[end] && (w[end] = 1.0; return w)
    i = searchsortedlast(pillars, t)
    frac = (t - pillars[i]) / (pillars[i + 1] - pillars[i])
    w[i] = 1 - frac
    w[i + 1] = frac
    return w
end

# Zero rate at year fraction `t` by linear interpolation of the
# pillar rates. Generic over the element type of `zeros`, so
# ForwardDiff dual numbers flow through it; at t = 0 the rate is
# not defined by the pillars, and zero is returned because the
# discount factor there is 1 whatever the rate.
function _zero_rate_at(pillars::Vector{Float64}, zeros::AbstractVector,
                       t::Float64)
    t == 0 && return zero(eltype(zeros))
    t <= pillars[1] && return zeros[1]
    t >= pillars[end] && return zeros[end]
    i = searchsortedlast(pillars, t)
    frac = (t - pillars[i]) / (pillars[i + 1] - pillars[i])
    return zeros[i] * (1 - frac) + zeros[i + 1] * frac
end

"""
    pv_at_zeros(pillars, zeros, times, amounts) -> Real

Present value of cash flows `amounts` at year fractions `times`,
discounted on the linear-zero curve with pillars `pillars` and
zero rates `zeros`: each flow contributes
`amount * exp(-r(t) * t)` with `r(t)` the interpolated zero rate.
Generic over the element type of `zeros`, so ForwardDiff can
differentiate it with respect to the zero rates; `times` and
`amounts` stay plain Float64. A flow at t = 0 contributes its
amount undiscounted.
"""
function pv_at_zeros(pillars::Vector{Float64}, zeros::AbstractVector,
                     times::Vector{Float64}, amounts::Vector{Float64})
    length(times) == length(amounts) ||
        throw(ArgumentError("times and amounts must match in length"))
    total = zero(eltype(zeros))
    for (a, t) in zip(amounts, times)
        total += a * exp(-_zero_rate_at(pillars, zeros, t) * t)
    end
    return total
end

"""
    residual_jacobian(instruments, curve) -> Matrix{Float64}

The calibration residual Jacobian `J` for `instruments` (the same
`(cashflows, price)` pairs `bootstrap` takes, in any order) on
`curve`: `J[i, j]` is d/dz_j of the model price of instrument `i`,
with `z` the pillar zero rates. Derived analytically: each cash
flow at year fraction `t` contributes
`-amount * t * exp(-r(t) * t)` times the interpolation weight of
pillar `j` at `t`, so a flow between pillars loads both
neighbours, a flow on a pillar loads that pillar alone, and a
flow at the anchor loads nothing. The matrix is lower triangular
in maturity order, because an instrument's price only involves
pillars at or before its own maturity.
"""
function residual_jacobian(instruments::Vector{Tuple{Vector{CashFlow},Float64}},
                           curve::ZeroCurve)
    ordered = _validate_instruments(instruments, curve.anchor)
    n = length(ordered)
    pillars = curve.pillars
    length(pillars) == n || throw(ArgumentError(
        "curve has $(length(pillars)) pillars for $n instruments; " *
        "the residual Jacobian needs one pillar per instrument"))
    J = zeros(n, n)
    for (i, (cfs, _)) in enumerate(ordered)
        times = [yearfrac(curve.anchor, cf.date, :actual_365) for cf in cfs]
        for (cf, t) in zip(cfs, times)
            t == 0 && continue
            df = exp(-zero_rate(curve, t) * t)
            w = _interp_weights(pillars, t)
            for j in 1:n
                w[j] == 0 && continue
                J[i, j] += -cf.amount * t * df * w[j]
            end
        end
    end
    return J
end

"""
    implicit_quote_sensitivities(jacobian, quote_jacobian) -> NamedTuple

Differentiate the calibration residuals implicitly: with `J` the
residual Jacobian dF/dz and `G` the quote Jacobian dF/dq, the
quote sensitivities are `dz/dq = -J^(-1) * G`. The result carries:

- `dz_dq`: the sensitivity matrix, or all NaN when singular.
- `condition_number`: the 2-norm condition number of `J`
  (Inf when `J` is singular).
- `singular`: true when `J` is singular, so no unique
  sensitivity exists.
- `message`: a short statement of the outcome.

A singular Jacobian is a reported failure, not an exception:
the caller gets the flag, the condition number and NaN
sensitivities, and decides what to do with them.
"""
function implicit_quote_sensitivities(jacobian::AbstractMatrix{<:Real},
                                      quote_jacobian::AbstractMatrix{<:Real})
    J = Matrix{Float64}(jacobian)
    G = Matrix{Float64}(quote_jacobian)
    n, m = size(J)
    n == m || throw(ArgumentError("residual Jacobian must be square"))
    size(G) == (n, n) || throw(ArgumentError(
        "quote Jacobian must match the residual Jacobian, " *
        "got $(size(G)) for a $n by $n residual Jacobian"))
    all(isfinite, J) && all(isfinite, G) ||
        throw(ArgumentError("Jacobians must be finite"))
    κ = cond(J)
    if !isfinite(κ)
        return (dz_dq=fill(NaN, n, n), condition_number=κ, singular=true,
                message="residual Jacobian is singular (condition " *
                        "number $κ): no unique quote sensitivity exists")
    end
    dz_dq = try
        -(J \ G)
    catch err
        err isa SingularException || rethrow()
        return (dz_dq=fill(NaN, n, n), condition_number=κ, singular=true,
                message="residual Jacobian is singular (condition " *
                        "number $κ): no unique quote sensitivity exists")
    end
    return (dz_dq=dz_dq, condition_number=κ, singular=false,
            message="residual Jacobian is nonsingular; condition number $κ")
end

# Target validation: a value to move must exist, be positive and
# finite, be dated on or after the anchor, and run in increasing
# date order.
function _validate_target(cfs::Vector{CashFlow}, anchor::Date)
    isempty(cfs) && throw(ArgumentError("target has no cash flows"))
    for cf in cfs
        (isfinite(cf.amount) && cf.amount > 0) || throw(ArgumentError(
            "target cash-flow amounts must be positive and finite"))
        cf.date < anchor && throw(ArgumentError(
            "target cash flow dated $(cf.date) precedes the curve anchor $anchor"))
    end
    dates = [cf.date for cf in cfs]
    all(dates[i] < dates[i + 1] for i in 1:(length(dates) - 1)) ||
        throw(ArgumentError(
            "target cash flows must be in strictly increasing date order"))
    return nothing
end

"""
    quote_risk(quoted, anchor, target_cashflows; bump_bps=1.0) -> NamedTuple

How much each quote moves each calibrated zero rate and a target
sukuk's value. `quoted` is one `(cashflows, quote)` pair per
calibrating instrument, in any order; `target_cashflows` is the
cash-flow schedule of the sukuk being valued. The result carries:

- `curve`: the curve bootstrapped at the given quotes.
- `pillars`, `zeros`: the fitted pillars and zero rates.
- `jacobian`: the analytic residual Jacobian dF/dz.
- `quote_jacobian`: dF/dq, diagonal, with entry `-dP_i/dq_i`.
- `condition_number`, `singular`: the Jacobian condition number
  and the singular flag from `implicit_quote_sensitivities`.
- `dz_dq`: d(zero rate)/d(quote), one row per pillar, one column
  per quote (NaN when singular).
- `target_value`: the target price on the fitted curve.
- `target_gradient`: d(target value)/d(zero rate), one entry per
  pillar.
- `zero_dv01`: fall in target value per 1bp rise in one pillar's
  zero rate, other pillars held fixed.
- `quote_dv01`: fall in target value per 1bp rise in one quote,
  through recalibration. One basis point of a rate quote is 1e-4
  of rate; one basis point of a price quote is 0.01 price units.
  Either figure is negative when the value rises as the quote or
  rate rises, which happens when a quote moves a later pillar the
  other way: a higher early quote can lower a later pillar through
  a fixed-price calibrating instrument, and a long target then
  gains more from the later pillar than it loses on the early one.
- `bump_check`: the end-to-end bump-and-rebootstrap comparison
  (central differences at `bump_bps` basis points per quote),
  with one row per quote, `max_relative_error` over all rows,
  and `agrees` true when that error is at most 1e-5. When the
  Jacobian is singular the comparison is skipped and `agrees`
  is false.
- `message`: a short statement of the outcome.

Malformed quote sets are rejected with the same validation errors
as `bootstrap` (empty schedules, unordered or duplicated
cash-flow dates, non-positive amounts, cash flows before the
anchor, duplicate maturities, non-positive or non-finite prices);
whether a well-formed set has a solution is answered by the
calibration itself.
"""
function quote_risk(quoted::Vector{Tuple{Vector{CashFlow},QuoteInput}},
                    anchor::Date, target_cashflows::Vector{CashFlow};
                    bump_bps::Real=1.0)
    isempty(quoted) && throw(ArgumentError("no instruments given"))
    (isfinite(bump_bps) && bump_bps > 0) ||
        throw(ArgumentError("bump_bps must be positive and finite"))
    _validate_target(target_cashflows, anchor)
    for (cfs, _) in quoted
        isempty(cfs) &&
            throw(ArgumentError("an instrument has no cash flows"))
    end
    # Prices from quotes, then the shared validation and ordering:
    # quotes travel with their instrument by maturity date, and
    # maturities are unique once validation passes.
    by_maturity = Dict{Date,QuoteInput}()
    priced = Tuple{Vector{CashFlow},Float64}[]
    for (cfs, q) in quoted
        maturity = cfs[end].date
        haskey(by_maturity, maturity) && throw(ArgumentError(
            "duplicate instrument maturity: two quotes share a maturity " *
            "date, and the sequential solver fits one pillar per maturity " *
            "(no joint-fit method is selected)"))
        by_maturity[maturity] = q
        push!(priced, (cfs, quote_price(q, maturity, anchor)))
    end
    ordered = _validate_instruments(priced, anchor)
    quotes = [by_maturity[cfs[end].date] for (cfs, _) in ordered]
    curve = bootstrap(ordered, anchor)
    pillars, zs = curve.pillars, curve.zeros
    n = length(ordered)
    J = residual_jacobian(ordered, curve)
    G = zeros(n, n)
    for i in 1:n
        (cfs, _) = ordered[i]
        G[i, i] = -quote_price_derivative(quotes[i], cfs[end].date, anchor)
    end
    sens = implicit_quote_sensitivities(J, G)
    dz_dq = sens.dz_dq
    # Target value and its pillar gradient, by the same
    # interpolation weights as the Jacobian.
    target_times = [yearfrac(anchor, cf.date, :actual_365)
                    for cf in target_cashflows]
    target_amounts = [cf.amount for cf in target_cashflows]
    target_value = pv_at_zeros(pillars, zs, target_times, target_amounts)
    gradient = zeros(n)
    for (cf, t) in zip(target_cashflows, target_times)
        t == 0 && continue
        df = exp(-zero_rate(curve, t) * t)
        w = _interp_weights(pillars, t)
        for j in 1:n
            w[j] == 0 && continue
            gradient[j] += -cf.amount * t * df * w[j]
        end
    end
    zero_dv01 = -gradient .* 1e-4
    quote_dv01 = fill(NaN, n)
    if !sens.singular
        for j in 1:n
            quote_dv01[j] = -(gradient' * dz_dq[:, j]) *
                            _quote_bump_unit(quotes[j])
        end
    end
    # Bump-and-rebootstrap: central differences. Each quote is
    # moved up and down by bump_bps basis points, the curve is
    # rebuilt from the moved quotes, and the numerical total
    # derivatives of the zeros and the target value are compared
    # with the implicit ones. Skipped when singular.
    bump_rows = NamedTuple[]
    max_relative_error = NaN
    agrees = false
    if !sens.singular
        max_relative_error = 0.0
        for j in 1:n
            h = float(bump_bps) * _quote_bump_unit(quotes[j])
            moved = try
                q = quotes[j]
                up = QuoteInput(q.kind, q.value + h; face=q.face)
                dn = QuoteInput(q.kind, q.value - h; face=q.face)
                ups = [(cfs, i == j ? up : quotes[i])
                       for (i, (cfs, _)) in enumerate(ordered)]
                dns = [(cfs, i == j ? dn : quotes[i])
                       for (i, (cfs, _)) in enumerate(ordered)]
                price_of(pairs) = Tuple{Vector{CashFlow},Float64}[
                    (cfs, quote_price(qq, cfs[end].date, anchor))
                    for (cfs, qq) in pairs]
                curve_up = bootstrap(price_of(ups), anchor)
                curve_dn = bootstrap(price_of(dns), anchor)
                v_up = pv_at_zeros(pillars, curve_up.zeros,
                                   target_times, target_amounts)
                v_dn = pv_at_zeros(pillars, curve_dn.zeros,
                                   target_times, target_amounts)
                (curve_up, curve_dn, v_up, v_dn)
            catch err
                err isa ArgumentError || rethrow()
                nothing
            end
            if moved === nothing
                push!(bump_rows, (quote_index=j, z_error=NaN,
                                  value_error=NaN, status=:bump_failed))
                max_relative_error = Inf
                continue
            end
            (curve_up, curve_dn, v_up, v_dn) = moved
            num_dz = (curve_up.zeros .- curve_dn.zeros) ./ (2h)
            num_dv = (v_up - v_dn) / (2h)
            pred_dz = dz_dq[:, j]
            denom_z = max(maximum(abs.(num_dz)), 1e-12)
            err_z = maximum(abs.(pred_dz .- num_dz)) / denom_z
            pred_dv = gradient' * pred_dz
            err_v = abs(pred_dv - num_dv) / max(abs(num_dv), 1e-12)
            push!(bump_rows, (quote_index=j, z_error=err_z,
                              value_error=err_v, status=:ok))
            max_relative_error = max(max_relative_error, err_z, err_v)
        end
        agrees = isfinite(max_relative_error) &&
                 max_relative_error <= 1e-5
    end
    message = sens.message * "; bump-and-rebootstrap " *
              (sens.singular ? "skipped (singular Jacobian)" :
               agrees ? "agrees to relative $max_relative_error" :
               "disagrees: largest relative error $max_relative_error")
    return (anchor=anchor, curve=curve, pillars=pillars, zeros=zs,
            jacobian=J, quote_jacobian=G,
            condition_number=sens.condition_number, singular=sens.singular,
            dz_dq=dz_dq, target_value=target_value,
            target_gradient=gradient, zero_dv01=zero_dv01,
            quote_dv01=quote_dv01,
            bump_check=(rows=bump_rows,
                        max_relative_error=max_relative_error,
                        agrees=agrees),
            message=message)
end
