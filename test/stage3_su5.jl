# SU5: portfolio stress scenarios. A curve twist (different shifts at
# the short and long ends of the zero curve) and a stylized
# hazard/recovery overlay are applied to the remaining cash flows,
# and the scenario loss is attributed to the rate move, the modeled
# credit component and their interaction. Every expected value below
# is computed by an independent oracle that restates the documented
# formulas (linear zero interpolation, Actual/365 times, survival
# weight 1 - (1 - R) * (1 - exp(-lambda * t))) without calling the
# package curve or stress code.

@testset "stage3_su5_stress_scenarios" begin
    anchor = Date(2026, 1, 15)
    settle = Date(2026, 10, 10)
    pillars = [0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 7.0, 10.0]
    zeros = [0.038, 0.037, 0.036, 0.038, 0.040, 0.042, 0.043, 0.045]
    curve = ZeroCurve(anchor, pillars, zeros)
    ctx = ValuationContext(settle, curve)

    terms = [
        SukukTerms("SU5 ijara 5y", 1000.0, 0.05, anchor,
                   Date(2031, 1, 15), 2, "ijara"),
        SukukTerms("SU5 wakala 3y", 1000.0, 0.045, anchor,
                   Date(2029, 1, 15), 2, "wakala"),
        SukukTerms("SU5 murabaha 7y", 1000.0, 0.0525, anchor,
                   Date(2033, 1, 15), 2, "murabaha"; amortizing=true),
    ]

    # --- Independent oracle -------------------------------------------
    function su5_oracle_rate(pl, zs, t)
        t <= pl[1] && return zs[1]
        t >= pl[end] && return zs[end]
        i = searchsortedlast(pl, t)
        w = (t - pl[i]) / (pl[i + 1] - pl[i])
        return zs[i] * (1 - w) + zs[i + 1] * w
    end

    function su5_twisted_zeros(pl, zs, short_bps, long_bps)
        length(pl) == 1 && return [zs[1] + short_bps / 1e4]
        return [zs[i] + (short_bps + (long_bps - short_bps) *
                         (pl[i] - pl[1]) / (pl[end] - pl[1])) / 1e4
                for i in eachindex(pl)]
    end

    function su5_oracle_price(t, zs; hazard=0.0, recovery=0.0)
        cfs = remaining_cashflows(payment_schedule(t), settle)
        t_settle = Dates.value(settle - anchor) / 365
        df_settle = exp(-su5_oracle_rate(pillars, zs, t_settle) * t_settle)
        total = 0.0
        for cf in cfs
            ta = Dates.value(cf.date - anchor) / 365
            ts = Dates.value(cf.date - settle) / 365
            frac = 1 - (1 - recovery) * (1 - exp(-hazard * ts))
            total += cf.amount * frac *
                     exp(-su5_oracle_rate(pillars, zs, ta) * ta)
        end
        return total / df_settle
    end

    @testset "overlay_validation" begin
        @test_throws ArgumentError HazardOverlay(-0.01, 0.4)
        @test_throws ArgumentError HazardOverlay(0.1, -0.1)
        @test_throws ArgumentError HazardOverlay(0.1, 1.5)
        @test_throws ArgumentError HazardOverlay(NaN, 0.5)
        @test_throws ArgumentError HazardOverlay(0.1, NaN)
        @test_throws ArgumentError HazardOverlay(Inf, 0.5)
        @test HazardOverlay(0.0, 0.0).hazard == 0.0
        @test HazardOverlay(0.2, 1.0).recovery == 1.0
        @test_throws ArgumentError CurveTwist(Inf, 0.0)
        @test_throws ArgumentError CurveTwist(0.0, NaN)
    end

    @testset "zero_hazard_recovers_existing_prices" begin
        # Acceptance: with the hazard switched off the overlay is
        # inert at any recovery, and the stressed price is the
        # existing price to the last bit, not merely close.
        for t in terms
            base = price(ctx, t)
            for r in (0.0, 0.4, 0.65, 1.0)
                @test stressed_price(ctx, t, HazardOverlay(0.0, r)) == base
            end
            # The empty scenario is inert as a whole.
            res = stress_scenario(ctx, t, StressScenario())
            @test res.base_price == base
            @test res.stressed_price == base
            @test res.total_loss == 0.0
            @test res.rate_loss == 0.0
            @test res.credit_loss == 0.0
            @test res.interaction_loss == 0.0
        end
    end

    @testset "unit_recovery_recovers_existing_prices" begin
        # Acceptance: recovery of 1 makes the holder whole whatever
        # the hazard, so the price is again the existing price.
        for t in terms
            base = price(ctx, t)
            for h in (0.01, 0.25, 3.0)
                @test stressed_price(ctx, t, HazardOverlay(h, 1.0)) == base
            end
        end
    end

    @testset "limiting_cases" begin
        t = terms[1]
        base = price(ctx, t)
        # Hazard driven very large at zero recovery: every remaining
        # flow is lost, so the stressed price is exactly zero.
        @test stressed_price(ctx, t, HazardOverlay(1e6, 0.0)) == 0.0
        # Hazard driven very large at partial recovery: each flow
        # pays its recovery fraction, so the price tends to that
        # fraction of the unstressed price.
        @test isapprox(stressed_price(ctx, t, HazardOverlay(1e6, 0.4)),
                       0.4 * base; rtol=1e-12)
        # Monotone in the hazard at fixed recovery.
        hs = [0.0, 0.01, 0.05, 0.2, 1.0]
        ps = [stressed_price(ctx, t, HazardOverlay(h, 0.4)) for h in hs]
        @test all(ps[i] > ps[i + 1] for i in 1:(length(ps) - 1))
        @test ps[1] == base
        # Monotone in the recovery at fixed hazard.
        rs = [0.0, 0.25, 0.5, 0.75, 1.0]
        qs = [stressed_price(ctx, t, HazardOverlay(0.1, r)) for r in rs]
        @test all(qs[i] < qs[i + 1] for i in 1:(length(qs) - 1))
        @test qs[end] == base
    end

    @testset "curve_twist" begin
        flat = CurveTwist(0.0, 0.0)
        @test twist_curve(curve, flat).zeros == curve.zeros
        tw = twist_curve(curve, CurveTwist(50.0, -25.0))
        @test tw.zeros[1] ≈ zeros[1] + 0.005
        @test tw.zeros[end] ≈ zeros[end] - 0.0025
        # Interior pillars take the shift interpolated linearly in
        # pillar time between the two ends.
        @test tw.zeros ≈ su5_twisted_zeros(pillars, zeros, 50.0, -25.0)
        @test tw.pillars == curve.pillars
        @test tw.anchor == curve.anchor
        # A parallel twist is the special case short == long.
        par = twist_curve(curve, CurveTwist(100.0, 100.0))
        @test par.zeros ≈ zeros .+ 0.01
        # The original curve is untouched.
        @test curve.zeros == zeros
    end

    @testset "oracle_cross_check" begin
        # Combined scenario: twist +50bp short / -25bp long, hazard
        # 8% with 40% recovery. The package result must match the
        # independent oracle to 1e-10 per 1000 face.
        scen = StressScenario(CurveTwist(50.0, -25.0),
                              HazardOverlay(0.08, 0.4))
        tzs = su5_twisted_zeros(pillars, zeros, 50.0, -25.0)
        for t in terms
            res = stress_scenario(ctx, t, scen)
            @test isapprox(res.stressed_price,
                           su5_oracle_price(t, tzs; hazard=0.08,
                                            recovery=0.4);
                           atol=1e-10)
            @test isapprox(res.base_price, su5_oracle_price(t, zeros);
                           atol=1e-10)
            # Rate-only leg: twisted curve, overlay off.
            @test isapprox(res.base_price - res.rate_loss,
                           su5_oracle_price(t, tzs); atol=1e-10)
            # Credit-only leg: base curve, overlay on.
            @test isapprox(res.base_price - res.credit_loss,
                           su5_oracle_price(t, zeros; hazard=0.08,
                                            recovery=0.4);
                           atol=1e-10)
        end
    end

    @testset "loss_attribution" begin
        up = StressScenario(CurveTwist(100.0, 100.0),
                            HazardOverlay(0.08, 0.4))
        for t in terms
            res = stress_scenario(ctx, t, up)
            # The components reconcile with the total loss.
            @test res.total_loss == res.base_price - res.stressed_price
            @test isapprox(res.rate_loss + res.credit_loss +
                           res.interaction_loss, res.total_loss;
                           atol=1e-9)
            # Both legs lose money on their own here.
            @test res.rate_loss > 0
            @test res.credit_loss > 0
            @test res.stressed_price < res.base_price
        end
        # Single-component scenarios attribute everything to that
        # component, exactly.
        t = terms[1]
        rate_only = stress_scenario(ctx, t,
                                    StressScenario(CurveTwist(75.0, 25.0),
                                                   HazardOverlay(0.0, 0.0)))
        @test rate_only.credit_loss == 0.0
        @test rate_only.interaction_loss == 0.0
        @test rate_only.total_loss == rate_only.rate_loss
        credit_only = stress_scenario(ctx, t,
                                      StressScenario(CurveTwist(0.0, 0.0),
                                                     HazardOverlay(0.1, 0.3)))
        @test credit_only.rate_loss == 0.0
        @test credit_only.interaction_loss == 0.0
        @test credit_only.total_loss == credit_only.credit_loss
    end

    @testset "portfolio_stress" begin
        scen = StressScenario(CurveTwist(50.0, -25.0),
                              HazardOverlay(0.08, 0.4))
        rep = stress_scenario(ctx, terms, scen)
        @test length(rep.results) == length(terms)
        @test rep.base_value ≈ sum(price(ctx, t) for t in terms)
        @test rep.stressed_value ≈
              sum(r.stressed_price for r in rep.results)
        @test rep.rate_loss ≈ sum(r.rate_loss for r in rep.results)
        @test rep.credit_loss ≈ sum(r.credit_loss for r in rep.results)
        @test rep.interaction_loss ≈
              sum(r.interaction_loss for r in rep.results)
        @test isapprox(rep.rate_loss + rep.credit_loss +
                       rep.interaction_loss, rep.total_loss; atol=1e-9)
        @test rep.total_loss ≈ rep.base_value - rep.stressed_value
        @test_throws ArgumentError stress_scenario(ctx, SukukTerms[],
                                                   scen)
    end

    @testset "assumptions_distinguished_from_iilm_observations" begin
        # The January 2026 IILM record holds observations: published
        # clearing profit rates for the four series. The overlay is a
        # model assumption layered on top by the analyst; with the
        # hazard at zero it changes nothing on the observed curve,
        # and nothing in the record feeds its parameters.
        repo = joinpath(@__DIR__, "..")
        record = load_auction_record(joinpath(repo, "data",
                                              "iilm_2026-01.json"))
        @test [i.profit_rate for i in record.instruments] ==
              [0.0381, 0.0384, 0.0382, 0.0345]
        acurve = auction_curve(record)
        ictx = ValuationContext(Date(2026, 10, 10), acurve)
        t = SukukTerms("SU5 on IILM curve", 1000.0, 0.05,
                       Date(2026, 1, 15), Date(2029, 1, 15), 2, "ijara")
        @test stressed_price(ictx, t, HazardOverlay(0.0, 0.4)) ==
              price(ictx, t)
        # The separation is documented where the overlay is defined.
        src = read(joinpath(repo, "src", "portfolio.jl"), String)
        @test occursin("HazardOverlay", src)
        @test occursin("January 2026 IILM", src)
        @test occursin("assumption", src)
    end
end
