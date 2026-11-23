"""
Curve-node risk attribution from full cash flows.

A portfolio is more than its average yield and duration: what
matters when the curve moves is how much of its value sits on
each pillar of the term structure. This file prices an arbitrary
dated cash-flow vector on a `ZeroCurve` and attributes the value
to the curve nodes, analytically.

The sensitivity is exact for the piecewise-linear zero
interpolation the curve uses. A cash flow of `amount` at year
fraction `t` contributes `amount * exp(-r(t) * t)` to the price,
with `r(t)` the interpolated zero rate, so

    dPV/dz_j = -amount * t * exp(-r(t) * t) * w_j(t)

where `w_j(t)` is the interpolation weight of pillar `j` at `t`:
1 on its own pillar, shared between the two neighbours between
pillars, 1 on the last pillar past it, and 0 for a flow at the
anchor (worth its amount whatever the curve). Summing over the
flows gives the node sensitivities; summing those gives the
derivative of a parallel shift of every zero rate at once.

Two conventions are stated rather than left implicit:

- Bumps are zero-rate moves, not market-quote moves. A node
  sensitivity says what happens when one pillar's zero rate
  moves and the others stay put. What happens when a published
  quote moves is a different question: the quote refits the
  curve, and every pillar the refit moves reprices the value.
  That is `quote_risk` in `quote_risk.jl`, kept separate here.
- Full reprice is the ground truth for finite shocks. The
  first-order node decomposition is exact only for an
  infinitesimal move; for a finite parallel shock the report
  carries both the repriced price and the first-order price, and
  the nonlinear residual between them, so the size of the
  approximation is visible rather than assumed away.
"""

using Dates

# Analytic gradient of the present value of the flows at `times`
# with `amounts` on `curve`: one entry per pillar. Uses the same
# interpolation weights as the residual Jacobian in
# `quote_risk.jl`, so the two agree by construction.
function _node_gradient(times::Vector{Float64}, amounts::Vector{Float64},
                        curve::ZeroCurve)
    pillars = curve.pillars
    g = zeros(length(pillars))
    for (a, t) in zip(amounts, times)
        t == 0 && continue
        df = exp(-zero_rate(curve, t) * t)
        w = _interp_weights(pillars, t)
        for j in eachindex(g)
            w[j] == 0 && continue
            g[j] += -a * t * df * w[j]
        end
    end
    return g
end

# Central finite-difference check of an analytic gradient against
# a pricing function over the pillar zero rates. `price_fn(z)` is
# the price on the curve with zero rates `z`. Returns one row per
# pillar plus the largest relative and absolute errors. A row
# agrees when its relative error is at most 1e-5 or its absolute
# error is at most 1e-5: a pillar an exposure barely touches has
# a meaningless relative error, and the absolute bar is what
# matters there.
function _fd_check(price_fn, base_zeros::Vector{Float64},
                   gradient::Vector{Float64}, bump::Float64)
    rows = NamedTuple[]
    max_rel = 0.0
    max_abs = 0.0
    for j in eachindex(gradient)
        up = copy(base_zeros)
        dn = copy(base_zeros)
        up[j] += bump
        dn[j] -= bump
        fd = (price_fn(up) - price_fn(dn)) / (2 * bump)
        abs_err = abs(gradient[j] - fd)
        rel_err = abs_err / max(abs(fd), 1e-12)
        agrees = rel_err <= 1e-5 || abs_err <= 1e-5
        push!(rows, (pillar_index=j, analytic=gradient[j],
                     finite_difference=fd, absolute_error=abs_err,
                     relative_error=rel_err, agrees=agrees))
        max_rel = max(max_rel, rel_err)
        max_abs = max(max_abs, abs_err)
    end
    return (rows=rows, max_relative_error=max_rel,
            max_absolute_error=max_abs,
            agrees=all(r -> r.agrees, rows))
end

