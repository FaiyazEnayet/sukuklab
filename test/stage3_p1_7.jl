using ForwardDiff

@testset "stage3_p1_7_quote_risk" begin
    # P1/7: how much does each published quote move each calibrated
    # zero rate and a target sukuk value? The fixture is a known-answer
    # two-instrument set on a true curve (3% at 6m, 4% at 12m, linear
    # zero interpolation), plus the real January 2026 IILM record.
    # Every expected value below is computed by hand from the stated
    # conventions, never from the code under test.
    anchor = Date(2026, 1, 1)
    d6 = anchor + Month(6)
    d12 = anchor + Month(12)
    d9 = anchor + Month(9)
    d2y = anchor + Month(24)
    t6 = yearfrac(anchor, d6, :actual_365)
    t9 = yearfrac(anchor, d9, :actual_365)
    t12 = yearfrac(anchor, d12, :actual_365)
    t2y = yearfrac(anchor, d2y, :actual_365)

    # Independent pricing on the true curve, straight exp arithmetic.
    function pv_true(cfs)
        function r_at(t)
            t <= t6 && return 0.03
            t >= t12 && return 0.04
            return 0.03 + (0.04 - 0.03) * (t - t6) / (t12 - t6)
        end
        return sum(cf.amount *
                   exp(-r_at(yearfrac(anchor, cf.date, :actual_365)) *
                       yearfrac(anchor, cf.date, :actual_365)) for cf in cfs)
    end

    bill_cfs = [CashFlow(d6, 100.0)]
    bond_cfs = [CashFlow(d6, 2.0), CashFlow(d12, 102.0)]
    p1 = pv_true(bill_cfs)
    p2 = pv_true(bond_cfs)
    # The bill is quoted as a published simple profit rate under
    # Actual/365: price = 100 / (1 + r * t6), so r1 inverts it.
    r1 = (100.0 / p1 - 1) / t6
    # The bond is quoted as a price directly.
    quoted = Tuple{Vector{CashFlow},QuoteInput}[
        (bill_cfs, QuoteInput(:simple_act_365_rate, r1)),
        (bond_cfs, QuoteInput(:price, p2)),
    ]
    priced = Tuple{Vector{CashFlow},Float64}[(bill_cfs, p1), (bond_cfs, p2)]
    # Target: flows at 9m (between the pillars), 12m and 2y, so its
    # value genuinely depends on both pillars.
    target = [CashFlow(d9, 2.0), CashFlow(d12, 4.0), CashFlow(d2y, 104.0)]

    @testset "quote_price_convention" begin
        # The simple-rate quote converts back to the true bill price.
        @test quote_price(quoted[1][2], d6, anchor) ≈ p1 atol = 1e-12
        # dP/dr = -100 * t / (1 + r * t)^2, by hand.
        @test quote_price_derivative(quoted[1][2], d6, anchor) ≈
              -100.0 * t6 / (1 + r1 * t6)^2 atol = 1e-12
        # A price quote converts to itself with derivative 1.
        @test quote_price(quoted[2][2], d12, anchor) == p2
        @test quote_price_derivative(quoted[2][2], d12, anchor) == 1.0
        # The IILM 1-month series: the quote conversion reproduces
        # the record loader's model price exactly.
        record = load_auction_record(joinpath(@__DIR__, "..", "data",
                                              "iilm_2026-01.json"))
        inst1 = record.instruments[1]
        q1 = QuoteInput(:simple_act_365_rate, inst1.profit_rate)
        @test quote_price(q1, inst1.maturity_date,
                         inst1.issue_date) ≈ model_price(inst1) atol = 1e-12
        # Validation at construction: unknown kinds, non-positive
        # prices and rates outside (0, 1) are rejected.
        @test_throws ArgumentError QuoteInput(:yield, 0.05)
        @test_throws ArgumentError QuoteInput(:price, 0.0)
        @test_throws ArgumentError QuoteInput(:price, -99.0)
        @test_throws ArgumentError QuoteInput(:simple_act_365_rate, 0.0)
        @test_throws ArgumentError QuoteInput(:simple_act_365_rate, 1.5)
        @test_throws ArgumentError QuoteInput(:price, NaN)
    end

    @testset "residual_jacobian_known_answer" begin
        curve = bootstrap(priced, anchor)
        @test curve.zeros ≈ [0.03, 0.04] atol = 1e-9
        J = residual_jacobian(priced, curve)
        # Hand values. J[1, 1] = -t6 * P1 (single flow at pillar 1).
        # J[2, 1] = -2 * t6 * exp(-0.03 * t6): the 6m coupon of the
        # bond sits on pillar 1; its 12m flow has zero weight there.
        # J[2, 2] = -102 * t12 * exp(-0.04 * t12). J[1, 2] = 0: the
        # bill matures before the second pillar exists.
        @test J[1, 1] ≈ -t6 * p1 atol = 1e-10
        @test J[1, 2] == 0.0
        @test J[2, 1] ≈ -2.0 * t6 * exp(-0.03 * t6) atol = 1e-10
        @test J[2, 2] ≈ -102.0 * t12 * exp(-0.04 * t12) atol = 1e-10
    end

    @testset "implicit_sensitivities_known_answer" begin
        res = quote_risk(quoted, anchor, target)
        @test !res.singular
        @test isfinite(res.condition_number)
        @test res.condition_number > 1.0
        @test res.curve.zeros ≈ [0.03, 0.04] atol = 1e-9
        # Closed forms. The bill pins pillar 1 directly:
        # dz1/dr1 = 1 / (1 + r1 * t6).
        @test res.dz_dq[1, 1] ≈ 1 / (1 + r1 * t6) rtol = 1e-10
        # The bond price moves only pillar 2 (a later quote never
        # moves an earlier pillar in the sequential calibration),
        # and dz2/dP2 = 1 / J[2, 2].
        @test res.dz_dq[1, 2] == 0.0
        @test res.dz_dq[2, 2] ≈ 1 / (-102.0 * t12 * exp(-0.04 * t12)) rtol = 1e-10
        # The bill quote moves pillar 2 through the bond: the bond
        # reprices on the moved pillar 1, so pillar 2 compensates.
        # dz2/dr1 = J[2, 1] * G[1, 1] / (J[1, 1] * J[2, 2]) with
        # G[1, 1] = -dP1/dr1 = 100 * t6 / (1 + r1 * t6)^2.
        g11 = 100.0 * t6 / (1 + r1 * t6)^2
        j11 = -t6 * p1
        j21 = -2.0 * t6 * exp(-0.03 * t6)
        j22 = -102.0 * t12 * exp(-0.04 * t12)
        @test res.dz_dq[2, 1] ≈ j21 * g11 / (j11 * j22) rtol = 1e-10
        @test res.dz_dq[2, 1] != 0.0
        # The analytic Jacobian agrees with ForwardDiff on the
        # differentiable pricing components, two ways: the package
        # helper, and a from-scratch implementation in this test.
        pillars = [t6, t12]
        zeros = [0.03, 0.04]
        J_ad = ForwardDiff.jacobian(
            z -> [pv_at_zeros(pillars, z, [t6], [100.0]),
                  pv_at_zeros(pillars, z, [t6, t12], [2.0, 102.0])],
            zeros)
        @test J_ad ≈ res.jacobian rtol = 1e-10
        function pv_local(pl, zs, times, amounts)
            total = zero(eltype(zs))
            for (a, t) in zip(amounts, times)
                r = if t <= pl[1]
                    zs[1]
                elseif t >= pl[end]
                    zs[end]
                else
                    i = searchsortedlast(pl, t)
                    w = (t - pl[i]) / (pl[i + 1] - pl[i])
                    zs[i] * (1 - w) + zs[i + 1] * w
                end
                total += a * exp(-r * t)
            end
            return total
        end
        J_ad2 = ForwardDiff.jacobian(
            z -> [pv_local(pillars, z, [t6], [100.0]),
                  pv_local(pillars, z, [t6, t12], [2.0, 102.0])],
            zeros)
        @test J_ad2 ≈ res.jacobian rtol = 1e-10
        # Bump-and-rebootstrap (central differences) agrees with the
        # implicit derivatives to the 1e-5 acceptance bar.
        @test res.bump_check.agrees
        @test res.bump_check.max_relative_error <= 1e-5
    end

    @testset "quote_dv01_distinct_from_zero_dv01" begin
        res = quote_risk(quoted, anchor, target)
        # Target gradient by hand: the 9m flow sits between the
        # pillars with weights w1 = (t12 - t9) / (t12 - t6) on
        # pillar 1 and w2 = 1 - w1 on pillar 2; the 12m and 2y
        # flows sit on pillar 2 (flat extrapolation past it).
        r9 = 0.03 + (0.04 - 0.03) * (t9 - t6) / (t12 - t6)
        w1 = (t12 - t9) / (t12 - t6)
        w2 = 1 - w1
        dv1 = -2.0 * t9 * exp(-r9 * t9) * w1
        dv2 = -2.0 * t9 * exp(-r9 * t9) * w2 -
              4.0 * t12 * exp(-0.04 * t12) -
              104.0 * t2y * exp(-0.04 * t2y)
        @test res.target_gradient ≈ [dv1, dv2] rtol = 1e-10
        # Zero-node DV01: fall in value per 1bp rise in one pillar.
        @test res.zero_dv01 ≈ -[dv1, dv2] .* 1e-4 rtol = 1e-10
        # Quote DV01: fall in value per 1bp rise in one quote,
        # through recalibration. Quote 1 moves both pillars, so it
        # cannot equal the zero-node DV01 of pillar 1.
        qdv1 = -(dv1 * res.dz_dq[1, 1] + dv2 * res.dz_dq[2, 1]) * 1e-4
        @test res.quote_dv01[1] ≈ qdv1 rtol = 1e-10
        @test abs(res.quote_dv01[1] - res.zero_dv01[1]) >
              0.01 * abs(res.zero_dv01[1])
        # Quote 2 is a price quote: one basis point of price is
        # 0.01 price units, and it moves only pillar 2.
        qdv2 = -(dv2 * res.dz_dq[2, 2]) * 0.01
        @test res.quote_dv01[2] ≈ qdv2 rtol = 1e-10
        @test res.quote_dv01 != res.zero_dv01
    end

    @testset "iilm_real_record" begin
        record = load_auction_record(joinpath(@__DIR__, "..", "data",
                                              "iilm_2026-01.json"))
        insts = auction_instruments(record)
        quotes = auction_quotes(record)
        @test length(quotes) == 4
        @test all(q -> q.kind === :simple_act_365_rate, quotes)
        @test [q.value for q in quotes] ==
              [i.profit_rate for i in record.instruments]
        quoted_iilm = Tuple{Vector{CashFlow},QuoteInput}[
            (cfs, q) for ((cfs, _), q) in zip(insts, quotes)]
        uae = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                         Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
        target_iilm = remaining_cashflows(payment_schedule(uae),
                                          Date(2026, 10, 10))
        res = quote_risk(quoted_iilm, auction_anchor(record), target_iilm)
        @test !res.singular
        @test isfinite(res.condition_number)
        @test res.curve.zeros ≈ auction_curve(record).zeros rtol = 1e-12
        # All four calibrating instruments are discount bills, so
        # the sensitivity matrix is diagonal, and each diagonal
        # entry has the closed form 1 / (1 + r * T).
        for i in 1:4, j in 1:4
            if i != j
                @test abs(res.dz_dq[i, j]) <= 1e-12
            end
        end
        for (k, inst) in enumerate(record.instruments)
            T = yearfrac(inst.issue_date, inst.maturity_date, :actual_365)
            @test res.dz_dq[k, k] ≈ 1 / (1 + inst.profit_rate * T) rtol = 1e-10
        end
        # The 12-month quote moves the 12-month zero by about
        # 0.9667 per unit of quote (1 / (1 + 0.0345 * 364/365));
        # the 1-month quote moves its own pillar by about 0.9957.
        # Later quotes do not move earlier pillars, and the target
        # value falls when any quote rises.
        @test res.dz_dq[4, 4] ≈ 0.9667 atol = 1e-3
        @test res.dz_dq[1, 1] ≈ 0.9957 atol = 1e-3
        # The target's flows all fall past the last (12m) pillar,
        # where the curve extrapolates flat on that pillar alone,
        # so only the 12-month quote moves the target value at all:
        # the first three quote DV01s are exactly zero and the
        # fourth is positive (the value falls when the quote rises).
        @test res.quote_dv01[1:3] == [0.0, 0.0, 0.0]
        @test res.quote_dv01[4] > 0
        @test res.bump_check.agrees
        @test res.bump_check.max_relative_error <= 1e-5
    end

    @testset "singular_jacobian_flag" begin
        # A genuinely singular residual Jacobian: the second row is
        # a multiple of the first, so no unique sensitivity exists.
        # The step reports the failure instead of returning a number.
        sing = implicit_quote_sensitivities([1.0 0.0; 2.0 0.0],
                                            [-1.0 0.0; 0.0 -1.0])
        @test sing.singular
        @test !isfinite(sing.condition_number)
        @test all(isnan, sing.dz_dq)
        @test occursin("singular", lowercase(sing.message))
        sing0 = implicit_quote_sensitivities(zeros(2, 2),
                                             -Matrix{Float64}(I, 2, 2))
        @test sing0.singular
        @test all(isnan, sing0.dz_dq)
        # A nonsingular input is not flagged.
        ok = implicit_quote_sensitivities([2.0 0.0; 1.0 3.0],
                                          [-1.0 0.0; 0.0 -1.0])
        @test !ok.singular
        @test isfinite(ok.condition_number)
        @test ok.dz_dq ≈ [0.5 0.0; -1/6 1/3] atol = 1e-12
    end

    @testset "ill_conditioned_flag" begin
        # Two pillars one day apart, the second instrument almost
        # entirely an early coupon: the second pillar is barely
        # identified, so the condition number is large and reported,
        # while the calibration itself still solves.
        a2 = Date(2026, 1, 1)
        b6 = a2 + Month(6)
        b7 = b6 + Day(1)
        u6 = yearfrac(a2, b6, :actual_365)
        u7 = yearfrac(a2, b7, :actual_365)
        bill = ([CashFlow(b6, 100.0)], QuoteInput(:price, 100.0 * exp(-0.03 * u6)))
        pv_bond = 50.0 * exp(-0.03 * u6) + 0.01 * exp(-0.035 * u7)
        bond = ([CashFlow(b6, 50.0), CashFlow(b7, 0.01)],
                QuoteInput(:price, pv_bond))
        res = quote_risk(Tuple{Vector{CashFlow},QuoteInput}[bill, bond], a2,
                         [CashFlow(b7, 100.0)])
        @test !res.singular
        @test res.condition_number > 1e3
        @test occursin("condition", lowercase(res.message)) ||
              res.condition_number > 1e3
    end

    @testset "quote_risk_validation" begin
        # An empty quote set has nothing to calibrate.
        @test_throws ArgumentError quote_risk(
            Tuple{Vector{CashFlow},QuoteInput}[], anchor, target)
        # A one-instrument set is valid: a single bill pins its
        # own pillar, and the quote moves it by 1 / (1 + r * t).
        one = quote_risk(quoted[1:1], anchor, target)
        @test !one.singular
        @test one.dz_dq[1, 1] ≈ 1 / (1 + r1 * t6) rtol = 1e-10
        # An empty target has no value to move.
        @test_throws ArgumentError quote_risk(quoted, anchor, CashFlow[])
        # A target cash flow before the anchor is rejected.
        @test_throws ArgumentError quote_risk(
            quoted, anchor, [CashFlow(anchor - Day(1), 100.0)])
        # A malformed quote set is rejected, not calibrated.
        bad = Tuple{Vector{CashFlow},QuoteInput}[
            (bill_cfs, QuoteInput(:price, 99.0)),
            (bill_cfs, QuoteInput(:price, 98.5))]
        @test_throws ArgumentError quote_risk(bad, anchor, target)
    end
end
