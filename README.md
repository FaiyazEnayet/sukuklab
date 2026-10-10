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
| `black_scholes.jl` | Closed form prices, delta gamma vega theta rho, vanna volga, Newton implied vol with bisection fallback |
| `svi.jl` | Raw SVI (Gatheral) slice fits with multi start LBFGS, Durrleman butterfly penalty, calendar spread penalty across expiries |
| `heston.jl` | Characteristic function (Little trap), Fourier inversion pricing, multi start calibration to a vol smile |
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

The full suite (`Pkg.test()`) covers put call parity, greeks against finite differences, implied vol roundtrips, SVI recovery with arbitrage checks, Heston calibration recovery, and both FFT agreements. Green.

## Honest limitations

Everything above is synthetic. I have not fit this to real market data, so I make no claim about how it behaves on noisy quotes. Heston calibration is non convex: the multi start strategy works on clean smiles but real data will want better starting points and vega weighting. American exercise is not supported. The FFT grid assumes strikes well inside the log strike range; it errors loudly otherwise. Dividends are a single continuous yield.

## References

Gatheral (2004) on SVI. Durrleman (2005) on the butterfly condition. Carr and Madan (1999) on FFT pricing. Heston (1993) on stochastic volatility. Albrecher et al. on the Little trap formulation of the characteristic function.
