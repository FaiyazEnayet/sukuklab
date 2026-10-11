# Volkit

Fixed-income analytics for sukuk, in Julia. I wanted one clean library for the instruments I actually care about: pricing a fixed-profit-rate sukuk from its cash flows, building a profit-rate curve from published auction results, and measuring duration and convexity the way a portfolio manager would. No derivatives anywhere in this repo. Just cash flows, curves, and risk.

```julia
using Volkit, Dates

t = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
               Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
cfs = payment_schedule(t)          # 10 dated cash flows
y = ytm_from_price(cfs, 1000.0, Date(2026, 10, 10))
macaulay_duration(cfs, y, Date(2026, 10, 10))   # 4.4541 years
```

## What it does

| File | Contents |
|---|---|
| `sukuk.jl` | Fixed-profit-rate pricing and yield to maturity by bisection |
| `cashflows.jl` | Distribution schedules for ijara, murabaha and wakala structures, bullet and installment shapes, 30/360 and Actual/365 day counts, accrued profit |
| `curve.jl` | Zero profit-rate curves, discount factors, forward rates, par rates, bootstrapping from market instruments |
| `analytics.jl` | Yield to maturity, current yield, Macaulay and modified duration, convexity, DV01, parallel shift repricing |
| `portfolio.jl` | Market-value-weighted yield, duration and convexity across holdings |

Ijara, murabaha and wakala are named here as financial mechanics. An ijara sukuk pays lease-based periodic distributions with principal at maturity. A murabaha sukuk reflects a deferred sale: cost plus agreed profit, paid as a bullet or in installments. A wakala sukuk pays distributions from an agency-managed pool. The library models the cash-flow shapes that follow from each structure. Nothing more.

## Measured results

All numbers below come from `examples/demo.jl`, run on 2026-10-10.

I bootstrapped a short end zero curve from real published data: the IILM short-term sukuk auction of January 2026, clearing at 3.81% (1m), 3.84% (3m), 3.82% (6m) and 3.45% (12m). The curve recovers every auction point exactly, as a bootstrap should:

| Pillar | Zero rate |
|---|---|
| 0.085y | 3.8038% |
| 0.247y | 3.8219% |
| 0.496y | 3.7843% |
| 1.000y | 3.3918% |

The 6m to 12m forward rate is 3.0026%. The published 12m clearing rate sat below the 6m rate, and the curve keeps that shape.

I also ran the analytics on real published terms: the UAE sovereign retail T-Sukuk, 5-year, 5.06% annual, semi-annual, maturing 2031-09-30. Valued 2026-10-10 at a clean price of 1000 on 1000 face: YTM 5.089%, Macaulay duration 4.4541y, modified duration 4.3436y, convexity 22.3272, DV01 0.4344 per 1000 face. A 100bp parallel rise reprices it to 957.66. Accrued profit at settlement: 1.41.

The portfolio demo uses three illustrative holdings and is labeled synthetic in the script: value 99,800, weighted YTM 5.8005%, weighted duration 2.762y, weighted convexity 10.5031.

The full suite (`Pkg.test()`) is 83 tests: pricing and yield roundtrips, schedule shapes and day counts, curve interpolation and bootstrap recovery on a synthetic flat curve, bootstrap on the real IILM auction, duration against finite differences, convexity sign, DV01 against a 1bp reprice, and portfolio weighting. Green.

## Real data

Two public sources feed the demo. The IILM auction results are published clearing profit rates from January 2026, archived in `data/iilm_2026-01.json` with the source note. I treat them as simple annualized discount rates (Actual/365); that is a documented modeling choice, not a quoted convention. The UAE retail sukuk terms (5.06%, semi-annual, 2031-09-30 maturity) come from Nasdaq Dubai listing reports. Everything else in the demo is synthetic and labeled so.

## Honest limitations

The IILM curve covers only the short end: one month to one year, four points, one auction date. It is a primary-market snapshot, not a live secondary curve. Different credits sit at different levels, so do not mix these pillars with other issuers' paper. The UAE example uses published issuance terms; I have no secondary prices for it, so its risk numbers are computed at par. Day-count and compounding conventions are documented choices; check them against your market before relying on them. This is analytics code, not investment advice.

## References

IILM short-term sukuk auction results, January 2026. Nasdaq Dubai sukuk listing announcements. Standard fixed-income texts for duration and convexity arithmetic.
