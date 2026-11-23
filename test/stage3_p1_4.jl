@testset "stage3_p1_4_curve_node_risk" begin
    # P1/4: curve-node risk attribution from full cash flows. The
    # fixture is a known-answer three-pillar curve (3% at 6m, 3.5%
    # at 12m, 4% at 2y, linear zero interpolation) plus the real
    # January 2026 IILM record. Every expected value below is
    # computed by hand from the stated conventions, never from the
    # code under test.
    anchor = Date(2026, 1, 1)
    d6 = anchor + Month(6)
    d9 = anchor + Month(9)
    d12 = anchor + Month(12)
    d2y = anchor + Month(24)
    t6 = yearfrac(anchor, d6, :actual_365)
    t9 = yearfrac(anchor, d9, :actual_365)
    t12 = yearfrac(anchor, d12, :actual_365)
    t2y = yearfrac(anchor, d2y, :actual_365)
    pillars = [t6, t12, t2y]
    zeros = [0.03, 0.035, 0.04]
    curve = ZeroCurve(anchor, pillars, zeros)

    # Independent pricing on the true curve, straight exp
    # arithmetic, with the interpolation written out here.
    function r_at(t)
        t <= t6 && return 0.03
        t >= t2y && return 0.04
        if t <= t12
            return 0.03 + (0.035 - 0.03) * (t - t6) / (t12 - t6)
        end
        return 0.035 + (0.04 - 0.035) * (t - t12) / (t2y - t12)
    end
    pv_true(cfs) = sum(cf.amount *
                       exp(-r_at(yearfrac(anchor, cf.date, :actual_365)) *
                           yearfrac(anchor, cf.date, :actual_365))
                       for cf in cfs)

    # Target: flows on pillar 1, between pillars 1 and 2, on
    # pillar 2, and on pillar 3, so every pillar is loaded and the
    # between-pillar flow genuinely splits across its neighbours.
    cfs = [CashFlow(d6, 2.0), CashFlow(d9, 3.0),
           CashFlow(d12, 4.0), CashFlow(d2y, 104.0)]

    @testset "node_sensitivities_known_answer" begin
        g = node_sensitivities(cfs, curve)
        @test length(g) == 3
        # Hand values. The 6m flow sits on pillar 1. The 9m flow
        # splits with weight w1 = (t12 - t9) / (t12 - t6) on
        # pillar 1 and w2 = 1 - w1 on pillar 2. The 12m flow sits
        # on pillar 2. The 2y flow sits on pillar 3.
        w1 = (t12 - t9) / (t12 - t6)
        w2 = 1 - w1
        r9 = 0.03 + (0.035 - 0.03) * (t9 - t6) / (t12 - t6)
        e1 = -2.0 * t6 * exp(-0.03 * t6) -
             3.0 * t9 * exp(-r9 * t9) * w1
        e2 = -3.0 * t9 * exp(-r9 * t9) * w2 -
             4.0 * t12 * exp(-0.035 * t12)
        e3 = -104.0 * t2y * exp(-0.04 * t2y)
        @test g ≈ [e1, e2, e3] rtol = 1e-12
        # Every entry is negative: raising a zero rate lowers value.
        @test all(<(0), g)
        # A flow at the anchor is worth its amount whatever the
        # curve, so it loads no pillar at all.
        g0 = node_sensitivities([CashFlow(anchor, 100.0)], curve)
        @test g0 == [0.0, 0.0, 0.0]
        # A flow past the last pillar loads only that pillar, at
        # the flat extrapolated rate.
        gfar = node_sensitivities([CashFlow(anchor + Month(60), 100.0)],
                                  curve)
        t5y = yearfrac(anchor, anchor + Month(60), :actual_365)
        @test gfar ≈ [0.0, 0.0, -100.0 * t5y * exp(-0.04 * t5y)] rtol = 1e-12
        # DV01 is the fall in value per 1bp rise in one pillar.
        @test node_dv01(cfs, curve) ≈ -g .* 1e-4 rtol = 1e-12
        @test all(>(0), node_dv01(cfs, curve))
    end

    @testset "finite_difference_agreement" begin
        rep = curve_risk(cfs, curve)
        @test rep.price ≈ pv_true(cfs) rtol = 1e-12
        @test rep.gradient ≈ node_sensitivities(cfs, curve) rtol = 1e-12
        @test rep.node_dv01 ≈ node_dv01(cfs, curve) rtol = 1e-12
        # Analytic node sensitivities against central finite
        # differences at 1bp per pillar: the acceptance bar.
        @test rep.fd_check.agrees
        @test rep.fd_check.max_relative_error <= 1e-5
        @test rep.fd_check.max_absolute_error <= 1e-5
        for row in rep.fd_check.rows
            @test row.relative_error <= 1e-5 || row.absolute_error <= 1e-6
        end
        # The sum of the node sensitivities matches the derivative
        # of a parallel zero-node shift, analytic and finite
        # difference both ways.
        @test rep.parallel_gradient ≈ sum(rep.gradient) rtol = 1e-12
        @test rep.parallel_check.agrees
        @test rep.parallel_check.relative_error <= 1e-5
        @test rep.parallel_dv01 ≈ -sum(rep.gradient) * 1e-4 rtol = 1e-12
        # Node DV01s sum to the parallel DV01.
        @test sum(rep.node_dv01) ≈ rep.parallel_dv01 rtol = 1e-12
    end

    @testset "finite_shock_reprice_is_ground_truth" begin
        rep = curve_risk(cfs, curve; shock_bps=100.0)
        @test rep.shock.shock_bps == 100.0
        # The repriced price is the full reprice on the shifted
        # curve, computed independently here.
        shifted = ZeroCurve(anchor, pillars, zeros .+ 0.01)
        @test rep.shock.repriced_price ≈ price_from_curve(cfs, shifted) rtol = 1e-12
        # First order from the node decomposition, and the
        # nonlinear residual between it and the true reprice.
        first_order = rep.price + sum(rep.gradient) * 0.01
        @test rep.shock.first_order_price ≈ first_order rtol = 1e-12
        @test rep.shock.residual ≈
              rep.shock.repriced_price - first_order atol = 1e-12
        @test rep.shock.actual_change ≈
              rep.shock.repriced_price - rep.price atol = 1e-12
        # The residual is genuinely second order: present, but a
        # small share of the move at 100bp.
        @test rep.shock.residual != 0.0
        @test abs(rep.shock.residual) <= 0.05 * abs(rep.shock.actual_change)
        # A downward shock gains value, and the same decomposition
        # holds with the sign flipped.
        rep_dn = curve_risk(cfs, curve; shock_bps=-100.0)
        shifted_dn = ZeroCurve(anchor, pillars, zeros .- 0.01)
        @test rep_dn.shock.repriced_price ≈
              price_from_curve(cfs, shifted_dn) rtol = 1e-12
        @test rep_dn.shock.actual_change > 0
        @test abs(rep_dn.shock.residual) <=
              0.05 * abs(rep_dn.shock.actual_change)
    end

    @testset "position_aggregation" begin
        other = [CashFlow(d12, 10.0)]
        positions = Tuple{Vector{CashFlow},Float64}[(cfs, 2.0),
                                                    (other, 3.0)]
        agg = curve_risk_positions(positions, curve)
        @test agg.price ≈ 2 * price_from_curve(cfs, curve) +
                          3 * price_from_curve(other, curve) rtol = 1e-12
        @test agg.gradient ≈ 2 .* node_sensitivities(cfs, curve) +
                             3 .* node_sensitivities(other, curve) rtol = 1e-12
        @test length(agg.rows) == 2
        @test agg.rows[1].quantity == 2.0
        @test agg.rows[2].quantity == 3.0
        @test agg.rows[1].price ≈ price_from_curve(cfs, curve) rtol = 1e-12
        @test agg.rows[2].gradient ≈ node_sensitivities(other, curve) rtol = 1e-12
        # The aggregated finite-difference check passes too: the
        # sum of the analytic node sensitivities matches the
        # repriced aggregate.
        @test agg.fd_check.agrees
        @test agg.fd_check.max_relative_error <= 1e-5
        @test agg.parallel_check.agrees
        # Quantities scale the value and every sensitivity.
        doubled = curve_risk_positions([(cfs, 2.0)], curve)
        @test doubled.price ≈ 2 * price_from_curve(cfs, curve) rtol = 1e-12
        @test doubled.gradient ≈ 2 .* node_sensitivities(cfs, curve) rtol = 1e-12
        # A zero quantity contributes nothing.
        zeroed = curve_risk_positions([(cfs, 0.0)], curve)
        @test zeroed.price == 0.0
        @test zeroed.gradient == [0.0, 0.0, 0.0]
    end

    @testset "settlement_context" begin
        terms = SukukTerms("Two-year 5%", 1000.0, 0.05, anchor,
                           Date(2028, 1, 1), 2, "ijara")
        # Settlement on the anchor: the context price is the
        # anchor price of the remaining flows.
        ctx0 = ValuationContext(anchor, curve)
        rep0 = curve_risk(ctx0, terms)
        rem0 = remaining_cashflows(payment_schedule(terms), anchor)
        @test rep0.price ≈ price_from_curve(rem0, curve) rtol = 1e-12
        @test rep0.gradient ≈ node_sensitivities(rem0, curve) rtol = 1e-12
        @test rep0.fd_check.agrees
        @test rep0.fd_check.max_relative_error <= 1e-5
        # Settlement six months later: the price is rescaled by
        # the discount factor to settlement, and the analytic
        # gradient carries that term. Finite differences on the
        # bumped contexts are the check.
        settle = anchor + Month(6)
        ctx = ValuationContext(settle, curve)
        rep = curve_risk(ctx, terms)
        @test rep.price ≈ price(ctx, terms) rtol = 1e-12
        @test rep.fd_check.agrees
        @test rep.fd_check.max_relative_error <= 1e-5
        @test rep.parallel_check.agrees
        @test rep.parallel_check.relative_error <= 1e-5
        # The settled first coupon is excluded: the price moves
        # only on the remaining flows.
        @test rep.price < rep0.price
    end

    @testset "iilm_real_record" begin
        record = load_auction_record(joinpath(@__DIR__, "..", "data",
                                              "iilm_2026-01.json"))
        icurve = auction_curve(record)
        uae = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                         Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
        target = remaining_cashflows(payment_schedule(uae),
                                     Date(2026, 10, 10))
        rep = curve_risk(target, icurve)
        @test rep.price ≈ price_from_curve(target, icurve) rtol = 1e-12
        @test rep.fd_check.agrees
        @test rep.fd_check.max_relative_error <= 1e-5
        @test rep.parallel_check.agrees
        # All of the target's flows fall past the last (12m)
        # pillar, where the curve extrapolates flat on that pillar
        # alone, so only the last node carries any exposure.
        @test rep.gradient[1:3] == [0.0, 0.0, 0.0]
        @test rep.gradient[4] < 0
        @test rep.node_dv01[4] > 0
    end

    @testset "curve_risk_validation" begin
        @test_throws ArgumentError node_sensitivities(CashFlow[], curve)
        @test_throws ArgumentError curve_risk(CashFlow[], curve)
        @test_throws ArgumentError node_sensitivities(
            [CashFlow(anchor - Day(1), 100.0)], curve)
        @test_throws ArgumentError node_sensitivities(
            [CashFlow(d12, 0.0), CashFlow(d2y, 100.0)], curve)
        @test_throws ArgumentError node_sensitivities(
            [CashFlow(d12, 4.0), CashFlow(d6, 2.0)], curve)
        @test_throws ArgumentError curve_risk(cfs, curve; bump_bps=0.0)
        @test_throws ArgumentError curve_risk(cfs, curve; bump_bps=-1.0)
        @test_throws ArgumentError curve_risk(cfs, curve; shock_bps=0.0)
        @test_throws ArgumentError curve_risk_positions(
            Tuple{Vector{CashFlow},Float64}[], curve)
        @test_throws ArgumentError curve_risk_positions(
            [(cfs, NaN)], curve)
        @test_throws ArgumentError curve_risk_positions(
            [(cfs, -1.0)], curve)
    end
end
