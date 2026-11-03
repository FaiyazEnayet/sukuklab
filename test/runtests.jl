using Test
using SukukLab
using Dates

@testset "SukukLab" begin

    @testset "sukuk_price" begin
        # Par: price equals face when yield matches the profit rate.
        @test isapprox(sukuk_price(100.0, 0.05, 0.05, 5.0), 100.0; atol=1e-8)
        # Discount: yield above the profit rate.
        p = sukuk_price(100.0, 0.05, 0.06, 5.0)
        @test p < 100.0
        # Premium: yield below the profit rate.
        @test sukuk_price(100.0, 0.05, 0.04, 5.0) > 100.0
        # Closed form cross-check: 1y annual, 5 on 100 at 6%.
        @test isapprox(sukuk_price(100.0, 0.05, 0.06, 1.0; m=1),
                       105 / 1.06; atol=1e-10)
        # Zero yield is just the sum of cash flows.
        @test isapprox(sukuk_price(100.0, 0.05, 0.0, 2.0; m=2), 110.0;
                       atol=1e-8)
        @test_throws ArgumentError sukuk_price(0.0, 0.05, 0.05, 5.0)
        @test_throws ArgumentError sukuk_price(100.0, 0.05, 0.05, 0.0)
    end

    @testset "sukuk_ytm" begin
        # Round trip through the pricer.
        for y in (0.03, 0.05, 0.08)
            p = sukuk_price(100.0, 0.05, y, 5.0)
            @test isapprox(sukuk_ytm(p, 100.0, 0.05, 5.0), y; atol=1e-8)
        end
        # Par bond recovers the profit rate.
        @test isapprox(sukuk_ytm(100.0, 100.0, 0.05, 5.0), 0.05; atol=1e-8)
        # Impossible prices return NaN, not garbage.
        @test isnan(sukuk_ytm(-5.0, 100.0, 0.05, 5.0))
        @test isnan(sukuk_ytm(1e9, 100.0, 0.05, 5.0))
    end

    @testset "cashflows" begin
        terms = SukukTerms("Test ijara", 1000.0, 0.05,
                           Date(2026, 1, 15), Date(2028, 1, 15), 2, "ijara")
        cfs = payment_schedule(terms)
        # 2y semi-annual: 4 distributions, last includes principal.
        @test length(cfs) == 4
        @test all(cf.amount ≈ 25.0 for cf in cfs[1:3])
        @test cfs[end].amount ≈ 1025.0
        @test cfs[end].date == Date(2028, 1, 15)
        @test sum(cf.amount for cf in cfs) ≈ 1100.0

        # Murabaha installments: equal payments summing to cost plus profit.
        m = SukukTerms("Test murabaha", 1000.0, 0.05,
                       Date(2026, 1, 15), Date(2028, 1, 15), 2, "murabaha";
                       amortizing=true)
        mcfs = payment_schedule(m)
        @test length(mcfs) == 4
        @test all(cf.amount ≈ mcfs[1].amount for cf in mcfs)
        T = yearfrac(Date(2026, 1, 15), Date(2028, 1, 15), :actual_365)
        @test sum(cf.amount for cf in mcfs) ≈ 1000 * (1 + 0.05 * T)

        # Day counts.
        @test yearfrac(Date(2026, 1, 1), Date(2026, 7, 1), :thirty_360) ≈ 0.5
        @test yearfrac(Date(2026, 1, 1), Date(2027, 1, 1), :actual_365) ≈ 1.0
        @test_throws ArgumentError yearfrac(Date(2026, 1, 2), Date(2026, 1, 1),
                                            :actual_365)
        @test_throws ArgumentError yearfrac(Date(2026, 1, 1), Date(2026, 1, 2),
                                            :unknown)
        # Terms validation.
        @test_throws ArgumentError SukukTerms("x", -100.0, 0.05,
                                              Date(2026, 1, 15),
                                              Date(2028, 1, 15), 2, "ijara")
        @test_throws ArgumentError SukukTerms("x", 100.0, 0.05,
                                              Date(2028, 1, 15),
                                              Date(2028, 1, 15), 2, "ijara")
        @test_throws ArgumentError SukukTerms("x", 100.0, 0.05,
                                              Date(2026, 1, 15),
                                              Date(2028, 1, 15), 5, "ijara")
    end

    @testset "accrued_profit" begin
        terms = SukukTerms("Test", 1000.0, 0.06,
                           Date(2026, 1, 15), Date(2027, 1, 15), 2, "ijara")
        # Halfway through the first half-year: half of the 30.0 coupon.
        a = accrued_profit(terms, Date(2026, 4, 15))
        @test isapprox(a, 15.0; atol=0.5)
        # Just after a distribution date: near zero.
        @test accrued_profit(terms, Date(2026, 7, 16)) < 1.0
        # At maturity: nothing left to accrue.
        @test accrued_profit(terms, Date(2027, 1, 15)) == 0.0
        @test_throws ArgumentError accrued_profit(terms, Date(2026, 1, 15))
    end

    @testset "remaining_cashflows" begin
        terms = SukukTerms("Test", 1000.0, 0.06,
                           Date(2026, 1, 15), Date(2027, 1, 15), 2, "ijara")
        cfs = payment_schedule(terms)
        @test length(cfs) == 2
        rest = remaining_cashflows(cfs, Date(2026, 7, 15))
        @test length(rest) == 1
        @test rest[1].date == Date(2027, 1, 15)
        @test length(remaining_cashflows(cfs, Date(2026, 1, 14))) == 2
    end

    @testset "curve" begin
        anchor = Date(2026, 1, 13)
        curve = ZeroCurve(anchor, [0.5, 1.0, 2.0], [0.03, 0.035, 0.04])
        # Interpolation and flat extrapolation.
        @test zero_rate(curve, 0.75) ≈ 0.0325
        @test zero_rate(curve, 0.5) ≈ 0.03
        @test zero_rate(curve, 5.0) ≈ 0.04
        @test zero_rate(curve, 0.1) ≈ 0.03
        @test discount(curve, 1.0) ≈ exp(-0.035)
        # Forward rate between pillars.
        f = forward_rate(curve, 0.5, 1.0)
        @test f ≈ (0.035 * 1.0 - 0.03 * 0.5) / 0.5
        # Par rate on a flat curve: m * (exp(r / m) - 1).
        flat = ZeroCurve(anchor, [10.0], [log(1.05)])
        @test isapprox(par_rate(flat, 5.0, 2), 2 * (sqrt(1.05) - 1);
                       atol=1e-8)
        @test_throws ArgumentError ZeroCurve(anchor, [1.0, 0.5], [0.03, 0.04])
        @test_throws ArgumentError forward_rate(curve, 1.0, 0.5)
    end

    @testset "bootstrap_reprices_between_pillars" begin
        # SU1 regression: a coupon falling between the previous last pillar
        # and the new pillar must not be frozen on the old curve. Nonflat
        # fixture: discount bill at 6m, then a 1.5y coupon bond with an
        # intermediate coupon at 1y (between the 0.5y and 1.5y pillars).
        anchor = Date(2026, 1, 1)
        t6m = yearfrac(anchor, anchor + Month(6), :actual_365)
        t1y = yearfrac(anchor, anchor + Month(12), :actual_365)
        t18m = yearfrac(anchor, anchor + Month(18), :actual_365)
        # True curve: 3% at 6m, 5% at 18m (nonflat).
        disc6m = exp(-0.03 * t6m)
        bill = ([CashFlow(anchor + Month(6), 100.0)], 100.0 * disc6m)
        # 1.5y bond, 4% annual coupons semiannual: coupons at 1y and 1.5y.
        cpn = 2.0
        cfs = [CashFlow(anchor + Month(12), cpn),
               CashFlow(anchor + Month(18), 100.0 + cpn)]
        # Price on the true nonflat curve with linear zero interpolation.
        r_at(t) = t <= t6m ? 0.03 : 0.03 + (0.05 - 0.03) * (t - t6m) / (t18m - t6m)
        true_price = sum(cf.amount *
                         exp(-r_at(yearfrac(anchor, cf.date, :actual_365)) *
                             yearfrac(anchor, cf.date, :actual_365)) for cf in cfs)
        curve = bootstrap([bill, (cfs, true_price)], anchor)
        @test length(curve.pillars) == 2
        # Every input reprices to 1e-8 per 100 face.
        for (ics, price) in [bill, (cfs, true_price)]
            rp = sum(cf.amount * discount(curve, cf.date) for cf in ics)
            @test isapprox(rp, price; atol=1e-8)
        end
        # Independent check: the 1.5y zero must satisfy the scalar equation
        # price = cpn*exp(-r(1y)*1y) + 102*exp(-z*1.5y) with r(1y) linearly
        # interpolated between the solved pillars.
        z6m = curve.zeros[1]
        z18m = curve.zeros[2]
        r1y = z6m + (z18m - z6m) * (t1y - t6m) / (t18m - t6m)
        implied = cpn * exp(-r1y * t1y) + 102.0 * exp(-z18m * t18m)
        @test isapprox(implied, true_price; atol=1e-8)
    end

    @testset "bootstrap_synthetic" begin
        # Flat 4% continuous curve: build par bonds, bootstrap must recover it.
        anchor = Date(2026, 1, 1)
        r = 0.04
        instruments = Tuple{Vector{CashFlow},Float64}[]
        for T in (0.5, 1.0, 2.0, 3.0)
            n = Int(2T)
            cfs = CashFlow[]
            for i in 1:n
                d = anchor + Month(6i)
                amt = i < n ? 100 * (exp(r / 2) - 1) : 100 * exp(r / 2)
                push!(cfs, CashFlow(d, amt))
            end
            price = sum(cf.amount *
                        exp(-r * yearfrac(anchor, cf.date, :actual_365))
                        for cf in cfs)
            push!(instruments, (cfs, price))
        end
        # First instrument must be discount: prepend a 3m bill.
        bill_t = yearfrac(anchor, anchor + Month(3), :actual_365)
        bill = ([CashFlow(anchor + Month(3), 100.0)],
                100.0 * exp(-r * bill_t))
        curve = bootstrap([bill; instruments], anchor)
        for z in curve.zeros
            @test isapprox(z, r; atol=1e-6)
        end
        # Exact repricing of every input.
        for (cfs, price) in [bill; instruments]
            rp = sum(cf.amount * discount(curve, cf.date) for cf in cfs)
            @test isapprox(rp, price; atol=1e-6)
        end
        # A coupon bond with no discount instrument first must throw.
        two = CashFlow[CashFlow(anchor + Month(6), 2.0),
                       CashFlow(anchor + Month(12), 102.0)]
        @test_throws ArgumentError bootstrap([(two, 99.0)], anchor)
    end

    @testset "bootstrap_iilm_real" begin
        # Real published inputs: the January 2026 IILM auction series,
        # reconstructed from the sourced record with actual issue and
        # maturity dates, loaded through the package loader.
        record = load_auction_record(joinpath(@__DIR__, "..", "data",
                                              "iilm_2026-01.json"))
        instruments = auction_instruments(record)
        curve = auction_curve(record)
        @test length(curve.pillars) == 4
        # Short end sits near 3.8%, 12m pillar lower: the published
        # 12m clearing rate (3.45%) was below the 6m rate (3.82%).
        @test 0.035 < curve.zeros[1] < 0.042
        @test 0.035 < curve.zeros[3] < 0.042
        @test curve.zeros[4] < curve.zeros[3]
        # Curve reprices the auction inputs.
        for (cfs, price) in instruments
            rp = sum(cf.amount * discount(curve, cf.date) for cf in cfs)
            @test isapprox(rp, price; rtol=1e-9)
        end
    end

    @testset "curve_pillar_validation" begin
        anchor = Date(2026, 1, 1)
        # Pillars are documented as strictly increasing: a repeated
        # maturity must be rejected (issorted alone accepts it, and the
        # interpolation then divides by the zero pillar gap).
        @test_throws ArgumentError ZeroCurve(anchor, [0.5, 0.5],
                                             [0.03, 0.04])
        @test_throws ArgumentError ZeroCurve(anchor, [0.5, 1.0, 1.0],
                                             [0.03, 0.04, 0.05])
        # Non-finite pillars and zero rates are rejected up front
        # instead of poisoning every discount factor on the curve.
        @test_throws ArgumentError ZeroCurve(anchor, [0.5, Inf],
                                             [0.03, 0.04])
        @test_throws ArgumentError ZeroCurve(anchor, [0.5, NaN],
                                             [0.03, 0.04])
        @test_throws ArgumentError ZeroCurve(anchor, [0.5, 1.0],
                                             [0.03, NaN])
        @test_throws ArgumentError ZeroCurve(anchor, [0.5, 1.0],
                                             [0.03, Inf])
        # Strictness is about times, not rates: a flat segment is fine.
        flat = ZeroCurve(anchor, [0.5, 1.0], [0.03, 0.03])
        @test zero_rate(flat, 0.75) ≈ 0.03
    end

    @testset "discount_at_anchor" begin
        anchor = Date(2026, 1, 1)
        curve = ZeroCurve(anchor, [0.5, 1.0], [0.03, 0.04])
        # Stated convention: the discount factor at the anchor is
        # exactly 1. The zero rate at t = 0 stays undefined, and
        # negative times are rejected.
        @test discount(curve, 0.0) == 1.0
        @test discount(curve, anchor) == 1.0
        @test_throws ArgumentError zero_rate(curve, 0.0)
        @test_throws ArgumentError discount(curve, -0.5)
    end

    @testset "bootstrap_quote_validation" begin
        anchor = Date(2026, 1, 1)
        d6 = anchor + Month(6)
        d12 = anchor + Month(12)
        bill = ([CashFlow(d6, 100.0)], 99.0)
        T = Tuple{Vector{CashFlow},Float64}
        # An instrument with no cash flows: a validation error, not
        # an indexing error from reading its final cash flow.
        @test_throws ArgumentError bootstrap(T[bill, (CashFlow[], 50.0)],
                                             anchor)
        # Cash flows out of date order, or two on the same date.
        unsorted = T[bill, ([CashFlow(d12, 2.0), CashFlow(d6, 102.0)], 99.0)]
        @test_throws ArgumentError bootstrap(unsorted, anchor)
        dupdates = T[bill, ([CashFlow(d6, 2.0), CashFlow(d6, 102.0)], 99.0)]
        @test_throws ArgumentError bootstrap(dupdates, anchor)
        # Non-positive or non-finite payment amounts.
        zerocpn = T[bill, ([CashFlow(d6, 0.0), CashFlow(d12, 102.0)], 99.0)]
        @test_throws ArgumentError bootstrap(zerocpn, anchor)
        negamt = T[bill, ([CashFlow(d6, -2.0), CashFlow(d12, 102.0)], 99.0)]
        @test_throws ArgumentError bootstrap(negamt, anchor)
        # A cash flow dated before the curve anchor.
        early = T[bill, ([CashFlow(anchor - Month(1), 2.0),
                          CashFlow(d12, 102.0)], 99.0)]
        @test_throws ArgumentError bootstrap(early, anchor)
        # Duplicate maturity quotes are rejected, at any price: the
        # sequential solver fits one pillar per maturity and no
        # joint-fit method is offered.
        @test_throws ArgumentError bootstrap(T[bill,
                                               ([CashFlow(d6, 100.0)], 98.5)],
                                             anchor)
        @test_throws ArgumentError bootstrap(T[bill,
                                               ([CashFlow(d6, 100.0)], 99.0)],
                                             anchor)
        # A non-positive quoted price.
        @test_throws ArgumentError bootstrap(T[([CashFlow(d6, 100.0)], 0.0)],
                                             anchor)
    end

    @testset "calibration_report" begin
        anchor = Date(2026, 1, 1)
        T = Tuple{Vector{CashFlow},Float64}
        # Independent target pricing: piecewise-linear zero rates
        # through the stated pillars, discounted with exp(-r*t)
        # directly, never through the package's curve code.
        function pv_independent(pillar_ts, zs, cfs)
            function r_at(t)
                t <= pillar_ts[1] && return zs[1]
                t >= pillar_ts[end] && return zs[end]
                i = searchsortedlast(pillar_ts, t)
                w = (t - pillar_ts[i]) / (pillar_ts[i + 1] - pillar_ts[i])
                return zs[i] * (1 - w) + zs[i + 1] * w
            end
            return sum(cf.amount *
                       exp(-r_at(yearfrac(anchor, cf.date, :actual_365)) *
                           yearfrac(anchor, cf.date, :actual_365))
                       for cf in cfs)
        end
        function bond(months_coupons, cpn, face=100.0)
            cfs = [CashFlow(anchor + Month(m), cpn) for m in months_coupons]
            cfs[end] = CashFlow(cfs[end].date, cfs[end].amount + face)
            return cfs
        end

        # Flat curve: bill plus coupon bonds, all priced at 4%.
        flat_ts = [yearfrac(anchor, anchor + Month(m), :actual_365)
                   for m in (3, 6, 12, 24)]
        flat_inst = T[]
        push!(flat_inst, ([CashFlow(anchor + Month(3), 100.0)],
                          pv_independent(flat_ts, fill(0.04, 4),
                                         [CashFlow(anchor + Month(3),
                                                   100.0)])))
        for m in (6, 12, 24)
            cfs = bond(collect(6:6:m), 100 * (exp(0.02) - 1))
            push!(flat_inst, (cfs, pv_independent(flat_ts, fill(0.04, 4),
                                                  cfs)))
        end
        rep = calibration_report(flat_inst, anchor)
        @test rep.status == :exact
        @test rep.curve !== nothing
        @test length(rep.rows) == length(flat_inst)
        @test rep.max_residual <= 1e-8
        for row in rep.rows
            @test row.status == :exact
            @test row.residual <= 1e-8
            @test isapprox(row.model_price, row.quoted_price; atol=1e-8)
        end
        for z in rep.curve.zeros
            @test isapprox(z, 0.04; atol=1e-6)
        end

        # Non-flat curve with a coupon between pillars: bill at 6m
        # (3%), then an 18m bond (5% at its pillar) whose 12m coupon
        # sits between the two pillars.
        ts2 = [yearfrac(anchor, anchor + Month(m), :actual_365)
               for m in (6, 18)]
        bill2_cfs = [CashFlow(anchor + Month(6), 100.0)]
        bond2_cfs = [CashFlow(anchor + Month(12), 2.0),
                     CashFlow(anchor + Month(18), 102.0)]
        inst2 = T[(bill2_cfs, pv_independent(ts2, [0.03, 0.05], bill2_cfs)),
                  (bond2_cfs, pv_independent(ts2, [0.03, 0.05], bond2_cfs))]
        rep2 = calibration_report(inst2, anchor)
        @test rep2.status == :exact
        @test rep2.max_residual <= 1e-8

        # Highly steep curve: 2% at 3m rising to 30% at 2y.
        ts3 = [yearfrac(anchor, anchor + Month(m), :actual_365)
               for m in (3, 24)]
        bill3_cfs = [CashFlow(anchor + Month(3), 100.0)]
        bond3_cfs = bond(collect(6:6:24), 5.0)
        inst3 = T[(bill3_cfs, pv_independent(ts3, [0.02, 0.30], bill3_cfs)),
                  (bond3_cfs, pv_independent(ts3, [0.02, 0.30], bond3_cfs))]
        rep3 = calibration_report(inst3, anchor)
        @test rep3.status == :exact
        @test rep3.max_residual <= 1e-8

        # Steeply falling curve: 25% at 3m down to 1% at 2y. The
        # interpolated forward over the falling segment is negative;
        # that is reported, not constrained away, and the fit is
        # still exact.
        ts4 = [yearfrac(anchor, anchor + Month(m), :actual_365)
               for m in (3, 24)]
        bill4_cfs = [CashFlow(anchor + Month(3), 100.0)]
        bond4_cfs = bond(collect(6:6:24), 5.0)
        inst4 = T[(bill4_cfs, pv_independent(ts4, [0.25, 0.01], bill4_cfs)),
                  (bond4_cfs, pv_independent(ts4, [0.25, 0.01], bond4_cfs))]
        rep4 = calibration_report(inst4, anchor)
        @test rep4.status == :exact
        @test rep4.max_residual <= 1e-8
        @test forward_rate(rep4.curve, ts4[1], ts4[2]) < 0

        # Deliberately infeasible: the 6m bill pins the 6m discount
        # factor at 0.99, so the bond's 6m coupon of 50 alone is
        # worth 49.5; a quoted price of 10 has no solution at any
        # 12m rate. The report says so and names the instrument;
        # bootstrap rejects the same set.
        d6 = anchor + Month(6)
        d12 = anchor + Month(12)
        bad = T[([CashFlow(d6, 100.0)], 99.0),
                ([CashFlow(d6, 50.0), CashFlow(d12, 100.0)], 10.0)]
        rep5 = calibration_report(bad, anchor)
        @test rep5.status == :infeasible
        @test rep5.curve === nothing
        @test length(rep5.rows) == 2
        @test rep5.rows[1].status == :exact
        @test rep5.rows[2].status == :infeasible
        @test rep5.rows[2].maturity == d12
        @test_throws ArgumentError bootstrap(bad, anchor)

        # Malformed quote sets are validation failures in the report
        # API too, not calibration outcomes.
        dup = T[([CashFlow(d6, 100.0)], 99.0),
                ([CashFlow(d6, 100.0)], 98.5)]
        @test_throws ArgumentError calibration_report(dup, anchor)
    end

    @testset "analytics" begin
        anchor = Date(2026, 1, 15)
        terms = SukukTerms("Test", 1000.0, 0.05, anchor,
                           Date(2031, 1, 15), 2, "ijara")
        cfs = payment_schedule(terms)
        # YTM round trip.
        for y in (0.03, 0.05, 0.07)
            p = price_from_cashflows(cfs, y, anchor)
            @test isapprox(ytm_from_price(cfs, p, anchor), y; atol=1e-8)
        end
        @test isnan(ytm_from_price(cfs, -10.0, anchor))
        @test isnan(ytm_from_price(cfs, 1e12, anchor))
        # Current yield at par equals the profit rate.
        @test current_yield(50.0, 1000.0) ≈ 0.05
        # Zero-coupon: Macaulay duration equals maturity.
        zc = [CashFlow(Date(2031, 1, 15), 1000.0)]
        T = yearfrac(anchor, Date(2031, 1, 15), :actual_365)
        @test isapprox(macaulay_duration(zc, 0.05, anchor), T; atol=1e-8)
        # Modified duration is the finite-difference slope (central).
        y0 = 0.05
        md = modified_duration(cfs, y0, anchor)
        p0 = price_from_cashflows(cfs, y0, anchor)
        h = 1e-4
        p_up = price_from_cashflows(cfs, y0 + h, anchor)
        p_dn = price_from_cashflows(cfs, y0 - h, anchor)
        @test isapprox(-(p_up - p_dn) / p0 / (2h), md; rtol=1e-6)
        # Convexity is positive for a bullet structure.
        @test convexity(cfs, y0, anchor) > 0
        # DV01 matches a 1bp reprice.
        @test isapprox(dv01(cfs, y0, anchor),
                       p0 - price_from_cashflows(cfs, y0 + 1e-4, anchor);
                       rtol=1e-3)
        # Parallel shift repricing is exact by construction.
        @test price_under_shift(cfs, y0, 100, anchor) ≈
              price_from_cashflows(cfs, y0 + 0.01, anchor)
        # Duration + convexity approximate a small shift well.
        dp_approx = -md * p0 * 0.0025 +
                    0.5 * convexity(cfs, y0, anchor) * p0 * 0.0025^2
        dp_exact = price_under_shift(cfs, y0, 25, anchor) - p0
        @test isapprox(dp_approx, dp_exact; rtol=1e-3)
    end

    @testset "portfolio" begin
        hs = [Holding("a", 600.0, 0.05, 4.0, 20.0),
              Holding("b", 400.0, 0.03, 2.0, 6.0)]
        @test portfolio_value(hs) ≈ 1000.0
        @test weighted_ytm(hs) ≈ 0.6 * 0.05 + 0.4 * 0.03
        @test weighted_duration(hs) ≈ 0.6 * 4.0 + 0.4 * 2.0
        @test weighted_convexity(hs) ≈ 0.6 * 20.0 + 0.4 * 6.0
        # Single holding returns its own measures.
        @test weighted_ytm([hs[1]]) ≈ 0.05
        @test_throws ArgumentError weighted_ytm(Holding[])
        @test_throws ArgumentError Holding("x", -1.0, 0.05, 4.0, 20.0)
    end

    @testset "notebook" begin
        # notebook.jl must stay a valid Pluto file: parses cleanly, cell ids
        # unique, footer order matches the cells, every cell body parses.
        parses_ok(s) = try
            pos = firstindex(s)
            while true
                ex, pos = Meta.parse(s, pos; raise=true)
                ex === nothing && break
            end
            true
        catch
            false
        end
        nb = joinpath(@__DIR__, "..", "notebook.jl")
        @test isfile(nb)
        text = read(nb, String)
        @test parses_ok(text)
        ids = [m.captures[1]
               for m in eachmatch(r"^# ╔═╡ ([0-9a-f-]{36})$"m, text)]
        @test length(ids) == length(unique(ids)) > 0
        order = [m.captures[1]
                 for m in eachmatch(r"^# ╠═╡ ([0-9a-f-]{36})$"m, text)]
        @test ids == order
        @test occursin("PLUTO_PROJECT_TOML_CONTENTS", text)
        @test occursin("PLUTO_MANIFEST_TOML_CONTENTS", text)
        @test occursin("PlutoUI", text)
        # The repo was renamed: no volkit mentions may remain.
        @test !occursin(r"volkit"i, text)
        # Every cell body parses on its own.
        bodies = split(text, r"^# ╔═╡ [0-9a-f-]{36}$"m)
        cells = [split(b, r"^# [╠╙].*$"m)[1] for b in bodies[2:end]]
        @test length(cells) == length(ids)
        @test all(parses_ok.(cells))
    end

    @testset "stage3_p0_5_source_integrity" begin
        # Scope cleanup guards: no orphan source files under src/, and the
        # retired SVI derivatives source must not return. Every .jl file in
        # src/ is either the package entry point or included by it.
        repo = joinpath(@__DIR__, "..")
        src_dir = joinpath(repo, "src")
        entry = read(joinpath(src_dir, "SukukLab.jl"), String)
        for f in sort(readdir(src_dir))
            endswith(f, ".jl") || continue
            f == "SukukLab.jl" && continue
            @test occursin("include(\"$f\")", entry)
        end
        @test !isfile(joinpath(src_dir, "svi.jl"))
        for f in sort(readdir(src_dir))
            endswith(f, ".jl") || continue
            text = read(joinpath(src_dir, f), String)
            @test !occursin(r"\bSVI\b|svi_total_var|svi_vol|durrleman"i, text)
        end
        # Version coherence: the package version equals the latest release
        # heading in the CHANGELOG (metadata reconciled, no new release).
        proj = read(joinpath(repo, "Project.toml"), String)
        pkg_version = match(r"(?m)^version = \"([0-9.]+)\"", proj).captures[1]
        chg = read(joinpath(repo, "CHANGELOG.md"), String)
        rel_version = match(r"(?m)^## v([0-9]+\.[0-9]+\.[0-9]+)",
                            chg).captures[1]
        @test pkg_version == rel_version
    end

    @testset "stage3_p0_5_canonical_results" begin
        # The canonical results file (examples/results.json, generated by
        # examples/make_results.jl through the package only) must match a
        # fresh recomputation, and every number prominently quoted in the
        # README must match the canonical values at printed precision.
        repo = joinpath(@__DIR__, "..")
        text = read(joinpath(repo, "examples", "results.json"), String)
        jnum(key) = parse(Float64, match(Regex("\"" * key *
                                             "\":\\s*([-0-9.eE+]+)"),
                                         text).captures[1])
        jvec(key) = parse.(Float64,
                           split(match(Regex("\"" * key *
                                             "\":\\s*\\[([^\\]]*)\\]"),
                                       text).captures[1], ","))

        record = load_auction_record(joinpath(repo, "data",
                                              "iilm_2026-01.json"))
        instruments = auction_instruments(record)
        curve = auction_curve(record)
        @test jvec("pillar_years") ≈ collect(curve.pillars)
        @test jvec("zero_rates") ≈ collect(curve.zeros)
        @test jnum("forward_6m_12m") ≈ forward_rate(curve, 0.5, 1.0)
        @test jnum("max_reprice_error") < 1e-9

        uae = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                         Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
        cfs = payment_schedule(uae)
        settle = Date(2026, 10, 10)
        y = ytm_from_price(cfs, 1000.0, settle)
        @test jnum("uae_ytm") ≈ y
        @test jnum("uae_macaulay_duration") ≈
              macaulay_duration(cfs, y, settle)
        @test jnum("uae_modified_duration") ≈
              modified_duration(cfs, y, settle)
        @test jnum("uae_convexity") ≈ convexity(cfs, y, settle)
        @test jnum("uae_dv01") ≈ dv01(cfs, y, settle)
        @test jnum("uae_price_shift_100bp") ≈
              price_under_shift(cfs, y, 100, settle)
        @test jnum("uae_accrued") ≈ accrued_profit(uae, settle)

        mk(terms, price, qty) = begin
            sc = remaining_cashflows(payment_schedule(terms), settle)
            yy = ytm_from_price(sc, price, settle)
            Holding(terms.name, price * qty, yy,
                    modified_duration(sc, yy, settle),
                    convexity(sc, yy, settle))
        end
        hs = [mk(SukukTerms("Illustrative 3y 4.5%", 1000.0, 0.045,
                            Date(2026, 1, 15), Date(2029, 1, 15), 2,
                            "wakala"), 990.0, 50),
              mk(SukukTerms("Illustrative 5y 5.0%", 1000.0, 0.050,
                            Date(2026, 1, 15), Date(2031, 1, 15), 2,
                            "ijara"), 1010.0, 30),
              mk(SukukTerms("Illustrative 7y 5.25% murabaha", 1000.0,
                            0.0525, Date(2026, 1, 15), Date(2033, 1, 15), 2,
                            "murabaha"; amortizing=true), 1000.0, 20)]
        @test jnum("portfolio_value") ≈ portfolio_value(hs)
        @test jnum("portfolio_weighted_ytm") ≈ weighted_ytm(hs)
        @test jnum("portfolio_weighted_duration") ≈ weighted_duration(hs)
        @test jnum("portfolio_weighted_convexity") ≈ weighted_convexity(hs)

        # README quoted demo numbers, at the precision the README prints.
        readme = read(joinpath(repo, "README.md"), String)
        for z in curve.zeros
            @test occursin(string(round(100 * z; digits=4)), readme)
        end
        fmt3(x) = (p = split(string(round(x; digits=3)), ".");
                   length(p) == 1 ? p[1] * ".000" :
                   p[1] * "." * rpad(p[2], 3, "0"))
        for t in curve.pillars
            @test occursin(fmt3(t), readme)
        end
        @test occursin(string(round(100 * forward_rate(curve, 0.5, 1.0);
                                    digits=4)), readme)
        @test occursin(string(round(100 * y; digits=4)), readme)
        @test occursin(string(round(macaulay_duration(cfs, y, settle);
                                    digits=4)), readme)
        @test occursin(string(round(modified_duration(cfs, y, settle);
                                    digits=4)), readme)
        @test occursin(string(round(convexity(cfs, y, settle);
                                    digits=4)), readme)
        @test occursin(string(round(dv01(cfs, y, settle); digits=4)),
                       readme)
        @test occursin(string(round(price_under_shift(cfs, y, 100, settle);
                                    digits=2)), readme)
        @test occursin(string(round(accrued_profit(uae, settle);
                                    digits=2)), readme)
        @test occursin("99,800", readme)
        @test occursin(string(round(100 * weighted_ytm(hs); digits=4)),
                       readme)
        @test occursin(string(round(weighted_duration(hs); digits=4)),
                       readme)
        @test occursin(string(round(weighted_convexity(hs); digits=4)),
                       readme)
        # Stale claims must stay fixed: real test count, real entry point.
        @test !occursin("83 tests", readme)
        @test occursin("src/SukukLab.jl", readme)
        @test !occursin("src/sukuklab.jl", readme)
    end

    @testset "stage3_p0_5_python_parity" begin
        # Julia/Python valuation parity on shared fixtures, enforced by an
        # independent stdlib-only Python implementation of the documented
        # formulas (test/check_parity.py). Bar: 1e-8 per 1,000 face.
        py = Sys.which("python3")
        if py === nothing
            @test_skip "python3 not available in this environment"
        else
            ok = success(pipeline(`$py $(joinpath(@__DIR__,
                                                  "check_parity.py"))`;
                                  stdout=devnull, stderr=devnull))
            @test ok
        end
    end

    @testset "stage3_p0_1_iilm_reconstruction" begin
        # The January 2026 IILM auction, reconstructed from the published
        # series record: actual issue and maturity dates, series and ISIN
        # identifiers, and the auction (observation) date stored apart
        # from them. One validated loader reads data/iilm_2026-01.json;
        # nothing in the package derives a maturity from a tenor again.
        repo = joinpath(@__DIR__, "..")
        datafile = joinpath(repo, "data", "iilm_2026-01.json")
        record = load_auction_record(datafile)

        @test record.issuer ==
              "International Islamic Liquidity Management Corporation (IILM)"
        @test record.currency == "USD"
        # Observation time is the auction date, not an instrument date.
        @test record.auction_date == Date(2026, 1, 13)
        @test record.convention === :simple_act_365
        @test length(record.instruments) == 4
        @test length(record.sources) == 3
        @test all(s -> startswith(s.url, "https://"), record.sources)
        @test all(s -> s.retrieved == Date(2026, 11, 2), record.sources)

        inst = record.instruments
        # Source fixture: the published series, pinned exactly.
        @test [i.series for i in inst] ==
              ["260001", "260002", "260003", "260004"]
        @test [i.isin for i in inst] ==
              ["XS3270973699", "XS3270991162", "XS3270992996",
               "XS3270995072"]
        @test [i.tenor_label for i in inst] ==
              ["1-month", "3-month", "6-month", "12-month"]
        @test [i.profit_rate for i in inst] == [0.0381, 0.0384, 0.0382, 0.0345]
        @test [i.amount_usd_m for i in inst] == [460.0, 635.0, 155.0, 50.0]
        @test all(i -> i.issue_date == Date(2026, 1, 15), inst)
        @test [i.maturity_date for i in inst] ==
              [Date(2026, 2, 25), Date(2026, 4, 9), Date(2026, 7, 23),
               Date(2027, 1, 14)]
        @test [i.quote_text for i in inst] ==
              ["3.81% for USD 460 million for 1-month tenor;",
               "3.84% for USD 635 million for 3-month tenor;",
               "3.82% for USD 155 million for 6-month tenor;",
               "3.45% for USD 50 million for 12-month tenor."]

        # Independent price check: straight calendar arithmetic on the
        # fixture fields, no package pricing helpers involved.
        for i in inst
            days = Dates.value(i.maturity_date - i.issue_date)
            expected = 100.0 / (1 + i.profit_rate * days / 365)
            @test isapprox(model_price(i), expected; atol=1e-12)
        end

        # Curve construction anchors on the shared issue date and
        # reprices every series to at most 1e-9 per 100 face.
        @test auction_anchor(record) == Date(2026, 1, 15)
        curve = auction_curve(record)
        @test curve.anchor == Date(2026, 1, 15)
        @test length(curve.pillars) == 4
        residuals = pricing_residuals(record)
        @test length(residuals) == 4
        @test [r.series for r in residuals] == [i.series for i in inst]
        @test all(r -> r.abs_residual <= 1e-9, residuals)

        # Strict validation: corrupted records fail loudly.
        raw = read(datafile, String)
        tmp = mktempdir()
        function variant(name, text)
            p = joinpath(tmp, name)
            write(p, text)
            return p
        end
        # Maturity date removed from the first series.
        @test_throws ArgumentError load_auction_record(variant(
            "missing_maturity.json",
            replace(raw, ",\"maturity_date\":\"2026-02-25\"" => ""; count=1)))
        # Maturity date present but blank.
        @test_throws ArgumentError load_auction_record(variant(
            "blank_maturity.json",
            replace(raw, "\"maturity_date\":\"2026-02-25\"" =>
                    "\"maturity_date\":\"\""; count=1)))
        # Issue date removed from the first series.
        @test_throws ArgumentError load_auction_record(variant(
            "missing_issue.json",
            replace(raw, "\"issue_date\":\"2026-01-15\"," => ""; count=1)))
        # Unknown rate-to-price convention.
        @test_throws ArgumentError load_auction_record(variant(
            "unknown_convention.json",
            replace(raw, "\"rate_convention\":\"simple_act_365\"" =>
                    "\"rate_convention\":\"act_360_money_market\""; count=1)))
        # One series carrying a different currency than the record.
        @test_throws ArgumentError load_auction_record(variant(
            "mixed_currency.json",
            replace(raw, "\"series\":\"260001\"" =>
                    "\"series\":\"260001\",\"currency\":\"EUR\""; count=1)))
        # One series carrying a different issuer than the record.
        @test_throws ArgumentError load_auction_record(variant(
            "mixed_issuer.json",
            replace(raw, "\"series\":\"260002\"" =>
                    "\"series\":\"260002\",\"issuer\":\"Another Issuer\"";
                    count=1)))
        # Maturity before the issue date.
        @test_throws ArgumentError load_auction_record(variant(
            "early_maturity.json",
            replace(raw, "\"maturity_date\":\"2026-02-25\"" =>
                    "\"maturity_date\":\"2026-01-10\""; count=1)))
        # Not JSON at all.
        @test_throws ArgumentError load_auction_record(variant(
            "garbage.json", "{not json"))
    end

    @testset "stage3_p0_2_dated_cashflows" begin
        # Contract-grade dated cash flows: schedules are generated from
        # the unadjusted contractual anchor (issue plus k periods, never
        # by stepping from an already-clamped date), regular and
        # irregular periods are explicit, the 30/360 day count follows
        # the bond-basis rules, and full, accrued and clean prices are
        # three distinct quantities that reconcile.

        # --- Anchor-based month-end generation (no stepping drift) ---
        jan30 = SukukTerms("Jan30 monthly", 1000.0, 0.06,
                           Date(2026, 1, 30), Date(2026, 6, 30), 12, "ijara")
        @test distribution_dates(jan30) ==
              [Date(2026, 2, 28), Date(2026, 3, 30), Date(2026, 4, 30),
               Date(2026, 5, 30), Date(2026, 6, 30)]
        @test length(payment_schedule(jan30)) == 5
        @test all(p -> p.regular, distribution_periods(jan30))

        jan31 = SukukTerms("Jan31 monthly", 1000.0, 0.06,
                           Date(2026, 1, 31), Date(2026, 5, 31), 12, "ijara")
        @test distribution_dates(jan31) ==
              [Date(2026, 2, 28), Date(2026, 3, 31), Date(2026, 4, 30),
               Date(2026, 5, 31)]
        # An end-of-month anchor stays on month ends.
        @test all(is_end_of_month, distribution_dates(jan31))
        @test is_end_of_month(Date(2026, 2, 28))
        @test !is_end_of_month(Date(2026, 2, 27))

        aug31 = SukukTerms("Aug31 semiannual", 1000.0, 0.06,
                           Date(2026, 8, 31), Date(2028, 8, 31), 2, "ijara")
        # Leap day 2028-02-29 is a real payment date on the anchor grid.
        @test distribution_dates(aug31) ==
              [Date(2027, 2, 28), Date(2027, 8, 31), Date(2028, 2, 29),
               Date(2028, 8, 31)]

        nov30 = SukukTerms("Nov30 quarterly", 1000.0, 0.06,
                           Date(2027, 11, 30), Date(2028, 11, 30), 4, "ijara")
        @test distribution_dates(nov30) ==
              [Date(2028, 2, 29), Date(2028, 5, 30), Date(2028, 8, 30),
               Date(2028, 11, 30)]

        leap = SukukTerms("Leap annual", 1000.0, 0.06,
                          Date(2028, 2, 29), Date(2032, 2, 29), 1, "ijara")
        @test distribution_dates(leap) ==
              [Date(2029, 2, 28), Date(2030, 2, 28), Date(2031, 2, 28),
               Date(2032, 2, 29)]
        @test all(is_end_of_month, distribution_dates(leap))

        # Actual retail dated fixture: the published UAE T-Sukuk terms
        # (issued 2026-09-30, semi-annual, matures 2031-09-30) produce
        # exactly the archived schedule dates.
        uae = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                         Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
        @test distribution_dates(uae) ==
              [Date(2027, 3, 30), Date(2027, 9, 30), Date(2028, 3, 30),
               Date(2028, 9, 30), Date(2029, 3, 30), Date(2029, 9, 30),
               Date(2030, 3, 30), Date(2030, 9, 30), Date(2031, 3, 30),
               Date(2031, 9, 30)]

        # --- 30/360 bond basis, hand-computed from the stated rules ---
        # D2 = 31 is kept when D1 < 30.
        @test yearfrac(Date(2026, 1, 29), Date(2026, 1, 31),
                       :thirty_360) == 2 / 360
        # D2 = 31 becomes 30 when D1 is 30 or 31.
        @test yearfrac(Date(2026, 1, 30), Date(2026, 1, 31),
                       :thirty_360) == 0.0
        @test yearfrac(Date(2026, 1, 31), Date(2026, 7, 31),
                       :thirty_360) == 0.5
        # February end-of-month: a last-day-of-February D1 counts as 30.
        @test yearfrac(Date(2026, 2, 28), Date(2026, 3, 30),
                       :thirty_360) == 30 / 360
        @test yearfrac(Date(2026, 2, 28), Date(2026, 3, 31),
                       :thirty_360) == 30 / 360
        @test yearfrac(Date(2026, 2, 28), Date(2026, 8, 28),
                       :thirty_360) == 178 / 360
        @test yearfrac(Date(2024, 2, 29), Date(2024, 8, 29),
                       :thirty_360) == 179 / 360
        # D2 on the last day of February with D1 elsewhere keeps its day.
        @test yearfrac(Date(2026, 1, 31), Date(2026, 2, 28),
                       :thirty_360) == 28 / 360
        @test yearfrac(Date(2026, 1, 15), Date(2026, 7, 15),
                       :thirty_360) == 0.5
        # The enumeration names the same conventions.
        @test DayCount(:thirty_360) === Thirty360
        @test DayCount(:actual_365) === Actual365
        @test yearfrac(Date(2026, 2, 28), Date(2026, 8, 28),
                       Thirty360) == 178 / 360
        @test yearfrac(Date(2026, 1, 1), Date(2027, 1, 1),
                       Actual365) == 1.0
        @test_throws ArgumentError DayCount(:act_360)
        @test_throws ArgumentError yearfrac(Date(2026, 1, 1),
                                            Date(2026, 7, 1), :act_360)

        # --- Final stub: explicitly irregular, accrued by fraction ---
        stub = SukukTerms("Stub", 1000.0, 0.06,
                          Date(2026, 1, 15), Date(2026, 8, 20), 2, "ijara")
        speriods = distribution_periods(stub)
        @test [p.date for p in speriods] ==
              [Date(2026, 7, 15), Date(2026, 8, 20)]
        @test speriods[1].regular
        @test !speriods[2].regular
        scfs = payment_schedule(stub)
        @test scfs[1].amount == 30.0
        # Stub distribution: 35/360 of a year at 6% on 1000.
        @test scfs[2].amount ≈ 1000 + 60 * (35 / 360)
        # Accrued inside the stub accrues the stub distribution itself.
        @test accrued_profit(stub, Date(2026, 8, 1)) ≈ 60 * (16 / 360)
        # Accrued inside the regular first period is unchanged.
        @test accrued_profit(stub, Date(2026, 4, 15)) ≈ 15.0

        short_stub = SukukTerms("Short stub", 1000.0, 0.06,
                                Date(2026, 1, 15), Date(2026, 3, 10), 2,
                                "ijara")
        @test length(distribution_periods(short_stub)) == 1
        @test !distribution_periods(short_stub)[1].regular
        @test payment_schedule(short_stub)[1].amount ≈ 1000 + 60 * (55 / 360)

        # --- Settlement on a distribution date ---
        semi = SukukTerms("Semi", 1000.0, 0.06,
                          Date(2026, 1, 15), Date(2028, 1, 15), 2, "ijara")
        oncpn = Date(2026, 7, 15)
        @test accrued_profit(semi, oncpn) == 0.0
        @test length(remaining_cashflows(payment_schedule(semi), oncpn)) == 3
        dec_on = price_decomposition(semi, 0.05, oncpn)
        @test dec_on.accrued == 0.0
        @test dec_on.clean_price == dec_on.full_price
        dec_issue = price_decomposition(semi, 0.05, Date(2026, 1, 15))
        @test dec_issue.accrued == 0.0
        @test dec_issue.clean_price == dec_issue.full_price

        # --- Full / accrued / clean decomposition (acceptance) ---
        settle = Date(2026, 10, 10)
        @test price_decomposition(uae, 0.0506, settle).accrued ≈ 25.3 / 18
        for y in (0.03, 0.0506, 0.07)
            dec = price_decomposition(uae, y, settle)
            # clean + accrued = full to 1e-10 per 1,000 face.
            @test abs(dec.clean_price + dec.accrued - dec.full_price) <= 1e-10
            # Clean-price round trip: recover the yield from the clean
            # price, reprice, and the full price returns to 1e-8.
            y2 = ytm_from_clean_price(uae, dec.clean_price, settle)
            @test abs(y2 - y) <= 1e-7
            @test abs(price_decomposition(uae, y2, settle).full_price -
                      dec.full_price) <= 1e-8
        end

        # --- Business-day adjustment is declared on the terms ---
        @test jan30.adjustment === :unadjusted
        fol = SukukTerms("Following", 1000.0, 0.06,
                         Date(2026, 1, 31), Date(2026, 4, 30), 12, "ijara";
                         adjustment=:following)
        # 2026-02-28 is a Saturday: following pays Monday 2026-03-02.
        @test distribution_dates(fol) ==
              [Date(2026, 3, 2), Date(2026, 3, 31), Date(2026, 4, 30)]
        modfol = SukukTerms("Modified following", 1000.0, 0.06,
                            Date(2026, 1, 31), Date(2026, 4, 30), 12,
                            "ijara"; adjustment=:modified_following)
        # Following would cross into March, so it falls back to Friday.
        @test distribution_dates(modfol) ==
              [Date(2026, 2, 27), Date(2026, 3, 31), Date(2026, 4, 30)]
        prec = SukukTerms("Preceding", 1000.0, 0.06,
                          Date(2026, 1, 31), Date(2026, 3, 31), 12, "ijara";
                          adjustment=:preceding)
        @test distribution_dates(prec) ==
              [Date(2026, 2, 27), Date(2026, 3, 31)]
        @test_throws ArgumentError SukukTerms("Bad adj", 1000.0, 0.06,
                                              Date(2026, 1, 31),
                                              Date(2026, 4, 30), 12, "ijara";
                                              adjustment=:next_business_day)

        # --- Rounding at payment is an explicit, opt-in policy ---
        rcfs = payment_schedule(stub; rounding=:cent)
        @test rcfs[1].amount == 30.0
        @test rcfs[2].amount == 1005.83
        mround = SukukTerms("Murabaha rounding", 1000.0, 0.05,
                            Date(2026, 1, 15), Date(2026, 10, 15), 4,
                            "murabaha"; amortizing=true)
        mcfs = payment_schedule(mround; rounding=:cent)
        mtotal = 1000 * (1 + 0.05 * 273 / 365)
        @test all(cf -> cf.amount == round(cf.amount; digits=2), mcfs)
        @test sum(cf.amount for cf in mcfs) ≈ mtotal atol=0.005
        @test_throws ArgumentError payment_schedule(stub; rounding=:millis)

        # --- Closed form refuses non-whole-period maturities ---
        @test_throws ArgumentError sukuk_price(100.0, 0.05, 0.05, 1.3; m=2)
        @test_throws ArgumentError sukuk_price(100.0, 0.05, 0.05, 5.0; m=2.5)
        @test_throws ArgumentError sukuk_ytm(100.0, 100.0, 0.05, 1.3; m=2)
    end

    @testset "stage3_su2_golden_fixtures" begin
        # Golden fixtures pinning the day-count, month-end, leap-day
        # and stub conventions to values computed by hand from the
        # stated rules, so a silent change to any of them fails here.

        # --- Seven-month semiannual instrument: one regular period
        # plus a one-month final stub ---
        # Issue 2026-01-15, maturity 2026-08-15, semiannual grid:
        # the grid dates are 2026-07-15 and 2027-01-15, so the
        # schedule is one regular six-month period and a final stub
        # from 2026-07-15 to 2026-08-15.
        seven = SukukTerms("Seven-month semiannual", 1000.0, 0.06,
                           Date(2026, 1, 15), Date(2026, 8, 15), 2,
                           "ijara")
        speriods = distribution_periods(seven)
        @test [p.date for p in speriods] ==
              [Date(2026, 7, 15), Date(2026, 8, 15)]
        @test speriods[1].regular
        @test !speriods[2].regular
        scfs = payment_schedule(seven)
        # Regular period: 1000 * 0.06 / 2 = 30.
        @test scfs[1].amount == 30.0
        # Stub by hand, bond-basis 30/360: 2026-07-15 to 2026-08-15
        # is (8 - 7) * 30 + (15 - 15) = 30 days, a 30/360 year
        # fraction, so the stub distribution is 1000 * 0.06 *
        # (30 / 360) = 5, not a full 30 semiannual distribution.
        @test yearfrac(Date(2026, 7, 15), Date(2026, 8, 15),
                       :thirty_360) == 30 / 360
        @test scfs[2].amount ≈ 1000 + 60 * (30 / 360)
        @test scfs[2].amount ≈ 1005.0
        # Accrued inside the stub accrues the stub distribution:
        # on 2026-07-31 the elapsed share is (16 / 360) / (30 / 360)
        # of the stub period, so accrued is 5 * 16 / 30 = 8 / 3;
        # halfway through the stub (2026-07-30) it is 2.5.
        @test accrued_profit(seven, Date(2026, 7, 31)) ≈ 8 / 3
        @test accrued_profit(seven, Date(2026, 7, 30)) ≈ 2.5

        # --- February end to February end across a leap day ---
        # Bond-basis 30/360: a first date on the last day of
        # February counts as the 30th, and a second date on the
        # last day of February counts as the 30th when the first
        # date is also February-end. 2024-02-29 to 2025-02-28 is
        # therefore (1 * 360 + 0 * 30 + (30 - 30)) / 360 = 1.
        @test yearfrac(Date(2024, 2, 29), Date(2025, 2, 28),
                       :thirty_360) == 1.0
        # Same rule in a non-leap span.
        @test yearfrac(Date(2026, 2, 28), Date(2027, 2, 28),
                       :thirty_360) == 1.0
    end

end
