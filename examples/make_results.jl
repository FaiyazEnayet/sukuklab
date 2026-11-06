# Canonical results generator for SukukLab.
#
# Every number quoted in the README's "Measured results" section comes
# from this single Julia calculation path through the SukukLab package.
# Running this script regenerates two checked-in artifacts:
#
#   examples/results.json                  (canonical results file)
#   test/fixtures/valuation_parity.json    (shared Julia/Python fixtures)
#
# results.json is the one versioned schema (sukuklab/results/1) both
# renderers consume: examples/make_dashboard.jl renders its snapshot
# from it, and examples/make_dashboard.py renders the portfolio
# dashboard from it. The schema records its version, the Julia
# version that generated it, and the source dates of the IILM record,
# so a renderer can refuse an unknown schema instead of rendering
# stale numbers, and a reader can tell when the inputs were published
# and retrieved. New analytics belong here first; renderers must not
# recompute them inline.
#
# Inputs are the documented public ones, identical to examples/demo.jl:
# the IILM January 2026 auction clearing rates archived in
# data/iilm_2026-01.json, the UAE retail T-Sukuk published terms, and
# the labeled synthetic three-holding portfolio from the demo.
#
# Usage: julia --project=. examples/make_results.jl

using Dates
using SukukLab

const ROOT = joinpath(@__DIR__, "..")

# ---------------------------------------------------------------------------
# JSON writing helpers (flat, stable layout: one key per line, full precision)
# ---------------------------------------------------------------------------

fmt(x::Float64) = repr(x)
fmt(x::Integer) = string(x)
fmt(s::AbstractString) = "\"" * s * "\""
fmt(v::Vector{Int}) = "[" * join((string(x) for x in v), ", ") * "]"
fmt(v::Vector{Float64}) = "[" * join((repr(x) for x in v), ", ") * "]"
fmt(v::Vector{String}) = "[" * join(("\"" * x * "\"" for x in v), ", ") * "]"

function write_json(path, pairs)
    io = IOBuffer()
    println(io, "{")
    for (i, (k, v)) in enumerate(pairs)
        comma = i < length(pairs) ? "," : ""
        println(io, "  \"", k, "\": ", fmt(v), comma)
    end
    println(io, "}")
    write(path, String(take!(io)))
    return path
end

# ---------------------------------------------------------------------------
# 1. IILM short-end curve (real published auction, January 2026)
# ---------------------------------------------------------------------------

record = load_auction_record(joinpath(ROOT, "data", "iilm_2026-01.json"))
anchor = auction_anchor(record)
instruments = auction_instruments(record)
curve = bootstrap(instruments, anchor)
max_reprice_error = maximum(r.abs_residual for r in pricing_residuals(record))
fwd_6m_12m = forward_rate(curve, 0.5, 1.0)

# ---------------------------------------------------------------------------
# 2. UAE retail T-Sukuk (real published terms), valued at par on 2026-10-10
# ---------------------------------------------------------------------------

uae = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                 Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
uae_cfs = payment_schedule(uae)
settle = Date(2026, 10, 10)
uae_ytm = ytm_from_price(uae_cfs, 1000.0, settle)

# ---------------------------------------------------------------------------
# 3. Illustrative three-holding portfolio (synthetic, labeled as such)
# ---------------------------------------------------------------------------

function mk_holding(terms, price, qty, sdate)
    sc = remaining_cashflows(payment_schedule(terms), sdate)
    yy = ytm_from_price(sc, price, sdate)
    return Holding(terms.name, price * qty, yy,
                   modified_duration(sc, yy, sdate), convexity(sc, yy, sdate))
end

pa = SukukTerms("Illustrative 3y 4.5%", 1000.0, 0.045,
                Date(2026, 1, 15), Date(2029, 1, 15), 2, "wakala")
pb = SukukTerms("Illustrative 5y 5.0%", 1000.0, 0.050,
                Date(2026, 1, 15), Date(2031, 1, 15), 2, "ijara")
pc = SukukTerms("Illustrative 7y 5.25% murabaha", 1000.0, 0.0525,
                Date(2026, 1, 15), Date(2033, 1, 15), 2, "murabaha";
                amortizing=true)
holdings = [mk_holding(pa, 990.0, 50, settle), mk_holding(pb, 1010.0, 30, settle),
            mk_holding(pc, 1000.0, 20, settle)]

# ---------------------------------------------------------------------------
# 4. Playground pricing and structures (dashboard sections 1-2), and the
# UAE price sweep (the dashboard price chart payload). The dashboard
# snapshot used to recompute these inline; it now renders them from
# this export, so the values cannot drift from the package.
# ---------------------------------------------------------------------------

