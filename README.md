# Volkit

I kept rewriting the same options math in every research repo: Black Scholes here, an SVI fit there, a Heston pricer somewhere else. Copy pasted code rots. So I pulled the good parts into one library I can actually depend on. This is the craft counterpart to my research code: same math, clean API, tested.

```julia
using Volkit

bs_price(100.0, 100.0, 1.0, 0.05, 0.2; kind=:call)  # 10.450584
bs_greeks(100.0, 100.0, 1.0, 0.05, 0.2)              # delta gamma vega theta rho vanna volga

params, info = fit_svi(strikes, vols, T, S0, r)
check_arbitrage(params).butterfly_ok                 # true

hparams, hinfo = calibrate_heston(strikes, vols, T, S0, r)
fft_price(100.0, 100.0, 1.0, 0.05; sigma=0.25)       # agrees with closed form to 4e-8
```

## What it does

| File | Contents |
|---|---|
| `black_scholes.jl` | Closed form prices, delta gamma vega theta rho, vanna volga, Newton implied vol with bisection fallback, continuous dividend yield `q` throughout |
| `american.jl` | Barone Adesi Whaley (1987) approximation for American calls and puts, early exercise premium, plus an exact Cox Ross Rubinstein binomial tree as the benchmark |
| `marketdata.jl` | CBOE delayed option chain fetch, parsing, liquidity cleaning, OTM selection, dividend yield from put call parity |
| `svi.jl` | Raw SVI (Gatheral) slice fits with multi start LBFGS, Durrleman butterfly penalty, calendar spread penalty across expiries |
| `heston.jl` | Characteristic function (Little trap), Fourier inversion pricing, multi start calibration to a vol smile, dividend yield support |
| `bates.jl` | Bates (1996) stochastic vol plus log normal jumps, characteristic function, Fourier pricing, multi start calibration; the answer to short dated skew |
| `sukuk.jl` | Fixed profit rate sukuk pricing and yield to maturity from present value of distributions and principal |
| `fft.jl` | Carr Madan FFT pricing from any characteristic function, cubic spline to arbitrary strikes |

Plotting (`plot_smile`, `plot_term_structure`) lives in a package extension: install Plots and it just works, skip it and the core never loads it.

## Install

```julia
using Pkg
Pkg.develop(path="path/to/volkit")
```

## Measured results

All numbers below come from `examples/demo.jl`, run on 2026-10-10. Synthetic data throughout: I fit the library to smiles generated from known parameters and checked what came back.

SVI recovery. True params (0.04, 0.4, -0.4, 0.0, 0.2), 15 strikes, T 0.5. Fit returned (0.04, 0.4, -0.4, -0.0, 0.2). RMSE on vols 3.63e-11. Butterfly check passes.

Heston calibration. True params (v0 0.04, kappa 2.0, theta 0.04, xi 0.35, rho -0.6), 9 strikes, T 0.5. Fit returned (0.0404, 2.0181, 0.0393, 0.3503, -0.5996). RMSE on vols 9.74e-07, max abs error 1.44e-06. Four seeded starts plus a polish.

FFT agreement. Carr Madan against closed form Black Scholes: max relative error 4.24e-08 across five strikes. FFT against Heston quadrature pricing: max relative error 5.55e-08.

The full suite (`Pkg.test()`) covers put call parity, greeks against finite differences, implied vol roundtrips, SVI recovery with arbitrage checks, Heston calibration recovery, Bates properties and real data calibration, CRR tree convergence and American bounds, sukuk pricing and yield roundtrips, both FFT agreements, CBOE fixture parsing and cleaning, BAW against the binomial tree, SVI arbitrage on real data, and Heston convergence on real data. Green.

## Real data

`examples/demo_real.jl` runs the full pipeline on SPY options from CBOE. The feed is free and needs no key, but it is delayed about 15 minutes. The script uses a committed snapshot by default (`data/spy_chain_2026-10-10/`, one file per expiry, 1,432 quotes across the three demo expiries) so it reproduces offline. Pass `--live` to refetch and save a new snapshot.

All numbers below are from 2026-10-10. SPY spot 778.57. I assumed r = 0.04. Cleaning (drop zero or crossed bids, wide spreads, thin volume and open interest) kept 476 of 1,432 quotes. Dividend yields come from put call parity on near ATM pairs: 0.0033 for Oct 16, 0.0000 for Nov 20, 0.0047 for Dec 18. The Nov expiry falls between SPY dividend dates, so zero is what the market says.

SVI surface on the three nearest monthly expiries, OTM quotes only:

| Expiry | T | Quotes | Vol RMSE | Butterfly |
|---|---|---|---|---|
| 2026-10-16 | 0.016 | 102 | 0.0078 | clean |
| 2026-11-20 | 0.112 | 135 | 0.0023 | clean |
| 2026-12-18 | 0.189 | 139 | 0.0037 | clean |

Calendar check passes across all three.

Heston calibration per expiry (25 strikes each):

| Expiry | Vol RMSE | v0 | kappa | theta | xi | rho |
|---|---|---|---|---|---|---|
| 2026-10-16 | 0.081 | 0.057 | 0.10 | 0.005 | 0.69 | -0.99 |
| 2026-11-20 | 0.010 | 0.025 | 0.10 | 0.380 | 1.50 | -0.24 |
| 2026-12-18 | 0.020 | 0.027 | 0.10 | 0.005 | 0.39 | -0.99 |

The 6 day expiry defeats Heston. A pure diffusion cannot make short dated skew that steep, and several params sit on their bounds. That is a model limitation, not a data problem. Bates (1996) adds log normal jumps to the same stochastic vol, and jumps put mass in the tails instantly, which is exactly what the short end needs.

Bates calibration on 2026-10-16 (25 strikes): vol RMSE 0.0074 against Heston's 0.0809. Fit params: v0 0.0127, kappa 0.10, theta 0.50, xi 0.15, rho -0.99, lambdaJ 0.10, muJ -0.14, sigJ 0.10. Roughly one jump every ten years in the calibration, downward on average. The short dated gap is closed.

American exercise. SPY options are American. I price them with Barone Adesi and Whaley, an analytic approximation, and I keep an exact Cox Ross Rubinstein tree in the library as the benchmark. BAW matches the 400 step tree to within 2% on my tests. At the money the early exercise premium is zero for calls and 59 to 256 bps of mid for puts across the three expiries. Small enough that European IVs are a fair summary of the smile, and I report the premium so you can judge the bias yourself.

## Honest limitations

The synthetic results above are clean by construction. Real data adds noise. CBOE quotes are delayed about 15 minutes, so this is not for live trading. I assume r = 0.04; short rates move and you should set your own. Dividends are a continuous yield backed out of put call parity, which approximates discrete quarterly payments. American exercise uses the Barone Adesi Whaley approximation: it is weakest on deep in the money puts close to expiry, and the exact tree is there when you need it. Bates fits short dated smiles where Heston cannot, at the cost of 8 parameters and a slower calibration. My liquidity filters (min volume, min open interest, max spread) shape every fit, so different choices give different numbers. The FFT grid assumes strikes well inside the log strike range; it errors loudly otherwise.

## References

Gatheral (2004) on SVI. Durrleman (2005) on the butterfly condition. Carr and Madan (1999) on FFT pricing. Heston (1993) on stochastic volatility. Bates (1996) on jumps with stochastic volatility. Albrecher et al. on the Little trap formulation of the characteristic function. Barone Adesi and Whaley (1987) on the American approximation. Cox Ross and Rubinstein (1979) on the binomial tree.
