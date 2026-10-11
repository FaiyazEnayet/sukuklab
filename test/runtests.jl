using Test
using Volkit
using Dates

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

    @testset "marketdata_fixture" begin
        # Committed CBOE snapshot loads offline; no network in tests.
        path = joinpath(@__DIR__, "..", "data", "spy_chain_2026-10-10")
        chain = chain_from_json(path)
        @test chain.ticker == "SPY"
        @test chain.spot ≈ 778.57
        @test length(chain.quotes) == 1432  # 3 demo expiries
        q0 = chain.quotes[1]
        @test q0.expiry isa Date && q0.strike > 0.0
        @test q0.bid >= 0.0 && q0.ask >= q0.bid
        # round-trip through JSON preserves everything
        tmp = tempname() * ".json"
        chain_to_json(chain, tmp)
        chain2 = chain_from_json(tmp)
        @test chain2.spot == chain.spot
        @test length(chain2.quotes) == length(chain.quotes)
        @test chain2.quotes[1] == chain.quotes[1]
        rm(tmp)
    end

    @testset "marketdata_cleaning" begin
        e = Date("2026-12-18")
        mk = (bid, ask, vol, oi; strike=780.0, call=true) ->
            (expiry=e, strike=strike, is_call=call, bid=bid, ask=ask,
             volume=vol, open_interest=oi, cboe_iv=0.15, theo=0.0)
        good = mk(5.0, 5.2, 100.0, 500.0)
        rows = [
            good,                                   # kept
            mk(0.0, 0.5, 100.0, 500.0),             # zero bid: dropped
            mk(-1.0, 0.5, 100.0, 500.0),            # negative bid: dropped
            mk(5.5, 5.0, 100.0, 500.0),             # crossed: dropped
            mk(1.0, 6.0, 100.0, 500.0),             # spread 6x: dropped
            mk(5.0, 5.2, 0.0, 500.0),               # no volume: dropped
            mk(5.0, 5.2, 100.0, 0.0),               # no OI: dropped
        ]
        out = clean_chain(rows; min_volume=1.0, min_open_interest=1.0)
        @test length(out) == 1
        @test out[1].mid ≈ 5.1
        @test out[1].strike == 780.0
        # relaxed spread threshold keeps the wide-spread row too
        out2 = clean_chain(rows; min_volume=1.0, min_open_interest=1.0,
                           max_spread_frac=2.0)
        @test length(out2) == 2
    end

    @testset "baw_properties" begin
        # American >= European everywhere (calls and puts, with dividends).
        for (S0, K, T, r, q, sig, kind) in [
                (100.0, 100.0, 1.0, 0.05, 0.02, 0.25, :call),
                (100.0, 100.0, 1.0, 0.05, 0.02, 0.25, :put),
                (90.0, 100.0, 0.5, 0.05, 0.03, 0.30, :put),
                (110.0, 100.0, 0.25, 0.05, 0.01, 0.40, :call)]
            am = baw_price(S0, K, T, r, sig; q=q, kind=kind)
            eu = bs_price(S0, K, T, r, sig; q=q, kind=kind)
            @test am >= eu - 1e-10
        end
        # American call without dividends is never exercised early.
        @test baw_price(100, 100, 1.0, 0.05, 0.25; q=0.0, kind=:call) ≈
              bs_price(100, 100, 1.0, 0.05, 0.25; q=0.0, kind=:call) rtol=1e-2
        # American put-call parity bounds (no dividends).
        S0, K, T, r = 100.0, 105.0, 0.5, 0.05
        C = baw_price(S0, K, T, r, 0.3; q=0.0, kind=:call)
        P = baw_price(S0, K, T, r, 0.3; q=0.0, kind=:put)
        @test S0 - K - 1e-8 <= C - P <= S0 - K * exp(-r * T) + 1e-8
        # BAW vs Cox-Ross-Rubinstein binomial (400 steps), 2% tolerance.
        function crr(S0, K, T, r, q, sig, n, kind)
            dt = T / n
            u = exp(sig * sqrt(dt)); d = 1 / u
            p = (exp((r - q) * dt) - d) / (u - d)
            df = exp(-r * dt)
            v = [kind == :call ? max(S0 * u^j * d^(n - j) - K, 0.0) :
                                 max(K - S0 * u^j * d^(n - j), 0.0) for j in 0:n]
            for i in n-1:-1:0
                v = [kind == :call ?
                     max(S0 * u^j * d^(i - j) - K, df * (p * v[j+2] + (1 - p) * v[j+1])) :
                     max(K - S0 * u^j * d^(i - j), df * (p * v[j+2] + (1 - p) * v[j+1]))
                     for j in 0:i]
            end
            return v[1]
        end
        for (S0, K, T, q, sig, kind) in [(100.0, 100.0, 1.0, 0.02, 0.25, :put),
                                          (100.0, 110.0, 0.5, 0.03, 0.30, :put),
                                          (100.0, 100.0, 1.0, 0.02, 0.25, :call)]
            b = baw_price(S0, K, T, 0.05, sig; q=q, kind=kind)
            c = crr(S0, K, T, 0.05, q, sig, 400, kind)
            @test abs(b - c) / c < 0.02
        end
    end

    @testset "svi_real_fixture" begin
        # SVI surface on the real SPY snapshot is arbitrage-free.
        path = joinpath(@__DIR__, "..", "data", "spy_chain_2026-10-10")
        chain = chain_from_json(path)
        clean = clean_chain(chain.quotes)
        S0, r = chain.spot, 0.04
        asof = Date(chain.timestamp)
        expiries = [Date("2026-10-16"), Date("2026-11-20"), Date("2026-12-18")]
        Ts, qs, Ks, Vs = Float64[], Float64[], [], []
        for e in expiries
            T = (e - asof).value / 365
            q = max(imply_dividend_yield(clean, e, S0, r, T), 0.0)
            F = S0 * exp((r - q) * T)
            otm = otm_quotes(clean, Dict(e => F))
            ivs = [implied_vol(x.mid, S0, x.strike, T, r; q=q,
                               kind=x.is_call ? :call : :put) for x in otm]
            keep = .!isnan.(ivs)
            push!(Ts, T); push!(qs, q)
            push!(Ks, [x.strike for x in otm][keep])
            push!(Vs, ivs[keep])
        end
        _, sinfo = fit_surface(Ks, Vs, Ts, S0, r; q=qs, n_restarts=2, seed=0)
        for si in sinfo.slice_infos
            @test si.butterfly_ok
        end
        @test sinfo.calendar_ok
    end

    @testset "heston_real_fixture" begin
        # Heston converges on the real Nov-2026 smile; RMSE sane (< 5 vol pts).
        path = joinpath(@__DIR__, "..", "data", "spy_chain_2026-10-10")
        chain = chain_from_json(path)
        clean = clean_chain(chain.quotes)
        S0, r = chain.spot, 0.04
        asof = Date(chain.timestamp)
        e = Date("2026-11-20")
        T = (e - asof).value / 365
        q = max(imply_dividend_yield(clean, e, S0, r, T), 0.0)
        F = S0 * exp((r - q) * T)
        otm = otm_quotes(clean, Dict(e => F))
        ivs = [implied_vol(x.mid, S0, x.strike, T, r; q=q,
                           kind=x.is_call ? :call : :put) for x in otm]
        keep = .!isnan.(ivs)
        ks = [x.strike for x in otm][keep]
        vs = ivs[keep]
        idx = unique(round.(Int, range(1, length(ks); length=15)))
        _, hinfo = calibrate_heston(ks[idx], vs[idx], T, S0, r; q=q, seed=0,
                                    n_starts=3, n_grid=2048, u_max=100.0,
                                    polish=true)
        @test isfinite(hinfo.rmse_vol)
        @test hinfo.rmse_vol < 0.05
    end

end