# The shared report body once a price, an analytic gradient and a
# pricing function over the pillar zero rates are known: the
# finite-difference check, the parallel-shift derivative (analytic
# and finite difference), and the finite-shock decomposition.
function _risk_report(price::Float64, gradient::Vector{Float64},
                      base_zeros::Vector{Float64}, price_fn,
                      bump_bps::Real, shock_bps::Real)
    bump = float(bump_bps) / 1e4
    fd = _fd_check(price_fn, base_zeros, gradient, bump)
    parallel_gradient = sum(gradient)
    h = bump
    up = base_zeros .+ h
    dn = base_zeros .- h
    parallel_fd = (price_fn(up) - price_fn(dn)) / (2 * h)
    parallel_abs = abs(parallel_gradient - parallel_fd)
    parallel_rel = parallel_abs / max(abs(parallel_fd), 1e-12)
    parallel_check = (finite_difference=parallel_fd,
                      absolute_error=parallel_abs,
                      relative_error=parallel_rel,
                      agrees=parallel_rel <= 1e-5 ||
                             parallel_abs <= 1e-5)
    shock = float(shock_bps) / 1e4
    repriced = price_fn(base_zeros .+ shock)
    first_order_price = price + parallel_gradient * shock
    first_order_change = parallel_gradient * shock
    actual_change = repriced - price
    residual = repriced - first_order_price
    message = "node sensitivities agree with central finite " *
              "differences to relative $(fd.max_relative_error); " *
              "a $(shock_bps)bp parallel shock reprices to " *
              "$repriced against a first-order $first_order_price " *
              "(residual $residual)"
    return (price=price, gradient=gradient,
            node_dv01=-gradient .* 1e-4,
            parallel_gradient=parallel_gradient,
            parallel_dv01=-parallel_gradient * 1e-4,
            parallel_fd_gradient=parallel_fd,
            parallel_check=parallel_check, fd_check=fd,
            shock=(shock_bps=float(shock_bps),
                   repriced_price=repriced,
                   first_order_price=first_order_price,
                   first_order_change=first_order_change,
                   actual_change=actual_change,
                   residual=residual),
            message=message)
end

function _check_bump_shock(bump_bps::Real, shock_bps::Real)
    (isfinite(bump_bps) && bump_bps > 0) ||
        throw(ArgumentError("bump_bps must be positive and finite"))
    (isfinite(shock_bps) && shock_bps != 0) ||
        throw(ArgumentError("shock_bps must be finite and nonzero"))
    return nothing
end

"""
    node_sensitivities(cfs, curve) -> Vector{Float64}

dPV/dz for the cash flows `cfs` on `curve`: one entry per pillar,
in pillar order, in price units per unit move in the pillar's
zero rate. Derived analytically from the piecewise-linear zero
interpolation (see the file header). A flow at the anchor loads
no pillar; a flow past the last pillar loads only that pillar.
"""
function node_sensitivities(cfs::Vector{CashFlow}, curve::ZeroCurve)
    _validate_target(cfs, curve.anchor)
    times = [yearfrac(curve.anchor, cf.date, :actual_365) for cf in cfs]
    amounts = [cf.amount for cf in cfs]
    return _node_gradient(times, amounts, curve)
end

"""
    node_dv01(cfs, curve) -> Vector{Float64}

The fall in the value of `cfs` on `curve` per one basis point
rise in one pillar's zero rate, the other pillars held fixed.
Positive when the value falls as the pillar rises, which is the
usual case; a pillar that touches no flow leaves the value
exactly unchanged.
"""
function node_dv01(cfs::Vector{CashFlow}, curve::ZeroCurve)
    return -node_sensitivities(cfs, curve) .* 1e-4
end