play_terms = SukukTerms("Playground sukuk", 1000.0, 0.0506,
                        Date(2026, 1, 15), Date(2026, 1, 15) + Year(5),
                        2, "ijara")
play_anchor = Date(2026, 1, 15)
play_cfs = payment_schedule(play_terms)
play_y = 0.0506
play_p = price_from_cashflows(play_cfs, play_y, play_anchor; m=2)

struct_issue = Date(2026, 1, 15)
struct_maturity = Date(2029, 1, 15)
function structure_schedule(structure, amortizing)
    terms = SukukTerms("$structure example", 1000.0, 0.05,
                       struct_issue, struct_maturity, 2, structure;
                       amortizing=amortizing)
    return payment_schedule(terms)
end
ijara_cfs = structure_schedule("ijara", false)
murabaha_cfs = structure_schedule("murabaha", true)
wakala_cfs = structure_schedule("wakala", false)

# Sweep over the same remaining cash flows the shared valuation
# fixture carries, so the Python checker can recompute it from the
# fixture alone. Yields are in percent, matching the chart axis.
sweep_yields = [2.0 + i / 10 for i in 0:70]
sweep_cfs = remaining_cashflows(uae_cfs, settle)
sweep_prices = [price_from_cashflows(sweep_cfs, y / 100, settle; m=2)
                for y in sweep_yields]

results = Pair{String,Any}[
    "generated_by" => "examples/make_results.jl",
    "calculation_path" => "SukukLab Julia package only",
    "schema" => "sukuklab/results/1",
    "schema_version" => 1,
    # Major.minor of the generating Julia: stable across patch
    # releases, so the file only changes when the pinned Julia
    # version moves. CI pins that version (see .github/workflows/ci.yml).
    "julia_version" => string(VERSION.major) * "." * string(VERSION.minor),
    # Source dates, taken from the record itself: the auction date,
    # and the published and retrieved dates of its three sources.
    "iilm_source_published_dates" => [string(s.published)
                                       for s in record.sources
                                       if s.published !== nothing],
    "iilm_source_retrieved_dates" => [string(s.retrieved)
                                       for s in record.sources],
    "iilm_anchor" => string(anchor),
    "iilm_auction_date" => string(record.auction_date),
    "iilm_series" => [i.series for i in record.instruments],
    "iilm_isins" => [i.isin for i in record.instruments],
    "iilm_months" => [i.tenor_months for i in record.instruments],
    "iilm_rates" => [i.profit_rate for i in record.instruments],
    "iilm_maturities" => [string(i.maturity_date) for i in record.instruments],
    "pillar_years" => collect(curve.pillars),
    "zero_rates" => collect(curve.zeros),
    "forward_6m_12m" => fwd_6m_12m,
    "max_reprice_error" => max_reprice_error,
    "uae_settlement" => "2026-10-10",
    "uae_n_cashflows" => length(uae_cfs),
    "uae_ytm" => uae_ytm,
    "uae_current_yield" => current_yield(1000 * 0.0506, 1000.0),
    "uae_macaulay_duration" => macaulay_duration(uae_cfs, uae_ytm, settle),
    "uae_modified_duration" => modified_duration(uae_cfs, uae_ytm, settle),
    "uae_convexity" => convexity(uae_cfs, uae_ytm, settle),
    "uae_dv01" => dv01(uae_cfs, uae_ytm, settle),
    "uae_price_shift_100bp" => price_under_shift(uae_cfs, uae_ytm, 100, settle),
    "uae_accrued" => accrued_profit(uae, settle),
    "portfolio_value" => portfolio_value(holdings),
    "portfolio_weighted_ytm" => weighted_ytm(holdings),
    "portfolio_weighted_duration" => weighted_duration(holdings),
    "portfolio_weighted_convexity" => weighted_convexity(holdings),
    "playground_face" => play_terms.face,
    "playground_profit_rate" => play_terms.profit_rate,
    "playground_issue" => string(play_terms.issue),
    "playground_maturity" => string(play_terms.maturity),
    "playground_freq" => play_terms.freq,
    "playground_structure" => play_terms.structure,
    "playground_anchor" => string(play_anchor),
    # At the anchor (the issue date) accrued profit is zero, so the
    # full price and the clean price coincide; the dashboard labels
    # this value its clean price.
    "playground_clean_price" => play_p,
    "playground_n_cashflows" => length(play_cfs),
    "playground_ytm" => ytm_from_price(play_cfs, play_p, play_anchor; m=2),
    "playground_macaulay_duration" => macaulay_duration(play_cfs, play_y, play_anchor; m=2),
    "playground_modified_duration" => modified_duration(play_cfs, play_y, play_anchor; m=2),
    "playground_convexity" => convexity(play_cfs, play_y, play_anchor; m=2),
    "playground_dv01" => dv01(play_cfs, play_y, play_anchor; m=2),
    "structure_face" => 1000.0,
    "structure_profit_rate" => 0.05,
    "structure_issue" => string(struct_issue),
    "structure_maturity" => string(struct_maturity),
    "structure_freq" => 2,
    "structure_ijara_dates" => [string(cf.date) for cf in ijara_cfs],
    "structure_ijara_amounts" => [cf.amount for cf in ijara_cfs],
    "structure_murabaha_dates" => [string(cf.date) for cf in murabaha_cfs],
    "structure_murabaha_amounts" => [cf.amount for cf in murabaha_cfs],
    "structure_wakala_dates" => [string(cf.date) for cf in wakala_cfs],
    "structure_wakala_amounts" => [cf.amount for cf in wakala_cfs],
    "uae_price_sweep_yield_pct" => sweep_yields,
    "uae_price_sweep_prices" => sweep_prices,
]
write_json(joinpath(ROOT, "examples", "results.json"), results)
println("wrote examples/results.json")

