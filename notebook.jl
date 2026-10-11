### A Pluto.jl notebook ###
# v0.20.4

using Markdown
using InteractiveUtils

# ╔═╡ 8f3a1c2e-4b5d-4e6f-8a7b-9c0d1e2f3a4b
md"""
# SukukLab playground

An interactive tour of [SukukLab](https://github.com/FaiyazEnayet/sukuklab): price a fixed-profit-rate sukuk, inspect ijara / murabaha / wakala cash-flow schedules, and bootstrap a profit-rate curve from auction rates. Move the sliders and everything below recomputes live.

No derivatives anywhere in this notebook. Just cash flows, curves, and risk.
"""

# ╔═╡ 1a2b3c4d-5e6f-47a8-b9c0-d1e2f3a4b5c6
begin
	# Load the SukukLab package from this folder's src/, so the notebook
	# always runs against the repo's own code.
	include(joinpath(@__DIR__, "src", "SukukLab.jl"))
	nothing
end

# ╔═╡ 2b3c4d5e-6f7a-48b9-c0d1-e2f3a4b5c6d7
using .SukukLab, Dates, PlutoUI

# ╔═╡ 3c4d5e6f-7a8b-49c0-d1e2-f3a4b5c6d7e8
md"""
## 1. Price a sukuk

Pick a profit rate, a market yield, a maturity and a face value. The price below is the present value of the sukuk's cash flows at the market yield. When the market yield equals the profit rate, the price sits right at face: par. (Dates use Actual/365, so half year periods are a day or two off exact halves; par holds to a few cents.)
"""

# ╔═╡ 4d5e6f7a-8b9c-4ad1-e2f3-a4b5c6d7e8f9
@bind nb_profit Slider(0.01:0.0025:0.12; default=0.0506, show_value=true)

# ╔═╡ 5e6f7a8b-9c0d-4be2-f3a4-b5c6d7e8f9a0
@bind nb_yield Slider(0.01:0.0025:0.12; default=0.0506, show_value=true)

# ╔═╡ 6f7a8b9c-0d1e-4cf3-a4b5-c6d7e8f9a0b1
@bind nb_years Slider(1:10; default=5, show_value=true)

# ╔═╡ 7a8b9c0d-1e2f-4ad4-b5c6-d7e8f9a0b1c2
@bind nb_face Slider(100:100:5000; default=1000, show_value=true)

# ╔═╡ 8b9c0d1e-2f3a-4be5-c6d7-e8f9a0b1c2d3
begin
	nb_terms = SukukTerms("Playground sukuk", nb_face, nb_profit,
		Date(2026, 1, 15), Date(2026, 1, 15) + Year(nb_years), 2, "ijara")
	nb_anchor = Date(2026, 1, 15)
	nb_cfs = payment_schedule(nb_terms)
	nb_price = price_from_cashflows(nb_cfs, nb_yield, nb_anchor; m=2)
	nb_ytm = ytm_from_price(nb_cfs, nb_price, nb_anchor; m=2)
	nb_mac = macaulay_duration(nb_cfs, nb_yield, nb_anchor; m=2)
	nb_mod = modified_duration(nb_cfs, nb_yield, nb_anchor; m=2)
	nb_cvx = convexity(nb_cfs, nb_yield, nb_anchor; m=2)
	nb_dv = dv01(nb_cfs, nb_yield, nb_anchor; m=2)
	nb_verdict = abs(nb_price - nb_face) < 0.5 ? "about par: market yield matches the profit rate" :
		nb_price > nb_face ? "premium: the market yield is below the profit rate" :
		"discount: the market yield is above the profit rate"
	md"""
	**Clean price: $(round(nb_price; digits=2))** on $(round(Int, nb_face)) face ($(nb_verdict)).

	| Measure | Value |
	|---|---|
	| Cash flows | $(length(nb_cfs)) |
	| Yield to maturity | $(round(100 * nb_ytm; digits=4))% |
	| Macaulay duration | $(round(nb_mac; digits=4)) years |
	| Modified duration | $(round(nb_mod; digits=4)) years |
	| Convexity | $(round(nb_cvx; digits=4)) |
	| DV01 | $(round(nb_dv; digits=4)) per $(round(Int, nb_face)) face |
	"""
end

# ╔═╡ 9c0d1e2f-3a4b-4cf6-d7e8-f9a0b1c2d3e4
md"""
## 2. Cash-flow structures

Ijara, murabaha and wakala are different funding mechanics, and they produce different payment shapes. Ijara pays lease-based periodic distributions with principal at maturity. Murabaha here is the installment shape: the deferred sale price, cost plus agreed profit, split into equal payments. Wakala pays distributions from an agency-managed pool, bullet style like ijara.
"""

# ╔═╡ 0d1e2f3a-4b5c-4ad7-e8f9-a0b1c2d3e4f5
@bind nb_structure Select(
	["ijara" => "Ijara: lease, bullet",
	 "murabaha" => "Murabaha: deferred sale, installments",
	 "wakala" => "Wakala: agency, bullet"];
	default="ijara")

