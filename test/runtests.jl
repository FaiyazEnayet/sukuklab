using Test
using Volkit
using Dates

@testset "Volkit" begin

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
        # Real published inputs: IILM January 2026 auction clearing rates.
        anchor = Date(2026, 1, 13)
        iilm = [(1, 0.0381), (3, 0.0384), (6, 0.0382), (12, 0.0345)]
        instruments = Tuple{Vector{CashFlow},Float64}[]
        for (months, rate) in iilm
            mat = anchor + Month(months)
            T = yearfrac(anchor, mat, :actual_365)
            push!(instruments,
                  ([CashFlow(mat, 100.0)], 100.0 / (1 + rate * T)))
        end
        curve = bootstrap(instruments, anchor)
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

end