# ---------------------------------------------------------------------------
# Shared Julia/Python valuation parity fixtures.
# Each case carries its terms, anchor and compounding frequency, the Julia
# schedule, and Julia price/yield values. test/check_parity.py rebuilds the
# schedule and the valuations independently in Python from the terms alone
# and asserts agreement to at most 1e-8 absolute per 1,000 face.
# ---------------------------------------------------------------------------

function case_block(name, terms, anchor_date, yields, ytm_prices)
    cfs = remaining_cashflows(payment_schedule(terms), anchor_date)
    io = IOBuffer()
    println(io, "    \"", name, "\": {")
    println(io, "      \"face\": ", fmt(terms.face), ",")
    println(io, "      \"profit_rate\": ", fmt(terms.profit_rate), ",")
    println(io, "      \"issue\": \"", terms.issue, "\",")
    println(io, "      \"maturity\": \"", terms.maturity, "\",")
    println(io, "      \"freq\": ", terms.freq, ",")
    println(io, "      \"structure\": ", fmt(terms.structure), ",")
    println(io, "      \"amortizing\": ", terms.amortizing, ",")
    println(io, "      \"anchor\": \"", anchor_date, "\",")
    println(io, "      \"m\": 2,")
    cf_strs = ["[\"" * string(cf.date) * "\", " * repr(cf.amount) * "]"
               for cf in cfs]
    println(io, "      \"cashflows\": [", join(cf_strs, ", "), "],")
    pc_strs = ["{\"yield\": " * repr(y) * ", \"price\": " *
               repr(price_from_cashflows(cfs, y, anchor_date)) * "}"
               for y in yields]
    println(io, "      \"price_checks\": [", join(pc_strs, ", "), "],")
    yc_strs = ["{\"price\": " * repr(p) * ", \"ytm\": " *
               repr(ytm_from_price(cfs, p, anchor_date)) * "}"
               for p in ytm_prices]
    println(io, "      \"ytm_checks\": [", join(yc_strs, ", "), "]")
    print(io, "    }")
    return String(take!(io))
end

cases = [
    case_block("uae_bullet", uae, settle, [0.03, 0.05089, 0.07], [1000.0, 957.66]),
    case_block("wakala_3y",
               SukukTerms("Illustrative 3y 4.5%", 1000.0, 0.045,
                          Date(2026, 1, 15), Date(2029, 1, 15), 2, "wakala"),
               Date(2026, 1, 15), [0.03, 0.045, 0.055], [990.0]),
    case_block("murabaha_installments",
               SukukTerms("Illustrative 7y 5.25% murabaha", 1000.0, 0.0525,
                          Date(2026, 1, 15), Date(2033, 1, 15), 2, "murabaha";
                          amortizing=true),
               Date(2026, 1, 15), [0.04, 0.0525, 0.06], [1000.0]),
]

io = IOBuffer()
println(io, "{")
println(io, "  \"generated_by\": \"examples/make_results.jl\",")
println(io, "  \"tolerance_per_1000_face\": 1e-8,")
println(io, "  \"cases\": {")
println(io, join(cases, ",\n"))
println(io, "  }")
println(io, "}")
mkpath(joinpath(ROOT, "test", "fixtures"))
write(joinpath(ROOT, "test", "fixtures", "valuation_parity.json"),
      String(take!(io)))
println("wrote test/fixtures/valuation_parity.json")
