# make_dashboard.jl — static HTML snapshot of notebook.jl for docs/dashboard.html.
#
# Pluto's own HTML export needs a running Pluto server, which this build
# environment cannot provide, so this script renders the same three sections
# directly: every number is computed live from SukukLab, and the zero-curve
# plot is inline SVG. The result is self-contained (no external resources)
# and ready to serve from docs/ via GitHub Pages.
#
# Run from the repo root:
#   ~/.juliaup/bin/julia --project=. examples/make_dashboard.jl

using SukukLab
using Dates

r2(x) = round(x; digits=2)
r4(x) = round(x; digits=4)

function html_table(headers, rows)
    h = join(["<th>$(c)</th>" for c in headers], "")
    b = join(["<tr>" * join(["<td>$(c)</td>" for c in r], "") * "</tr>"
              for r in rows], "\n")
    return "<table><thead><tr>$h</tr></thead><tbody>\n$b\n</tbody></table>"
end

# ------------------------------------------------ section 1: pricing ------
terms1 = SukukTerms("Playground sukuk", 1000.0, 0.0506,
                    Date(2026, 1, 15), Date(2026, 1, 15) + Year(5), 2, "ijara")
anchor1 = Date(2026, 1, 15)
cfs1 = payment_schedule(terms1)
y1 = 0.0506
p1 = price_from_cashflows(cfs1, y1, anchor1; m=2)
ytm1 = ytm_from_price(cfs1, p1, anchor1; m=2)
sec1 = html_table(["Measure", "Value (profit 5.06%, yield 5.06%, 5y, face 1000)"],
    [["Clean price", r2(p1)],
     ["Cash flows", length(cfs1)],
     ["Yield to maturity", "$(r4(100ytm1))%"],
     ["Macaulay duration", "$(r4(macaulay_duration(cfs1, y1, anchor1; m=2))) years"],
     ["Modified duration", r4(modified_duration(cfs1, y1, anchor1; m=2))],
     ["Convexity", r4(convexity(cfs1, y1, anchor1; m=2))],
     ["DV01", r4(dv01(cfs1, y1, anchor1; m=2))]])

# ------------------------------------------------ section 2: structures ----
function schedule_table(structure, amortizing)
    t = SukukTerms("$structure example", 1000.0, 0.05,
                   Date(2026, 1, 15), Date(2029, 1, 15), 2, structure;
                   amortizing=amortizing)
    cfs = payment_schedule(t)
    rows = [["$(cf.date)", r2(cf.amount)] for cf in cfs]
    return html_table(["Date", "Amount"],
        vcat(rows, [["Total", r2(sum(cf.amount for cf in cfs))]]))
end
sec2_ijara = schedule_table("ijara", false)
sec2_murabaha = schedule_table("murabaha", true)
sec2_wakala = schedule_table("wakala", false)

# ------------------------------------------------ section 3: curve ---------
# Read the real IILM auction rates straight from the data file.
raw = read("data/iilm_2026-01.json", String)
pairs = [(parse(Int, m.captures[1]), parse(Float64, m.captures[2]))
         for m in eachmatch(r"\"months\":(\d+)[^}]*?\"profit_rate\":([\d.]+)", raw)]
@assert length(pairs) == 4
canchor = Date(2026, 1, 13)
instruments = Tuple{Vector{CashFlow},Float64}[]
for (months, r) in pairs
    mat = canchor + Month(months)
    T = yearfrac(canchor, mat, :actual_365)
    push!(instruments, ([CashFlow(mat, 100.0)], 100.0 / (1 + r * T)))
end
curve = bootstrap(instruments, canchor)
fwd = forward_rate(curve, 0.5, 1.0)
sec3 = html_table(["Pillar", "Zero rate"],
    [["$(r4(t))y", "$(r4(100z))%"] for (t, z) in zip(curve.pillars, curve.zeros)])

# inline SVG zero-curve plot
ts = collect(range(0.03, 1.0; length=80))
zs = [100 * zero_rate(curve, t) for t in ts]
zmin, zmax = minimum(zs), maximum(zs)
pad = max(0.05, 0.15 * (zmax - zmin))
zlo, zhi = zmin - pad, zmax + pad
W, H = 520, 320
ml, mr, mt, mb = 56, 16, 20, 40
X(t) = ml + t / 1.05 * (W - ml - mr)
Y(z) = mt + (1 - (z - zlo) / (zhi - zlo)) * (H - mt - mb)
pts = join(["$(round(X(t); digits=1)),$(round(Y(z); digits=1))"
            for (t, z) in zip(ts, zs)], " ")
