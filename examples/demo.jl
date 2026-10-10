# Volkit demo: real numbers for the README.
# Run with: julia --project=. examples/demo.jl
using Volkit
using Printf

println("=== 1. Black-Scholes ===")
c = bs_price(100.0, 100.0, 1.0, 0.05, 0.2; kind=:call)
@printf("ATM call: %.6f\n", c)
@printf("IV roundtrip: %.12f\n", implied_vol(c, 100.0, 100.0, 1.0, 0.05; kind=:call))
g = bs_greeks(100.0, 100.0, 1.0, 0.05, 0.2)
@printf("delta=%.4f gamma=%.6f vega=%.4f\n", g.delta, g.gamma, g.vega)

println("\n=== 2. SVI smile fit (synthetic) ===")
p_true = (0.04, 0.4, -0.4, 0.0, 0.2)
S0, r, T = 100.0, 0.02, 0.5
F = S0 * exp(r * T)
ks = collect(range(-0.6, 0.6; length=15))
strikes = F .* exp.(ks)
vols = svi_vol(p_true, ks, T)
params, info = fit_svi(strikes, vols, T, S0, r; n_restarts=6, seed=42)
@printf("true params: %s\n", string(round.(collect(p_true); digits=4)))
@printf("fit  params: %s\n", string(round.(collect(params); digits=4)))
@printf("rmse vol: %.2e  max abs err: %.2e  butterfly_ok: %s\n",
        info.rmse_vol, info.max_abs_err_vol, info.butterfly_ok)

println("\n=== 3. Heston calibration (synthetic) ===")
h_true = (0.04, 2.0, 0.04, 0.35, -0.6)
T2 = 0.5
ks2 = collect(range(-0.4, 0.4; length=9))
strikes2 = (S0 * exp(r * T2)) .* exp.(ks2)
vols2 = heston_vols(S0, strikes2, T2, r, h_true...; n_grid=2048, u_max=80.0)
h_fit, hinfo = calibrate_heston(strikes2, vols2, T2, S0, r;
                                seed=3, n_starts=4, n_grid=2048, u_max=80.0)
@printf("true params: %s\n", string(round.(collect(h_true); digits=4)))
@printf("fit  params: %s\n", string(round.(collect(h_fit); digits=4)))
@printf("rmse vol: %.2e  max abs err: %.2e\n", hinfo.rmse_vol, hinfo.max_abs_err_vol)

println("\n=== 4. FFT vs closed form ===")
K = [80.0, 90.0, 100.0, 110.0, 120.0]
fc = fft_price(100.0, K, 1.0, 0.05; sigma=0.25)
bc = bs_price(100.0, K, 1.0, 0.05, 0.25)
@printf("max relative error: %.2e\n", maximum(abs.(fc .- bc) ./ bc))

println("\n=== 5. FFT vs Heston quadrature ===")
cf = u -> heston_cf(u, 1.0, 100.0, 0.05, h_true...)
fq = fft_price(100.0, K, 1.0, 0.05; cf=cf)
hq = heston_price(100.0, K, 1.0, 0.05, h_true...)
@printf("max relative error: %.2e\n", maximum(abs.(fq .- hq) ./ hq))