# ╔═╡ 1e2f3a4b-5c6d-4be8-f9a0-b1c2d3e4f5a6
begin
	nb_amort = nb_structure == "murabaha"
	nb_terms2 = SukukTerms("$(nb_structure) example", 1000.0, 0.05,
		Date(2026, 1, 15), Date(2029, 1, 15), 2, nb_structure;
		amortizing=nb_amort)
	nb_cfs2 = payment_schedule(nb_terms2)
	nb_rows = join(["| $(cf.date) | $(round(cf.amount; digits=2)) |"
		for cf in nb_cfs2], "\n")
	md"""
	**$(nb_structure)**: $(length(nb_cfs2)) payments, $(round(sum(cf.amount for cf in nb_cfs2); digits=2)) total.

	| Date | Amount |
	|---|---|
	$(nb_rows)
	"""
end

# ╔═╡ 2f3a4b5c-6d7e-4cf9-a0b1-c2d3e4f5a6b7
md"""
## 3. Bootstrap a profit-rate curve

These four sliders start at the real IILM short-term sukuk auction clearing rates from January 2026: 3.81% (1m), 3.84% (3m), 3.82% (6m), 3.45% (12m). Each rate is treated as a simple annualized discount rate, and the bootstrap recovers every input point exactly. Move them and watch the curve change shape.
"""

# ╔═╡ 3a4b5c6d-7e8f-4ad0-b1c2-d3e4f5a6b7c8
@bind nb_r1m Slider(0.01:0.0005:0.08; default=0.0381, show_value=true)

# ╔═╡ 4b5c6d7e-8f9a-4be1-c2d3-e4f5a6b7c8d9
@bind nb_r3m Slider(0.01:0.0005:0.08; default=0.0384, show_value=true)

# ╔═╡ 5c6d7e8f-9a0b-4cf2-d3e4-f5a6b7c8d9e0
@bind nb_r6m Slider(0.01:0.0005:0.08; default=0.0382, show_value=true)

# ╔═╡ 6d7e8f9a-0b1c-4ad3-e4f5-a6b7c8d9e0f1
@bind nb_r12m Slider(0.01:0.0005:0.08; default=0.0345, show_value=true)

# ╔═╡ 7e8f9a0b-1c2d-4be4-f5a6-b7c8d9e0f1a2
begin
	nb_canchor = Date(2026, 1, 13)
	nb_instruments = Tuple{Vector{CashFlow},Float64}[]
	for (months, r) in ((1, nb_r1m), (3, nb_r3m), (6, nb_r6m), (12, nb_r12m))
		mat = nb_canchor + Month(months)
		T = yearfrac(nb_canchor, mat, :actual_365)
		push!(nb_instruments, ([CashFlow(mat, 100.0)], 100.0 / (1 + r * T)))
	end
	nb_curve = bootstrap(nb_instruments, nb_canchor)
	nb_fwd = forward_rate(nb_curve, 0.5, 1.0)
	nb_zrows = join(["| $(round(t; digits=4))y | $(round(100 * z; digits=4))% |"
		for (t, z) in zip(nb_curve.pillars, nb_curve.zeros)], "\n")
	md"""
	**Bootstrapped zero curve** (continuously compounded):

	| Pillar | Zero rate |
	|---|---|
	$(nb_zrows)

	6m/12m forward rate: **$(round(100 * nb_fwd; digits=4))%**.
	"""
end

# ╔═╡ 8f9a0b1c-2d3e-4cf5-a6b7-c8d9e0f1a2b3
begin
	nb_ts = collect(range(0.03, 1.0; length=80))
	nb_zs = [100 * zero_rate(nb_curve, t) for t in nb_ts]
	nb_zmin, nb_zmax = minimum(nb_zs), maximum(nb_zs)
	nb_pad = max(0.05, 0.15 * (nb_zmax - nb_zmin))
	nb_lo, nb_hi = nb_zmin - nb_pad, nb_zmax + nb_pad
	nb_W, nb_H = 520, 320
	nb_ml, nb_mr, nb_mt, nb_mb = 56, 16, 20, 40
	nb_x(t) = nb_ml + t / 1.05 * (nb_W - nb_ml - nb_mr)
	nb_y(z) = nb_mt + (1 - (z - nb_lo) / (nb_hi - nb_lo)) * (nb_H - nb_mt - nb_mb)
	nb_pts = join(["$(round(nb_x(t); digits=1)),$(round(nb_y(z); digits=1))"
		for (t, z) in zip(nb_ts, nb_zs)], " ")
	nb_dots = join(["<circle cx=\"$(round(nb_x(t); digits=1))\" cy=\"$(round(nb_y(100 * z); digits=1))\" r=\"4\" fill=\"#1f6feb\"/>"
		for (t, z) in zip(nb_curve.pillars, nb_curve.zeros)], "\n")
	HTML("""
	<svg width="$(nb_W)" height="$(nb_H)" style="background:white;border:1px solid #ddd;border-radius:8px" xmlns="http://www.w3.org/2000/svg">
	  <text x="$(nb_ml)" y="15" font-size="13" fill="#333">Zero curve, continuously compounded %</text>
	  <line x1="$(nb_ml)" y1="$(nb_y(nb_lo))" x2="$(nb_W - nb_mr)" y2="$(nb_y(nb_lo))" stroke="#999"/>
	  <line x1="$(nb_ml)" y1="$(nb_mt)" x2="$(nb_ml)" y2="$(nb_y(nb_lo))" stroke="#999"/>
	  <polyline points="$(nb_pts)" fill="none" stroke="#1f6feb" stroke-width="2"/>
	  $(nb_dots)
	  <text x="$(nb_ml)" y="$(nb_H - 10)" font-size="11" fill="#666">0y</text>
	  <text x="$(nb_x(1.0) - 6)" y="$(nb_H - 10)" font-size="11" fill="#666">1y</text>
	  <text x="6" y="$(nb_y(nb_hi) + 4)" font-size="11" fill="#666">$(round(nb_hi; digits=2))%</text>
	  <text x="6" y="$(nb_y(nb_lo) + 4)" font-size="11" fill="#666">$(round(nb_lo; digits=2))%</text>
	</svg>
	""")
