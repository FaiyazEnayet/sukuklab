# IILM pricing-residual report for the reconstructed auction record.
#
# Regenerates two checked-in artifacts from data/iilm_2026-01.json:
#
#   examples/iilm_residuals.json
#   examples/iilm_residuals.csv
#
# Each series of the January 2026 IILM auction is priced twice: once by
# the model price under the record's designated convention (simple
# annualized discount rate, Actual/365, from the actual issue date to
# the actual maturity date), and once by discounting its cash flow on
# the bootstrapped zero curve. The report records both prices and the
# absolute residual per 100 face, together with the SHA-256 of the
# source data file, so a reader can confirm exactly which record the
# numbers came from.
#
# Usage: julia --project=. examples/make_iilm_residuals.jl

using Dates
using SHA
using SukukLab

const ROOT = joinpath(@__DIR__, "..")
const DATAFILE = joinpath(ROOT, "data", "iilm_2026-01.json")

record = load_auction_record(DATAFILE)
rows = pricing_residuals(record)
anchor = auction_anchor(record)
data_sha256 = bytes2hex(sha256(read(DATAFILE)))
max_residual = maximum(r.abs_residual for r in rows)

# ---------------------------------------------------------------------------
# JSON artifact (flat header fields plus one object per series).
# ---------------------------------------------------------------------------

function json_row(r)
    fields = [
        "\"series\": \"$(r.series)\"",
        "\"isin\": \"$(r.isin)\"",
        "\"tenor_label\": \"$(r.tenor_label)\"",
        "\"profit_rate\": $(repr(r.profit_rate))",
        "\"amount_usd_m\": $(repr(r.amount_usd_m))",
        "\"issue_date\": \"$(r.issue_date)\"",
        "\"maturity_date\": \"$(r.maturity_date)\"",
        "\"year_fraction\": $(repr(r.year_fraction))",
        "\"model_price_per_100\": $(repr(r.model_price))",
        "\"curve_price_per_100\": $(repr(r.curve_price))",
        "\"abs_residual_per_100\": $(repr(r.abs_residual))",
    ]
    return "    {" * join(fields, ", ") * "}"
end

io = IOBuffer()
println(io, "{")
println(io, "  \"generated_by\": \"examples/make_iilm_residuals.jl\",")
println(io, "  \"data_file\": \"data/iilm_2026-01.json\",")
println(io, "  \"data_file_sha256\": \"$data_sha256\",")
println(io, "  \"auction\": \"$(record.auction)\",")
println(io, "  \"auction_date\": \"$(record.auction_date)\",")
println(io, "  \"curve_anchor_issue_date\": \"$anchor\",")
println(io, "  \"rate_convention\": \"$(record.convention)\",")
println(io, "  \"face\": 100,")
println(io, "  \"max_abs_residual_per_100\": $(repr(max_residual)),")
println(io, "  \"instruments\": [")
println(io, join((json_row(r) for r in rows), ",\n"))
println(io, "  ]")
println(io, "}")
write(joinpath(ROOT, "examples", "iilm_residuals.json"), String(take!(io)))
println("wrote examples/iilm_residuals.json")

# ---------------------------------------------------------------------------
# CSV artifact (one row per series).
# ---------------------------------------------------------------------------

io = IOBuffer()
println(io, "series,isin,tenor_label,profit_rate,amount_usd_m,issue_date," *
            "maturity_date,year_fraction,model_price_per_100," *
            "curve_price_per_100,abs_residual_per_100")
for r in rows
    println(io, join([r.series, r.isin, r.tenor_label, repr(r.profit_rate),
                      repr(r.amount_usd_m), string(r.issue_date),
                      string(r.maturity_date), repr(r.year_fraction),
                      repr(r.model_price), repr(r.curve_price),
                      repr(r.abs_residual)], ","))
end
write(joinpath(ROOT, "examples", "iilm_residuals.csv"), String(take!(io)))
println("wrote examples/iilm_residuals.csv")
println("max abs residual per 100 face: $max_residual")
