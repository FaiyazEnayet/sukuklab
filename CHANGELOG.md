# Changelog

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