end

# ╔═╡ 9a0b1c2d-3e4f-4ad6-b7c8-d9e0f1a2b3c4
md"""
## How to run this

You need [Julia](https://julialang.org) and [Pluto.jl](https://plutojl.org). From this folder:

```julia
using Pluto
Pluto.run(notebook="notebook.jl")
```

The notebook loads SukukLab straight from `src/`, so it always matches the repo. PlutoUI is the only extra dependency.

A static snapshot of this notebook lives at `docs/dashboard.html` for quick viewing without Julia.
"""

# ╠═╡ 8f3a1c2e-4b5d-4e6f-8a7b-9c0d1e2f3a4b
# ╠═╡ 1a2b3c4d-5e6f-47a8-b9c0-d1e2f3a4b5c6
# ╠═╡ 2b3c4d5e-6f7a-48b9-c0d1-e2f3a4b5c6d7
# ╠═╡ 3c4d5e6f-7a8b-49c0-d1e2-f3a4b5c6d7e8
# ╠═╡ 4d5e6f7a-8b9c-4ad1-e2f3-a4b5c6d7e8f9
# ╠═╡ 5e6f7a8b-9c0d-4be2-f3a4-b5c6d7e8f9a0
# ╠═╡ 6f7a8b9c-0d1e-4cf3-a4b5-c6d7e8f9a0b1
# ╠═╡ 7a8b9c0d-1e2f-4ad4-b5c6-d7e8f9a0b1c2
# ╠═╡ 8b9c0d1e-2f3a-4be5-c6d7-e8f9a0b1c2d3
# ╠═╡ 9c0d1e2f-3a4b-4cf6-d7e8-f9a0b1c2d3e4
# ╠═╡ 0d1e2f3a-4b5c-4ad7-e8f9-a0b1c2d3e4f5
# ╠═╡ 1e2f3a4b-5c6d-4be8-f9a0-b1c2d3e4f5a6
# ╠═╡ 2f3a4b5c-6d7e-4cf9-a0b1-c2d3e4f5a6b7
# ╠═╡ 3a4b5c6d-7e8f-4ad0-b1c2-d3e4f5a6b7c8
# ╠═╡ 4b5c6d7e-8f9a-4be1-c2d3-e4f5a6b7c8d9
# ╠═╡ 5c6d7e8f-9a0b-4cf2-d3e4-f5a6b7c8d9e0
# ╠═╡ 6d7e8f9a-0b1c-4ad3-e4f5-a6b7c8d9e0f1
# ╠═╡ 7e8f9a0b-1c2d-4be4-f5a6-b7c8d9e0f1a2
# ╠═╡ 8f9a0b1c-2d3e-4cf5-a6b7-c8d9e0f1a2b3
# ╠═╡ 9a0b1c2d-3e4f-4ad6-b7c8-d9e0f1a2b3c4

# ╙╜╡ 00000000-0000-0000-0000-000000000001
PLUTO_PROJECT_TOML_CONTENTS = """
[deps]
PlutoUI = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
"""

# ╙╜╡ 00000000-0000-0000-0000-000000000002
PLUTO_MANIFEST_TOML_CONTENTS = """
# This file is machine-generated - editing it directly is not advised

julia_version = "1.13.1"
manifest_format = "2.0"
project_hash = "0000000000000000000000000000000000000000"

[[deps.PlutoUI]]
git-tree-sha1 = "3bd0df8c7c15e0d7d4a4a66bb0ffceb52c7dcd09"
uuid = "7f904dfe-b85e-4ff6-b463-dae2292396a8"
version = "0.7.72"
"""
