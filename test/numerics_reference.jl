@testset "stage3_p1_8_numerics_reference" begin
    # P1/8: reliable root solvers. The defect under test is the
    # hard-coded yield bracket [-0.99, 5.0] in sukuk_ytm and
    # ytm_from_price: a mathematical root outside that bracket is
    # reported as no solution (NaN) today. Every solve below also
    # carries its residual, bracket, iteration count and runtime,
    # and the difficult fixtures are checked against an
    # independently implemented BigFloat evaluation.

    # --- The defect, stated as a fixture -------------------------------
    # A 5y 5% sukuk on 100 face priced at 1e9: the price at the old
    # bracket edge (y = -0.99, m = 2) is about 9.5e4, so the root
    # sits below -0.99, inside the valid domain (yield above -2).
    # Today this returns NaN; after the fix it returns the root and
    # reprices to the target.
    deep = sukuk_ytm_result(1e9, 100.0, 0.05, 5.0)
    @test deep.status == :converged
    @test -2.0 < deep.yield < -0.99
    @test isapprox(sukuk_price(100.0, 0.05, deep.yield, 5.0), 1e9;
                   rtol=1e-9)
    @test deep.abs_residual <= 1e-10 * 1e9
    @test deep.bracket[1] < deep.yield < deep.bracket[2]
    @test deep.iterations >= 1
    @test deep.evaluations >= deep.iterations
    # The plain Float64 API agrees with the result API.
    @test isapprox(sukuk_ytm(1e9, 100.0, 0.05, 5.0), deep.yield; atol=1e-8)

    # Same defect through the cash-flow path: a 5y 5% schedule on
    # 1000 face priced at 1e12 has its root below -0.99.
    anchor = Date(2026, 1, 15)
    terms = SukukTerms("Deep discount", 1000.0, 0.05, anchor,
                       Date(2031, 1, 15), 2, "ijara")
    cfs = payment_schedule(terms)
    deep_cf = ytm_from_price_result(cfs, 1e12, anchor)
    @test deep_cf.status == :converged
    @test -2.0 < deep_cf.yield < -0.99
    @test isapprox(price_from_cashflows(cfs, deep_cf.yield, anchor), 1e12;
                   rtol=1e-9)
    @test isapprox(ytm_from_price(cfs, 1e12, anchor), deep_cf.yield;
                   atol=1e-8)

    # --- Roundtrips across the stress ranges --------------------------
    # (profit rate, maturity, compounding, true yield). Yields run
    # from just above the domain boundary (-m) to far above any
    # market rate, maturities from 3 months to 30 years.
    stress = [
        (0.05, 5.0, 2, -1.9),
        (0.05, 5.0, 2, -1.5),
        (0.05, 5.0, 2, -0.5),
        (0.05, 5.0, 2, 0.0),
        (0.05, 5.0, 2, 0.03),
        (0.05, 5.0, 2, 0.08),
        (0.05, 5.0, 2, 3.0),
        (0.05, 5.0, 2, 8.0),
        (0.00, 10.0, 2, 0.04),
        (0.12, 30.0, 2, 0.06),
        (0.03, 0.25, 4, 0.05),
        (0.05, 7.0, 12, 0.045),
        (0.05, 7.0, 12, -11.0),
        (0.05, 3.0, 1, -0.9),
        (0.05, 3.0, 1, 2.5),
    ]
    solved = NamedTuple[]
    for (coupon, T, m, y_true) in stress
        p = sukuk_price(100.0, coupon, y_true, T; m=m)
        t0 = time_ns()
        r = sukuk_ytm_result(p, 100.0, coupon, T; m=m)
        elapsed = (time_ns() - t0) / 1e9
        push!(solved, (coupon=coupon, T=T, m=m, y_true=y_true,
                       y_solved=r.yield, iterations=r.iterations,
                       evaluations=r.evaluations, seconds=elapsed,
                       status=r.status, abs_residual=r.abs_residual))
        @test r.status == :converged
        @test isapprox(r.yield, y_true; atol=1e-8)
        @test r.abs_residual <= 1e-8 * max(1.0, p)
        @test r.rel_residual <= 1e-8
        @test r.iterations <= 200
        @test isfinite(elapsed)
    end
    # Iteration counts and runtimes are logged, not just asserted.
    @info "P1/8 stress roundtrips" solved

    # Cash-flow roundtrips on the same stress idea: a dated schedule
    # repriced at yields from near the boundary to the far end.
    for y_true in (-1.9, -1.0, 0.03, 0.05, 0.07, 2.0)
        p = price_from_cashflows(cfs, y_true, anchor)
        r = ytm_from_price_result(cfs, p, anchor)
        @test r.status == :converged
        @test isapprox(r.yield, y_true; atol=1e-8)
        @test r.rel_residual <= 1e-8
    end

    # --- Distinct failures ---------------------------------------------
    # A non-positive price has no root: the price of positive cash
    # flows is always positive. The typed result says :no_root and
    # the plain API still returns NaN.
    bad_price = sukuk_ytm_result(-5.0, 100.0, 0.05, 5.0)
    @test bad_price.status == :no_root
    @test isnan(bad_price.yield)
    @test isnan(sukuk_ytm(-5.0, 100.0, 0.05, 5.0))
    bad_cf = ytm_from_price_result(cfs, 0.0, anchor)
    @test bad_cf.status == :no_root
    @test isnan(ytm_from_price(cfs, 0.0, anchor))
    # A non-finite target is the same failure, not a crash.
    @test sukuk_ytm_result(Inf, 100.0, 0.05, 5.0).status == :no_root
    @test sukuk_ytm_result(NaN, 100.0, 0.05, 5.0).status == :no_root

    # Invalid input is an ArgumentError, distinct from no-root:
    # pricing at or below the domain boundary (yield <= -m).
    @test_throws ArgumentError sukuk_price(100.0, 0.05, -2.0, 5.0; m=2)
    @test_throws ArgumentError sukuk_price(100.0, 0.05, -2.5, 5.0; m=2)
    @test_throws ArgumentError price_from_cashflows(cfs, -2.0, anchor)

    # No convergence: starve the solver of iterations on a fixture
    # that needs more than one step.
    starved = sukuk_ytm_result(sukuk_price(100.0, 0.05, 0.06, 5.0),
                               100.0, 0.05, 5.0; maxiter=1)
    @test starved.status == :no_convergence
    @test isfinite(starved.yield)
    @test starved.iterations == 1

    # Precision limit: demand an absolute residual far below what
    # Float64 can resolve at a price of 1e12, with a bracket-width
    # tolerance below one float step at the root. The bracket
    # narrows to machine precision while the residual stays above
    # the bar, so the solve reports :precision_limit instead of
    # pretending it converged.
    tight = ytm_from_price_result(cfs, 1e12, anchor; ftol=1e-12,
                                  xtol=1e-16, maxiter=500)
    @test tight.status == :precision_limit
    @test tight.bracket[2] - tight.bracket[1] <= 1e-12

    # The curve bootstrap solver reports its failures with the same
    # typed errors, and the bootstrap still turns them into the
    # documented no-fit error naming the instrument.
    # exp(-x) + 1 stays positive everywhere, so no bracket exists.
    @test_throws YieldNoRootError SukukLab._bisect_zero(
        x -> exp(-x) + 1.0; lo=-1.0, hi=5.0)
    @test_throws YieldNoConvergenceError SukukLab._bisect_zero(
        x -> 0.123456789 - x; lo=-1.0, hi=5.0, tol=1e-15, maxiter=1)
    d6 = anchor + Month(6)
    d12 = anchor + Month(12)
    bad_set = Tuple{Vector{CashFlow},Float64}[
        ([CashFlow(d6, 100.0)], 99.0),
        ([CashFlow(d6, 50.0), CashFlow(d12, 100.0)], 10.0)]
    @test_throws ArgumentError bootstrap(bad_set, anchor)
    rep = calibration_report(bad_set, anchor)
    @test rep.status == :infeasible
    @test rep.rows[2].status == :infeasible

    # --- BigFloat reference --------------------------------------------
    # An independently implemented BigFloat evaluation (direct
    # per-period sums, bisection in BigFloat) agrees with the
    # Float64 solver on the difficult fixtures.
    for (coupon, T, m, y_true) in
        [(0.05, 5.0, 2, -1.9), (0.05, 5.0, 2, 3.0), (0.12, 30.0, 2, 0.06),
         (0.05, 7.0, 12, -11.0)]
        p = sukuk_price(100.0, coupon, y_true, T; m=m)
        y_ref = reference_sukuk_ytm(100.0, coupon, p, T; m=m)
        @test abs(Float64(y_ref) - y_true) <= 1e-12
        r = sukuk_ytm_result(p, 100.0, coupon, T; m=m)
        @test abs(r.yield - Float64(y_ref)) <= 1e-9
        # The BigFloat price at the Float64 yield reproduces the
        # target to 1e-9 relative.
        @test abs(Float64(reference_sukuk_price(100.0, coupon, r.yield,
                                                T; m=m)) - p) <= 1e-9 * p
    end
    # The 1e9 deep-discount fixture against the BigFloat reference.
    y_ref_deep = reference_sukuk_ytm(100.0, 0.05, 1e9, 5.0)
    @test abs(deep.yield - Float64(y_ref_deep)) <= 1e-9
    # Cash-flow path: BigFloat direct sum against the Float64 solve.
    times = [yearfrac(anchor, cf.date, :actual_365) for cf in cfs]
    amounts = [cf.amount for cf in cfs]
    for y_true in (-1.9, 0.05, 2.0)
        p = price_from_cashflows(cfs, y_true, anchor)
        y_ref = reference_ytm(times, amounts, p)
        @test abs(Float64(y_ref) - y_true) <= 1e-12
        r = ytm_from_price_result(cfs, p, anchor)
        @test abs(r.yield - Float64(y_ref)) <= 1e-9
        @test abs(Float64(reference_price(times, amounts, r.yield)) - p) <=
              1e-9 * max(1.0, p)
    end
    # The real IILM record still calibrates through the new solver:
    # the UAE target yield agrees with the BigFloat reference.
    record = load_auction_record(joinpath(@__DIR__, "..", "data",
                                          "iilm_2026-01.json"))
    curve = auction_curve(record)
    uae = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                     Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
    settle = Date(2026, 10, 10)
    ucfs = remaining_cashflows(payment_schedule(uae), settle)
    y_uae = ytm_from_price(ucfs, 1000.0, settle)
    utimes = [yearfrac(settle, cf.date, :actual_365) for cf in ucfs]
    uamounts = [cf.amount for cf in ucfs]
    @test abs(y_uae - Float64(reference_ytm(utimes, uamounts, 1000.0))) <=
          1e-9
    @test curve.zeros[1] > 0
end
