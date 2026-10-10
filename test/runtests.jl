using Test
using Volkit

@testset "Volkit" begin

    @testset "black_scholes" begin
        S0, K, T, r, σ = 100.0, 100.0, 1.0, 0.05, 0.2
        c = bs_price(S0, K, T, r, σ; kind=:call)
        p = bs_price(S0, K, T, r, σ; kind=:put)

        # Textbook ATM value (Hull-style parameters).
        @test isapprox(c, 10.4506; atol=1e-3)
        # Put-call parity.
        @test isapprox(c - p, S0 - K * exp(-r * T); atol=1e-8)
        # Implied-vol round trip.
        @test isapprox(implied_vol(c, S0, K, T, r; kind=:call), σ; atol=1e-6)
        @test isapprox(implied_vol(p, S0, K, T, r; kind=:put), σ; atol=1e-6)
        # OTM bounds return NaN instead of garbage.
        @test isnan(implied_vol(-1.0, S0, K, T, r; kind=:call))

        g = bs_greeks(S0, K, T, r, σ; kind=:call)
        @test 0.0 < g.delta < 1.0
        @test g.gamma > 0.0
        @test g.vega > 0.0
        gp = bs_greeks(S0, K, T, r, σ; kind=:put)
        @test isapprox(g.delta - gp.delta, 1.0; atol=1e-10)  # q = 0
        @test isapprox(g.gamma, gp.gamma; atol=1e-10)        # gamma is kind-agnostic
    end

    @testset "greeks_vs_finite_differences" begin
        S0, K, T, r, σ = 100.0, 100.0, 1.0, 0.05, 0.2
        eps = 1e-5
        fd_delta = (bs_price(S0 + eps, K, T, r, σ) - bs_price(S0 - eps, K, T, r, σ)) / (2eps)
        @test isapprox(bs_delta(S0, K, T, r, σ), fd_delta; atol=1e-7)
        fd_gamma = (bs_delta(S0 + eps, K, T, r, σ) - bs_delta(S0 - eps, K, T, r, σ)) / (2eps)
        @test isapprox(bs_gamma(S0, K, T, r, σ), fd_gamma; atol=1e-6)
        fd_vanna = (bs_delta(S0, K, T, r, σ + eps) - bs_delta(S0, K, T, r, σ - eps)) / (2eps)
        @test isapprox(bs_vanna(S0, K, T, r, σ), fd_vanna; atol=1e-5)
        fd_volga = (bs_vega(S0, K, T, r, σ + eps) - bs_vega(S0, K, T, r, σ - eps)) / (2eps)
        @test isapprox(bs_volga(S0, K, T, r, σ), fd_volga; atol=1e-4)
    end

    @testset "fft" begin
        S0, T, r, σ = 100.0, 1.0, 0.05, 0.25
        strikes = [80.0, 90.0, 100.0, 110.0, 120.0]
        for K in strikes
            fp = fft_price(S0, K, T, r; sigma=σ)
            bs = bs_price(S0, K, T, r, σ; kind=:call)
            @test isapprox(fp, bs; rtol=1e-6)
        end
        # Vector form agrees with the scalar closed form elementwise.
        fp_vec = fft_price(S0, strikes, T, r; sigma=σ)
        bs_vec = bs_price.(S0, strikes, T, r, σ; kind=:call)
        @test all(isapprox.(fp_vec, bs_vec; rtol=1e-6))
        # Put via parity matches the closed form.
        fp_put = fft_price(S0, 100.0, T, r; sigma=σ, kind=:put)
        bs_put = bs_price(S0, 100.0, T, r, σ; kind=:put)
        @test isapprox(fp_put, bs_put; rtol=1e-6)
        # Exactly one of sigma / cf is required.
        @test_throws ArgumentError fft_price(S0, 100.0, T, r)
    end

    @testset "svi_recovery" begin
        # Generate a synthetic smile from known params, fit, recover.
        p_true = (0.04, 0.4, -0.4, 0.0, 0.2)
        S0, r, T = 100.0, 0.02, 0.5
        F = S0 * exp(r * T)
        ks = collect(range(-0.6, 0.6; length=15))
        strikes = F .* exp.(ks)
        vols = svi_vol(p_true, ks, T)

        params, info = fit_svi(strikes, vols, T, S0, r; n_restarts=6, seed=42)
        @test info.rmse_vol < 5e-3
        @test info.max_abs_err_vol < 2e-2

        # The recovered surface interpolates the synthetic one back.
        vols_fit = svi_vol(params, ks, T)
        @test maximum(abs.(vols_fit .- vols)) < 2e-2

        # Surface fit on two synthetic expiries is calendar-consistent.
        p2 = (0.05, 0.45, -0.35, 0.0, 0.22)
        T2 = 1.0
        F2 = S0 * exp(r * T2)
        ks2 = collect(range(-0.6, 0.6; length=13))
        strikes2 = F2 .* exp.(ks2)
        vols2 = svi_vol(p2, ks2, T2)
        plist, sinfo = fit_surface([strikes, strikes2], [vols, vols2],
                                   [T, T2], S0, r; n_restarts=4, seed=7)
        @test sinfo.calendar_ok
        # Mid-expiry interpolation stays between the slices in vol space.
        mid = surface_vol(plist, [T, T2], [F * 1.0], 0.75, S0, r)[1]
        @test 0.0 < mid < 1.0
    end

    @testset "svi_arbitrage" begin
        # Gentle smile is butterfly-arbitrage-free by the Durrleman test.
        p = (0.04, 0.1, 0.0, 0.0, 0.2)
        arb = check_arbitrage(p)
        @test arb.butterfly_ok
        @test arb.min_g >= -1e-9
        @test arb.min_w > 0.0
        # A single-point query matches the vector form.
        @test durrleman_g(p, 0.0) == durrleman_g(p, [0.0])[1]
    end

    @testset "heston_recovery" begin
        # Synthetic Heston smile -> calibrate -> vols must come back.
        # Reduced starts/grid keep the test suite fast; the library
        # defaults (12 starts, 4096 grid) are tighter.
        S0, T, r = 100.0, 0.5, 0.02
        v0, kappa, theta, xi, rho = 0.04, 2.0, 0.04, 0.35, -0.6
        F = S0 * exp(r * T)
        ks = collect(range(-0.4, 0.4; length=9))
        strikes = F .* exp.(ks)
        vols = heston_vols(S0, strikes, T, r, v0, kappa, theta, xi, rho;
                           n_grid=2048, u_max=80.0)

        params, info = calibrate_heston(strikes, vols, T, S0, r;
                                        seed=3, n_starts=4, n_grid=2048,
                                        u_max=80.0, polish=true)
        @test info.rmse_vol < 1e-2
        v0f, kappaf, thetaf, xif, rhof = params
        @test 0.005 <= v0f <= 0.50
        @test -0.99 <= rhof <= 0.30
    end

    @testset "fft_vs_heston_quadrature" begin
        S0, T, r = 100.0, 1.0, 0.05
        v0, kappa, theta, xi, rho = 0.04, 2.0, 0.04, 0.3, -0.7
        strikes = [80.0, 90.0, 100.0, 110.0, 120.0]
        cf = u -> heston_cf(u, T, S0, r, v0, kappa, theta, xi, rho)
        fq = fft_price(S0, strikes, T, r; cf=cf)
        hq = heston_price(S0, strikes, T, r, v0, kappa, theta, xi, rho; kind=:call)
        @test maximum(abs.(fq .- hq) ./ hq) < 1e-3
    end

end
