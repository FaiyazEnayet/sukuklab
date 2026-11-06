# make_dashboard.jl - static HTML snapshot of notebook.jl for docs/dashboard.html.
#
# Pluto's own HTML export needs a running Pluto server, which this build
# environment cannot provide, so this script renders the same three sections
# directly: every number is read from the canonical results schema, and the
# zero-curve plot is inline SVG. The result is self-contained (no external
# resources) and ready to serve from docs/ via GitHub Pages.
#
# The schema is examples/results.json, exported by
# examples/make_results.jl from the SukukLab package. Regenerate it first
# after changing any analytics, then run this script. The schema is
# versioned (sukuklab/results/1); an unknown version stops the run
# instead of rendering stale numbers. The Python presentation path
# (examples/make_dashboard.py, run at the end of this script) renders
# the portfolio dashboard from the same schema file, so the two
# renderers cannot drift apart.
#
# Run from the repo root:
#   ~/.juliaup/bin/julia --project=. examples/make_dashboard.jl

r2(x) = round(x; digits=2)
r4(x) = round(x; digits=4)

# Minimal reader for the flat results schema: one "key": value pair per
# line, values are strings, numbers, or flat arrays of either. It reads
# the checked-in schema file; it is not a general JSON parser and must
# stay in step with examples/make_results.jl.
function read_results(path)
    data = Dict{String,Any}()
    for line in eachline(path)
        m = match(r"^  \"([^\"]+)\": (.*)$", line)
        m === nothing && continue
        key, raw = m.captures[1], m.captures[2]
        raw = endswith(raw, ",") ? raw[1:(end - 1)] : raw
        if startswith(raw, "\"")
            data[key] = raw[2:(end - 1)]
        elseif startswith(raw, "[")
            inner = strip(raw[2:(end - 1)])
            if isempty(inner)
                data[key] = Any[]
            elseif startswith(inner, "\"")
                data[key] = [s.captures[1] for s in
                             eachmatch(r"\"([^\"]*)\"", inner)]
            else
                data[key] = parse.(Float64, split(inner, ", "))
            end
        else
            data[key] = parse(Float64, raw)
        end
    end
    return data
end

results = read_results(joinpath(@__DIR__, "results.json"))
if get(results, "schema", "") != "sukuklab/results/1" ||
        get(results, "schema_version", 0) != 1
    error("unsupported results schema: expected sukuklab/results/1")
end

function html_table(headers, rows)
    h = join(["<th>$(c)</th>" for c in headers], "")
    b = join(["<tr>" * join(["<td>$(c)</td>" for c in r], "") * "</tr>"
              for r in rows], "\n")
    return "<table><thead><tr>$h</tr></thead><tbody>\n$b\n</tbody></table>"
end

# ------------------------------------------------ section 1: pricing ------
# Every value comes from the schema; the header is built from the same
# recorded terms, so the label cannot drift from the numbers.
sec1 = html_table(["Measure", "Value (profit $(r2(100 * results["playground_profit_rate"]))%, yield $(r2(100 * results["playground_ytm"]))%, 5y, face $(round(Int, results["playground_face"])))"],
    [["Clean price", r2(results["playground_clean_price"])],
     ["Cash flows", round(Int, results["playground_n_cashflows"])],
     ["Yield to maturity", "$(r4(100 * results["playground_ytm"]))%"],
     ["Macaulay duration", "$(r4(results["playground_macaulay_duration"])) years"],
     ["Modified duration", r4(results["playground_modified_duration"])],
     ["Convexity", r4(results["playground_convexity"])],
     ["DV01", r4(results["playground_dv01"])]])

# ------------------------------------------------ section 2: structures ----
function schedule_table(structure)
    dates = results["structure_$(structure)_dates"]
    amounts = results["structure_$(structure)_amounts"]
    rows = [["$(d)", r2(a)] for (d, a) in zip(dates, amounts)]
    return html_table(["Date", "Amount"],
        vcat(rows, [["Total", r2(sum(amounts))]]))
end
sec2_ijara = schedule_table("ijara")
sec2_murabaha = schedule_table("murabaha")
sec2_wakala = schedule_table("wakala")

# ------------------------------------------------ section 3: curve ---------
pillars = results["pillar_years"]
zeros = results["zero_rates"]
fwd = results["forward_6m_12m"]
sec3 = html_table(["Pillar", "Zero rate"],
    [["$(r4(t))y", "$(r4(100z))%"] for (t, z) in zip(pillars, zeros)])

# Presentation smoothing for the curve plot: linear interpolation
# between the schema pillars, flat outside them, mirroring the
# package curve convention. The plotted pillar dots are the schema
# values themselves.
function interp_zero(t)
    t <= pillars[1] && return zeros[1]
    t >= pillars[end] && return zeros[end]
    i = searchsortedlast(pillars, t)
    w = (t - pillars[i]) / (pillars[i + 1] - pillars[i])
    return zeros[i] * (1 - w) + zeros[i + 1] * w
end

# inline SVG zero-curve plot
ts = collect(range(0.03, 1.0; length=80))
zs = [100 * interp_zero(t) for t in ts]
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
             for (t, z) in zip(pillars, zeros)], "\n")
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
(1m 3.81%, 3m 3.84%, 6m 3.82%, 12m 3.45%). The series were issued on
15 January 2026 and mature on their actual published dates (25 February 2026,
9 April 2026, 23 July 2026, 14 January 2027). Rates are read from
<code>data/iilm_2026-01.json</code> through the package loader and treated as
simple annualized discount rates.</p>
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

# Render the sourced presentation from the checked-in Julia results.
let py = get(ENV, "PYTHON", "python"), root = dirname(@__DIR__)
    run(`$py $(joinpath(root, "examples", "make_dashboard.py"))`)
end
