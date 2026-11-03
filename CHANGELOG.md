# Changelog

## Unreleased

### Added
- Golden fixtures pinning the schedule and day-count conventions to hand-computed values: a seven-month semiannual instrument (one regular period plus a one-month final stub paying its 30/360 fraction of 5 per 1,000 face, with accrued profit inside the stub accruing the stub distribution), and February-end to February-end 30/360 spans (2024-02-29 to 2025-02-28 is exactly one year under the bond-basis rules). The remaining acceptance clauses (month-end and leap-day schedules, duplicate pillar rejection, stub fractions) were audited against the existing fixtures and already hold.

### Added
- `calibration_report` in `src/curve.jl`: runs the sequential bootstrap and reports the outcome instead of only returning a curve or throwing. It returns a status (`:exact`, `:approximate` or `:infeasible`), the fitted curve (absent when infeasible), one repricing row per instrument (maturity, quoted price, model price, absolute residual, status), the largest residual, and a message naming the instrument that cannot be fitted when a quote set has no solution. The bootstrap's exactness scope is documented with it: it reprices the instruments it calibrates exactly, because each new pillar sits beyond every cash flow of the instruments already fitted; it is not a joint fit, and duplicate maturity quotes are rejected rather than averaged.
- Two curve conventions are now stated where the API is defined: the discount factor at the anchor is exactly 1 (the zero rate at t = 0 remains undefined), and interpolated forwards may be negative on a steeply falling curve and are reported rather than floored at zero.

### Fixed
- `ZeroCurve` construction now enforces what its documentation always claimed: pillars must be strictly increasing (a repeated pillar previously passed the sortedness check and later divided by the zero gap between the duplicates during interpolation), and pillars and zero rates must be finite (a NaN zero rate previously constructed fine and silently made every discount factor NaN).
- `bootstrap` validates the whole quote set before solving: an instrument with no cash flows (previously an indexing error when it was not the shortest instrument), cash flows out of date order or sharing a date, non-positive or non-finite cash-flow amounts, a cash flow dated before the anchor, a non-positive or non-finite quoted price, and duplicate maturity quotes (previously a silent duplicate pillar) are all rejected with explicit errors, and a quote with no solution is rejected naming the instrument's maturity.

### Added
- Contract-grade dated cash flows in `src/cashflows.jl`: schedules are modeled as explicit `DistributionPeriod`s (unadjusted contractual start and finish, payment date, regular/stub flag) generated from the anchor (`distribution_periods`), a `DayCount` enumeration (`Thirty360`, `Actual365`) alongside the existing symbols, a weekend business-day adjustment declared on the terms (`adjustment=:following`, `:modified_following` or `:preceding`; default `:unadjusted`), and an explicit payment-rounding policy on `payment_schedule` (default full precision; `rounding=:cent` rounds each payment to cents with the installment residual absorbed by the final payment).
- `price_decomposition` and `ytm_from_clean_price` in `src/analytics.jl`: a settlement price as three distinct quantities (full price, accrued profit, clean price) that reconcile exactly, and yield recovery from a quoted clean price.

### Fixed
- Schedule generation no longer steps month by month from an already-clamped date. A monthly schedule issued on the 30th previously paid on the 28th from March onward, and a semi-annual issued 2026-08-31 never landed on leap day 2028-02-29; dates are now computed from the issue anchor in one step, end-of-month anchors stay on month ends, and the spurious short final periods the drift created are gone.
- A final stub period previously paid a full regular distribution. It now pays its actual 30/360 fraction, and accrued profit inside a stub accrues that stub distribution.
- The 30/360 day count now follows the bond-basis rules: a second date on the 31st is kept when the first date is below the 30th (2026-01-29 to 2026-01-31 is 2/360, was 1/360), and February end-of-month dates count as the 30th (2026-02-28 to 2026-08-28 is 178/360, was 180/360; 2024-02-29 to 2024-08-29 is 179/360).
- The closed-form pricer rejected nothing: a maturity that is not a whole number of periods was silently rounded to the nearest period count. `sukuk_price` (and `sukuk_ytm` through it) now raises an error for non-whole-period maturity/frequency pairs and points at the dated schedule.
- Price presentation: the settlement present value was labeled a clean price in the README, the demo and the notebook even though it includes accrued profit. It is now presented as the full price, with accrued profit and the clean price stated separately (UAE retail T-Sukuk at settlement 2026-10-10: full 1000, accrued 1.41, clean 998.59 on 1000 face; no other quoted number changed).

### Added
- Published-terms reconstruction of the IILM auction record (`data/iilm_2026-01.json`): each of the four January 2026 series now carries its series number, ISIN, amount, clearing profit rate, actual issue date (2026-01-15) and published maturity date, the verbatim press-release quote, and its sources, with the auction date (2026-01-13) stored separately as the observation time.
- `src/marketdata.jl`: a validated loader (`load_auction_record`) for the auction record, with strict errors on missing or blank issue/maturity dates, unknown rate conventions, mixed issuers or currencies, and duplicate identifiers, plus model pricing under the record's named convention (simple profit rate, Actual/365) and per-series pricing residuals (`pricing_residuals`).
- `examples/make_iilm_residuals.jl`: regenerates the pricing-residual report (`examples/iilm_residuals.json` and `.csv`) with the source data file's SHA-256; all four residuals are 0.0 per 100 face.

### Changed
- The bootstrapped IILM curve now anchors on the actual issue date (2026-01-15) and places pillars at the real times to maturity (0.112, 0.230, 0.518, 0.997 years; zero rates 3.8019%, 3.8231%, 3.7827%, 3.3920%; 6m/12m forward 2.9987%), replacing pillars derived from tenor labels plus the observation date. The demo, notebook, dashboard builder, and results generator all load the auction record through the same validated loader, and `examples/results.json` records the series identifiers and maturity dates alongside the rates.
### Added
- Canonical machine-readable results file (examples/results.json), generated by examples/make_results.jl through the package alone. The test suite recomputes every value and checks the README-quoted demo numbers against it; CI fails if the checked-in file differs from a fresh regeneration.
- Shared Julia/Python valuation parity fixtures (test/fixtures/valuation_parity.json) with an independent standard-library Python checker (test/check_parity.py): schedules, prices and yields agree to within 1e-8 per 1,000 face. CI runs the checker on every push and pull request.
- Clean-checkout reproducibility instructions in the README.

### Removed
- src/svi.jl: retired SVI implied-volatility surface code. It was never included by the package entry point, was exercised by no test, and imported a package that is not a project dependency. New tests fail if any source file under src/ is not included by the entry point or if the retired derivatives source returns.

### Fixed
- Project.toml version reconciled from 0.2.0 to 1.1.0, matching the existing v1.1.0 release and CHANGELOG heading. No new tag or release. A test now asserts the two stay coherent.
- README stale claims: the suite size (83 was quoted; the suite had grown past it) and the package entry point listed as src/sukuklab.jl instead of src/SukukLab.jl.

### Docs
- Centered the README header with the repo banner: uniform dark badge labels and three action buttons (Open Dashboard, Explore Notebook, Run Locally) with a black label side so they stand out on the page.

## v1.1.0

### Fixed
- Curve bootstrapping now root-solves each new pillar on the full instrument
  present value using the candidate curve that already includes the new
  pillar, instead of discounting intermediate coupons on the old curve.
  With linear zero-rate interpolation, the new pillar changes discount
  factors for dates between the old and new pillars; freezing coupons on
  the old curve left a repricing error (~0.02/100 in the regression test).

### Tests
- New `bootstrap_reprices_between_pillars` regression test; suite 97/97 green.