"""
    curve_risk(cfs, curve; bump_bps=1.0, shock_bps=100.0) -> NamedTuple

Curve-node risk attribution for the cash flows `cfs` on `curve`.
The result carries:

- `price`: the full price of the flows on the curve.
- `gradient`: the analytic node sensitivities
  (`node_sensitivities`), one entry per pillar.
- `node_dv01`: the fall in value per 1bp rise in one pillar.
- `parallel_gradient` / `parallel_dv01`: the sum of the node
  sensitivities and its DV01 form, the derivative of a parallel
  shift of every zero rate at once.
- `parallel_fd_gradient` / `parallel_check`: the same derivative
  by central finite differences, with its errors and agreement.
- `fd_check`: the per-pillar central finite-difference
  comparison of the analytic gradient (see `_fd_check`); `agrees`
  is true when every row meets the 1e-5 bar.
- `shock`: the finite-shock decomposition at `shock_bps` basis
  points in parallel: the full `repriced_price`, the
  `first_order_price` from the node decomposition, the
  `first_order_change` and `actual_change`, and the nonlinear
  `residual` between the reprice and the first-order price.
- `message`: a short statement of the outcome.

`bump_bps` is the central-difference step per pillar; the
default 1bp keeps truncation error far below the 1e-5 bar.
"""
function curve_risk(cfs::Vector{CashFlow}, curve::ZeroCurve;
                    bump_bps::Real=1.0, shock_bps::Real=100.0)
    _check_bump_shock(bump_bps, shock_bps)
    _validate_target(cfs, curve.anchor)
    price = price_from_curve(cfs, curve)
    gradient = node_sensitivities(cfs, curve)
    price_fn(z) = price_from_curve(
        cfs, ZeroCurve(curve.anchor, copy(curve.pillars), z))
    return _risk_report(price, gradient, curve.zeros, price_fn,
                        bump_bps, shock_bps)
end

# Price and analytic gradient of flows valued at a settlement
# date on a curve anchored at or before it. The price is the
# anchor present value rescaled by the discount factor to
# settlement, so the gradient has two parts: the flows'
# sensitivities rescaled the same way, plus the settlement
# factor's own sensitivity, `price * t_settle * w_j(t_settle)`.
# With settlement on the anchor the second part is exactly zero.
function _settlement_price_gradient(cfs::Vector{CashFlow},
                                    ctx::ValuationContext{ZeroCurve})
    curve = ctx.basis
    remaining = [cf for cf in cfs if cf.date > ctx.settlement]
    pv = price(ctx, cfs)
    times = [yearfrac(curve.anchor, cf.date, :actual_365)
             for cf in remaining]
    amounts = [cf.amount for cf in remaining]
    df_settle = discount(curve, ctx.settlement)
    gradient = _node_gradient(times, amounts, curve) ./ df_settle
    settle_t = yearfrac(curve.anchor, ctx.settlement, :actual_365)
    if settle_t > 0
        w = _interp_weights(curve.pillars, settle_t)
        for j in eachindex(gradient)
            gradient[j] += pv * settle_t * w[j]
        end
    end
    return (price=pv, gradient=gradient)
end

"""
    node_sensitivities(ctx, terms) / node_sensitivities(ctx, cfs)

Node sensitivities of the settlement full price under the curve
context `ctx`: d(price)/dz per pillar, including the settlement
discount factor's own sensitivity when the curve anchors before
settlement. With terms, the remaining flows after settlement are
valued; with raw cash flows, the flows dated after settlement.
"""
function node_sensitivities(ctx::ValuationContext{ZeroCurve},
                            terms::SukukTerms)
    ctx.settlement < terms.issue &&
        throw(ArgumentError("settlement must not precede issue"))
    cfs = remaining_cashflows(payment_schedule(terms), ctx.settlement)
    return _settlement_price_gradient(cfs, ctx).gradient
end

function node_sensitivities(ctx::ValuationContext{ZeroCurve},
                            cfs::Vector{CashFlow})
    return _settlement_price_gradient(cfs, ctx).gradient
end

"""
    node_dv01(ctx, terms) / node_dv01(ctx, cfs)

The fall in the settlement full price per one basis point rise
in one pillar's zero rate, under the curve context `ctx`.
"""
function node_dv01(ctx::ValuationContext{ZeroCurve}, terms::SukukTerms)
    return -node_sensitivities(ctx, terms) .* 1e-4
end

function node_dv01(ctx::ValuationContext{ZeroCurve},
                    cfs::Vector{CashFlow})
    return -node_sensitivities(ctx, cfs) .* 1e-4
end

