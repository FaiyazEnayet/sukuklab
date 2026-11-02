# Canonical results generator for SukukLab.
#
# Every number quoted in the README's "Measured results" section comes
# from this single Julia calculation path through the SukukLab package.
# Running this script regenerates two checked-in artifacts:
#
#   examples/results.json                  (canonical results file)
#   test/fixtures/valuation_parity.json    (shared Julia/Python fixtures)
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

anchor = Date(2026, 1, 13)
iilm = [(1, 0.0381), (3, 0.0384), (6, 0.0382), (12, 0.0345)]
instruments = Tuple{Vector{CashFlow},Float64}[]
for (months, r) in iilm
    mat = anchor + Month(months)
    T = yearfrac(anchor, mat, :actual_365)
    price = 100.0 / (1 + r * T)
    push!(instruments, ([CashFlow(mat, 100.0)], price))
end
curve = bootstrap(instruments, anchor)
max_reprice_error = maximum(
    abs(sum(cf.amount * discount(curve, cf.date) for cf in cfs) - price)
    for (cfs, price) in instruments)
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

results = Pair{String,Any}[
    "generated_by" => "examples/make_results.jl",
    "calculation_path" => "SukukLab Julia package only",
    "iilm_anchor" => "2026-01-13",
    "iilm_months" => [1, 3, 6, 12],
    "iilm_rates" => [0.0381, 0.0384, 0.0382, 0.0345],
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
