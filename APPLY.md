# SukukLab generator update

Copy the contents of this folder into your own checkout when ready. This package did not modify any existing checkout or GitHub.

Install your repository's original generator dependencies, plus `python -m pip install -r portfolio_ui/requirements.txt`.
Run `julia --project=. examples/make_dashboard.jl` from the repository root. Its final write calls `examples/make_dashboard.py`, which validates the dated auction record, canonical results, valuation fixture, and calibration residuals before producing `docs/dashboard.html`. Python's standard library is required for this presentation step.

To rebuild this exact recorded snapshot without retraining:

`python portfolio_ui/renderer.py --repo sukuklab --root . --input portfolio_ui/original-dashboard-snapshot.html --output docs/dashboard.html`

You can also run `python examples/make_dashboard.py` directly. It builds the same standalone dashboard from the checked-in Julia results and dated valuation fixture.

The HTML itself needs no Python, Julia, Go, network or server.
