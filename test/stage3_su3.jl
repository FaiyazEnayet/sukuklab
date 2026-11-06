@testset "stage3_su3_settlement_pricing" begin
    # SU3: settlement-aware pricing and sensitivities. One typed
    # valuation context carries the settlement date, the day count
    # and the pricing basis; a nominal quoted yield and a
    # continuously compounded curve are distinct types, so the same
    # number 0.05 means different prices under each convention.
    #
    # Fixture: 2y semiannual ijara, face 1000, profit 5%, issued
    # 2026-01-15, maturing 2028-01-15. Schedule: 25.0 at 2026-07-15,
    # 25.0 at 2027-01-15, 25.0 at 2027-07-15, 1025.0 at 2028-01-15.
    # Settlement 2026-10-15 sits halfway through the 2026-07-15 to
    # 2027-01-15 period under 30/360 (90 of 180 days), so the
    # accrued profit is exactly 25 * 90/180 = 12.5.
    terms = SukukTerms("SU3 fixture ijara", 1000.0, 0.05,
                       Date(2026, 1, 15), Date(2028, 1, 15), 2, "ijara")
    settle = Date(2026, 10, 15)
    cfs = payment_schedule(terms)
    @test length(cfs) == 4
    @test cfs[1] == CashFlow(Date(2026, 7, 15), 25.0)
    @test cfs[end] == CashFlow(Date(2028, 1, 15), 1025.0)
    remaining = remaining_cashflows(cfs, settle)
    @test length(remaining) == 3
    @test remaining[1].date == Date(2027, 1, 15)

    # Independent oracle: linear interpolation of the zero rate
    # between pillars (flat outside), written out here from the
    # definition, never calling zero_rate or discount.
    function oracle_df(pillars, zeros, t)
        t == 0 && return 1.0
        t <= pillars[1] && return exp(-zeros[1] * t)
        t >= pillars[end] && return exp(-zeros[end] * t)
        for i in 1:(length(pillars) - 1)
            if pillars[i] <= t <= pillars[i + 1]
                w = (t - pillars[i]) / (pillars[i + 1] - pillars[i])
                r = zeros[i] * (1 - w) + zeros[i + 1] * w
                return exp(-r * t)
            end
        end
        error("unreachable")
    end
    pillars = [0.25, 0.5, 1.0, 2.0]
    zeros = [0.04, 0.045, 0.05, 0.055]

    # --- Distinct types, distinct conventions -------------------------
    nom = NominalYield(0.05, 2)
    @test nom.rate == 0.05 && nom.m == 2
    curve = ZeroCurve(Date(2026, 1, 15), pillars, zeros)
    @test typeof(nom) != typeof(curve)
    # A bare number is not a pricing basis: it must be wrapped so
    # the convention is explicit.
    @test_throws MethodError ValuationContext(settle, 0.05)
    @test_throws ArgumentError NominalYield(0.05, 0)
    @test_throws ArgumentError NominalYield(NaN, 2)
    @test_throws ArgumentError ValuationContext(settle, nom;
                                                daycount=:actual_360)
    ctx_nom = ValuationContext(settle, nom)
    ctx_curve = ValuationContext(settle, curve)
    @test ctx_nom.settlement == settle
    @test ctx_curve.settlement == settle

    # --- Clean plus accrued equals dirty ------------------------------
    dec = price_decomposition(ctx_nom, terms)
    @test dec.accrued ≈ 12.5 atol = 1e-12
    @test dec.clean_price + dec.accrued ≈ dec.full_price atol = 1e-12
    @test dec.full_price ≈
        price_from_cashflows(remaining, 0.05, settle; m=2) atol = 1e-10
    @test price(ctx_nom, terms) == dec.full_price

    # --- Settled cash flows are excluded consistently ------------------
    # A flow dated exactly on the settlement date belongs to the
    # seller, not the buyer.
    on_date = [CashFlow(settle, 25.0), CashFlow(Date(2027, 1, 15), 25.0),
               CashFlow(Date(2027, 7, 15), 25.0),
               CashFlow(Date(2028, 1, 15), 1025.0)]
    @test price(ctx_nom, on_date) ≈
        price_from_cashflows(remaining, 0.05, settle; m=2) atol = 1e-10
    # On a distribution date the accrued part is zero and the full
    # price is the present value of the flows after that date.
    dec_dist = price_decomposition(
        ValuationContext(Date(2027, 1, 15), nom), terms)
    @test dec_dist.accrued == 0.0
    @test dec_dist.clean_price == dec_dist.full_price
    @test dec_dist.full_price ≈ price_from_cashflows(
        remaining_cashflows(cfs, Date(2027, 1, 15)), 0.05,
        Date(2027, 1, 15); m=2) atol = 1e-10
    # After maturity nothing remains to price.
    dec_mature = price_decomposition(
        ValuationContext(Date(2028, 6, 15), nom), terms)
    @test dec_mature.full_price == 0.0
    @test dec_mature.accrued == 0.0
    @test dec_mature.clean_price == 0.0
    # Settlement before issue is rejected, not silently priced.
    @test_throws ArgumentError price(
        ValuationContext(Date(2026, 1, 1), nom), terms)

    # --- Yield and price round trips ----------------------------------
    for y in (0.03, 0.05, 0.08)
        ctx_y = ValuationContext(settle, NominalYield(y, 2))
        full_y = price(ctx_y, terms)
        @test ytm_from_price(remaining, full_y, settle; m=2) ≈ y atol = 1e-8
        dec_y = price_decomposition(ctx_y, terms)
        @test ytm_from_clean_price(terms, dec_y.clean_price, settle) ≈ y atol = 1e-8
    end

    # --- Curve pricing against the independent oracle ------------------
    # The curve anchors at the issue date, before settlement, so the
    # settlement price divides each discount factor by the factor
    # to the settlement date: value at settlement, not at anchor.
    t_settle = Dates.value(settle - Date(2026, 1, 15)) / 365
    expected_curve = sum(cf.amount *
                         oracle_df(pillars, zeros,
                                   Dates.value(cf.date - Date(2026, 1, 15)) / 365) /
                         oracle_df(pillars, zeros, t_settle)
                         for cf in remaining)
    @test price(ctx_curve, terms) ≈ expected_curve atol = 1e-8
    @test price_from_curve(remaining, curve) ≈
        sum(cf.amount * oracle_df(pillars, zeros,
                                  Dates.value(cf.date - Date(2026, 1, 15)) / 365)
            for cf in remaining) atol = 1e-8
    # A curve anchored at the settlement date needs no rescaling:
    # its anchor factor is exactly 1.
    curve_at = ZeroCurve(settle, pillars, zeros)
    ctx_at = ValuationContext(settle, curve_at)
    expected_at = sum(cf.amount *
                      oracle_df(pillars, zeros,
                                Dates.value(cf.date - settle) / 365)
                      for cf in remaining)
    @test price(ctx_at, terms) ≈ expected_at atol = 1e-8
    @test price_from_curve(remaining, curve_at) ≈ expected_at atol = 1e-8
    # Curve price round trip through the nominal yield: the yield
    # implied by the curve price reprices back to that price.
    curve_price = price(ctx_curve, terms)
    y_star = ytm_from_price(remaining, curve_price, settle; m=2)
    @test isfinite(y_star)
    @test price_from_cashflows(remaining, y_star, settle; m=2) ≈
        curve_price atol = 1e-8

    # --- Nominal and continuous conventions are not interchangeable ---
    # The same 5% as a continuously compounded curve discounts more
    # than as a nominal semiannual yield, so the prices differ.
    flat_curve = ZeroCurve(settle, [0.5, 1.0, 2.0], [0.05, 0.05, 0.05])
    flat_ctx = ValuationContext(settle, flat_curve)
    @test abs(price(flat_ctx, terms) - price(ctx_nom, terms)) > 0.5
    # Compounding frequency matters within the nominal convention.
    @test price(ValuationContext(settle, NominalYield(0.05, 1)), terms) !=
        price(ctx_nom, terms)

    # --- Analytic DV01 and convexity against central differences -----
    y = 0.05
    h = 1e-4
    p0 = price_from_cashflows(remaining, y, settle; m=2)
    p_up = price_from_cashflows(remaining, y + h, settle; m=2)
    p_down = price_from_cashflows(remaining, y - h, settle; m=2)
    first_fd = (p_down - p_up) / (2h)
    second_fd = (p_up - 2p0 + p_down) / h^2
    @test first_fd ≈ modified_duration(remaining, y, settle; m=2) * p0 rtol = 1e-6
    @test second_fd ≈ convexity(remaining, y, settle; m=2) * p0 rtol = 1e-5
    @test dv01(remaining, y, settle; m=2) ≈ first_fd * 1e-4 rtol = 1e-6
    # A one basis point reprice agrees with DV01 up to the
    # second-order term the analytic measure omits by design.
    @test (p0 - p_up) ≈ dv01(remaining, y, settle; m=2) rtol = 1e-3

    # --- Key-rate DV01 via pillar bumps -------------------------------
    bumped = bump_pillar(curve, 3, 1.0)
    @test bumped.pillars == curve.pillars
    @test bumped.zeros[1:2] == curve.zeros[1:2]
    @test bumped.zeros[3] ≈ curve.zeros[3] + 1e-4
    @test bumped.zeros[4] == curve.zeros[4]
    @test_throws ArgumentError bump_pillar(curve, 0, 1.0)
    @test_throws ArgumentError bump_pillar(curve, 5, 1.0)
    @test_throws ArgumentError key_rate_dv01(ctx_curve, terms, 5)
    krs = key_rate_dv01s(ctx_curve, terms)
    @test length(krs) == 4
    for i in 1:4
        @test krs[i] == key_rate_dv01(ctx_curve, terms, i)
    end
    # Pillar locality: the 0.25y pillar touches neither any
    # remaining cash flow nor the settlement discount factor, so
    # bumping it leaves the settlement price exactly unchanged.
    # The 2y and 1y pillars also touch the settlement discount
    # factor (the settlement sits between them), and for those two
    # the settlement effect dominates: bumping either one lowers
    # the settlement discount factor while leaving the flows
    # (nearly) untouched, so the settlement price rises and the
    # key-rate DV01 is negative. The 2y pillar carries the 1025
    # principal flow, so it moves the price most, in the usual
    # direction.
    @test krs[1] == 0.0
    @test krs[2] < 0.0 && krs[3] < 0.0 && krs[4] > 0.0
    @test krs[2] < krs[3]
    @test krs[4] > abs(krs[2]) && krs[4] > abs(krs[3])
    # The key-rate DV01s add up to the parallel curve DV01, up to
    # second-order cross terms between pillars (each bump is 1bp).
    @test sum(krs) ≈ curve_dv01(ctx_curve, terms) rtol = 1e-3
    # A single-pillar bump matches a direct bump and reprice.
    direct = (price(ctx_curve, terms) -
              price(ValuationContext(settle, bump_pillar(curve, 4, 1.0)),
                    terms))
    @test krs[4] ≈ direct atol = 1e-12
    # A 2bp bump quoted per basis point agrees with the 1bp figure.
    @test key_rate_dv01(ctx_curve, terms, 4; bump_bps=2.0) ≈
        krs[4] rtol = 1e-3
end