"""
    curve_risk(ctx, terms; bump_bps=1.0, shock_bps=100.0) -> NamedTuple
    curve_risk(ctx, cfs; bump_bps=1.0, shock_bps=100.0) -> NamedTuple

Curve-node risk attribution for the settlement full price under
the curve context `ctx`, with the same fields as
`curve_risk(cfs, curve)`. The finite-difference check reprices
through the context, so it exercises the settlement rescaling
as well as the curve.
"""
function curve_risk(ctx::ValuationContext{ZeroCurve},
                    terms::SukukTerms; bump_bps::Real=1.0,
                    shock_bps::Real=100.0)
    _check_bump_shock(bump_bps, shock_bps)
    ctx.settlement < terms.issue &&
        throw(ArgumentError("settlement must not precede issue"))
    cfs = remaining_cashflows(payment_schedule(terms), ctx.settlement)
    return _curve_risk_context(ctx, cfs, bump_bps, shock_bps)
end

function curve_risk(ctx::ValuationContext{ZeroCurve},
                    cfs::Vector{CashFlow}; bump_bps::Real=1.0,
                    shock_bps::Real=100.0)
    _check_bump_shock(bump_bps, shock_bps)
    return _curve_risk_context(ctx, cfs, bump_bps, shock_bps)
end

function _curve_risk_context(ctx::ValuationContext{ZeroCurve},
                             cfs::Vector{CashFlow}, bump_bps, shock_bps)
    pg = _settlement_price_gradient(cfs, ctx)
    curve = ctx.basis
    price_fn(z) = price(ValuationContext(
        ctx.settlement, ZeroCurve(curve.anchor, copy(curve.pillars), z);
        daycount=ctx.daycount), cfs)
    return _risk_report(pg.price, pg.gradient, curve.zeros, price_fn,
                        bump_bps, shock_bps)
end

# One position: dated cash flows held in a quantity. A negative
# quantity would be a short position, which this aggregation does
# not model; quantities are non-negative, and zero contributes
# nothing.
function _validate_positions(positions)
    isempty(positions) && throw(ArgumentError("no positions given"))
    for (_, q) in positions
        (isfinite(q) && q >= 0) ||
            throw(ArgumentError("quantities must be finite and non-negative"))
    end
    return nothing
end

"""
    curve_risk_positions(positions, curve; bump_bps=1.0, shock_bps=100.0) -> NamedTuple

Curve-node risk attribution for a portfolio of positions on
`curve`. `positions` is one `(cashflows, quantity)` pair per
holding: the cash flows are one unit's dated schedule and the
quantity scales its value and every sensitivity. The result
carries the same fields as `curve_risk(cfs, curve)` for the
aggregated portfolio, plus `rows`: one entry per position, in
the order given, with its `quantity`, `price`, `gradient` and
`node_dv01`. The aggregated finite-difference and parallel
checks reprice the whole portfolio, so they test the sum, not
just the parts.
"""
function curve_risk_positions(
        positions::Vector{Tuple{Vector{CashFlow},Float64}},
        curve::ZeroCurve; bump_bps::Real=1.0, shock_bps::Real=100.0)
    _check_bump_shock(bump_bps, shock_bps)
    _validate_positions(positions)
    rows = NamedTuple[]
    price = 0.0
    gradient = zeros(length(curve.pillars))
    for (cfs, q) in positions
        g = node_sensitivities(cfs, curve)
        p = price_from_curve(cfs, curve)
        push!(rows, (quantity=q, price=p, gradient=g,
                     node_dv01=-g .* 1e-4))
        price += q * p
        gradient .+= q .* g
    end
    price_fn(z) = sum(q * price_from_curve(
        cfs, ZeroCurve(curve.anchor, copy(curve.pillars), z))
                      for (cfs, q) in positions)
    rep = _risk_report(price, gradient, curve.zeros, price_fn,
                       bump_bps, shock_bps)
    return (price=rep.price, gradient=rep.gradient,
            node_dv01=rep.node_dv01,
            parallel_gradient=rep.parallel_gradient,
            parallel_dv01=rep.parallel_dv01,
            parallel_fd_gradient=rep.parallel_fd_gradient,
            parallel_check=rep.parallel_check, fd_check=rep.fd_check,
            shock=rep.shock, rows=rows, message=rep.message)
end