dots = join(["<circle cx=\"$(round(X(t); digits=1))\" cy=\"$(round(Y(100z); digits=1))\" r=\"4\" fill=\"#1f6feb\"/>"
             for (t, z) in zip(curve.pillars, curve.zeros)], "\n")
svg = """
<svg width="$W" height="$H" style="background:white;border:1px solid #ddd;border-radius:8px" xmlns="http://www.w3.org/2000/svg">
  <text x="$ml" y="15" font-size="13" fill="#333">Zero curve, continuously compounded %</text>
  <line x1="$ml" y1="$(Y(zlo))" x2="$(W - mr)" y2="$(Y(zlo))" stroke="#999"/>
  <line x1="$ml" y1="$mt" x2="$ml" y2="$(Y(zlo))" stroke="#999"/>
  <polyline points="$pts" fill="none" stroke="#1f6feb" stroke-width="2"/>
  $dots
  <text x="$ml" y="$(H - 10)" font-size="11" fill="#666">0y</text>
  <text x="$(X(1.0) - 6)" y="$(H - 10)" font-size="11" fill="#666">1y</text>
  <text x="6" y="$(Y(zhi) + 4)" font-size="11" fill="#666">$(round(zhi; digits=2))%</text>
  <text x="6" y="$(Y(zlo) + 4)" font-size="11" fill="#666">$(round(zlo; digits=2))%</text>
</svg>"""

html = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>SukukLab playground (static snapshot)</title>
<style>
body { font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
       max-width: 860px; margin: 2em auto; padding: 0 1em; color: #1a1a1a;
       line-height: 1.55; }
h1 { font-size: 1.8em; } h2 { margin-top: 2em; border-bottom: 1px solid #ddd;
       padding-bottom: 0.3em; }
table { border-collapse: collapse; margin: 1em 0; }
th, td { border: 1px solid #ccc; padding: 0.35em 0.8em; text-align: left; }
th { background: #f6f8fa; }
code { background: #f6f8fa; padding: 0.1em 0.3em; border-radius: 4px; }
.note { background: #fffbe6; border: 1px solid #e6d96e; border-radius: 8px;
        padding: 0.8em 1em; }
img.demo { max-width: 100%; border: 1px solid #ddd; border-radius: 8px; }
.grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
        gap: 1em; }
</style>
</head>
<body>
<h1>SukukLab playground</h1>
<p>A static snapshot of <code>notebook.jl</code>, the interactive Pluto
notebook in this repo. Every number below was computed by running SukukLab;
the live version lets you move sliders and watch it all recompute.</p>

<h2>1. Price a sukuk</h2>
$sec1
<p><img class="demo" src="demo.gif" alt="Animated sweep of the UAE T-Sukuk price as the market yield moves from 2% to 9%"></p>

<h2>2. Cash-flow structures</h2>
<p>Three year, 5% annual, semi-annual. Ijara and wakala pay periodic
distributions with principal at maturity; murabaha pays the deferred sale
price in equal installments.</p>
<div class="grid">
<div><h3>Ijara (bullet)</h3>$sec2_ijara</div>
<div><h3>Murabaha (installments)</h3>$sec2_murabaha</div>
<div><h3>Wakala (bullet)</h3>$sec2_wakala</div>
</div>

<h2>3. Bootstrapped profit-rate curve</h2>
<p>From the real IILM short-term sukuk auction clearing rates, January 2026
(1m 3.81%, 3m 3.84%, 6m 3.82%, 12m 3.45%), read from
<code>data/iilm_2026-01.json</code> and treated as simple annualized discount
rates.</p>
$sec3
<p>6m/12m forward rate: <strong>$(r4(100fwd))%</strong>.</p>
$svg

<h2>Run it live</h2>
<p>You need <a href="https://julialang.org">Julia</a> and
<a href="https://plutojl.org">Pluto.jl</a>. From the repo root:</p>
<pre><code>using Pluto
Pluto.run(notebook="notebook.jl")</code></pre>

<div class="note"><p><strong>Note.</strong> This page is a static snapshot.
The notebook is interactive: sliders for profit rate, market yield, maturity
and face value, a structure picker, and editable auction rates. The snapshot
shows the notebook's default values.</p></div>
</body>
</html>
"""

mkpath("docs")
write("docs/dashboard.html", html)
println("wrote docs/dashboard.html: $(length(html)) chars")
