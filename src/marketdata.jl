using Downloads
using JSON
using Dates
using Statistics: median

"""
Real market data: free delayed CBOE option quotes, no API key.

    chain = fetch_chain("SPY")          # live pull (~15 min delayed)
    clean = clean_chain(chain.quotes)   # liquid, sensibly quoted rows

`fetch_chain` returns `(ticker, timestamp, spot, quotes)` where each quote
is a NamedTuple `(expiry, strike, is_call, bid, ask, volume,
open_interest, cboe_iv, theo)`. Option symbols look like
`SPY261012C00550000`: ticker, YYMMDD expiry, C/P, strike in thousandths.
"""

const CBOE_URL = "https://cdn.cboe.com/api/global/delayed_quotes/options"

const _OPT_RE = r"^([A-Z]+)(\d{6})([CP])(\d{8})$"

function _parse_option_symbol(sym::AbstractString)
    m = match(_OPT_RE, sym)
    m === nothing && return nothing
    yymmdd = m.captures[2]
    expiry = Date("20" * yymmdd, "yyyymmdd")
    strike = parse(Int, m.captures[4]) / 1000.0
    is_call = m.captures[3] == "C"
    return (expiry=expiry, strike=strike, is_call=is_call)
end

"""Fetch the full delayed option chain for `ticker` (e.g. "SPY")."""
function fetch_chain(ticker::AbstractString)
    t = uppercase(strip(ticker))
    url = "$CBOE_URL/$t.json"
    buf = try
        Downloads.download(url, IOBuffer(); timeout=120)
    catch e
        throw(ErrorException("CBOE request failed for $t: $(sprint(showerror, e))"))
    end
    body = String(take!(buf))
    isempty(body) && throw(ErrorException("CBOE returned an empty body for $t"))
    return parse_chain(body, t)
end

"""Parse a raw CBOE JSON payload (as returned by `fetch_chain`)."""
function parse_chain(json_str::AbstractString, ticker::AbstractString="")
    data = try
        JSON.parse(json_str)
    catch e
        throw(ErrorException("could not parse CBOE JSON: $(sprint(showerror, e))"))
    end
    root = get(data, "data", data)
    spot = Float64(get(root, "current_price", NaN))
    ts_raw = get(data, "timestamp", "")
    timestamp = try
        DateTime(ts_raw, "yyyy-mm-dd HH:MM:SS")
    catch
        nothing
    end
    quotes = NamedTuple[]
    for o in get(root, "options", [])
        parsed = _parse_option_symbol(get(o, "option", ""))
        parsed === nothing && continue
        push!(quotes, (
            expiry=parsed.expiry,
            strike=parsed.strike,
            is_call=parsed.is_call,
            bid=Float64(get(o, "bid", 0.0)),
            ask=Float64(get(o, "ask", 0.0)),
            volume=Float64(get(o, "volume", 0.0)),
            open_interest=Float64(get(o, "open_interest", 0.0)),
            cboe_iv=Float64(get(o, "iv", 0.0)),
            theo=Float64(get(o, "theo", 0.0)),
        ))
    end
    return (ticker=ticker, timestamp=timestamp, spot=spot, quotes=quotes)
end

"""
    clean_chain(quotes; min_volume=25.0, min_open_interest=100.0,
                max_spread_frac=0.25)

Keep liquid, sensibly quoted rows. Drops zero or crossed markets, wide
spreads, and thinly traded contracts. Adds `mid`.
"""
function clean_chain(quotes; min_volume=25.0, min_open_interest=100.0,
                     max_spread_frac=0.25)
    out = NamedTuple[]
    for q in quotes
        (q.bid > 0 && q.ask > 0 && q.ask >= q.bid) || continue
        q.volume >= min_volume || continue
        q.open_interest >= min_open_interest || continue
        mid = (q.bid + q.ask) / 2
        (q.ask - q.bid) / mid <= max_spread_frac || continue
        push!(out, merge(q, (mid=mid,)))
    end
    return out
end

"""
    otm_quotes(quotes)

Standard smile construction: out-of-the-money puts and calls only.
For each strike keep the OTM side (puts below forward, calls above).
Needs `forward` per quote; pass `forwards` as Dict(expiry => F).
"""
function otm_quotes(quotes, forwards::Dict)
    best = Dict{Tuple{Date,Float64},NamedTuple}()
    for q in quotes
        F = get(forwards, q.expiry, nothing)
        F === nothing && continue
        otm = q.is_call ? (q.strike >= F) : (q.strike <= F)
        otm || continue
        key = (q.expiry, q.strike)
        if !haskey(best, key) || q.volume > best[key].volume
            best[key] = q
        end
    end
    return collect(values(best))
end

"""
    imply_dividend_yield(quotes, expiry, S0, r, T)

Back out the continuous dividend yield from put-call parity using mid
quotes: C - P = S e^{-qT} - K e^{-rT}. Median across strikes that have
both a call and a put. Returns NaN when no pair exists.
"""
function imply_dividend_yield(quotes, expiry::Date, S0, r, T)
    calls = Dict{Float64,Float64}()
    puts = Dict{Float64,Float64}()
    for q in quotes
        q.expiry == expiry || continue
        hasproperty(q, :mid) || continue
        if q.is_call
            calls[q.strike] = q.mid
        else
            puts[q.strike] = q.mid
        end
    end
    qs = Float64[]
    for (K, c) in calls
        haskey(puts, K) || continue
        abs(K / S0 - 1) <= 0.05 || continue  # near-ATM pairs only
        p = puts[K]
        fwd_disc = (c - p + K * exp(-r * T)) / S0
        fwd_disc > 0 || continue
        push!(qs, -log(fwd_disc) / T)
    end
    length(qs) < 3 && return NaN
    return median(qs)
end

"""Serialize a chain to JSON (for the committed offline fixture)."""
function chain_to_json(chain, path::AbstractString)
    obj = Dict(
        "ticker" => chain.ticker,
        "timestamp" => chain.timestamp === nothing ? "" :
            Dates.format(chain.timestamp, "yyyy-mm-dd HH:MM:SS"),
        "spot" => chain.spot,
        "quotes" => [Dict(
            "expiry" => Dates.format(q.expiry, "yyyy-mm-dd"),
            "strike" => q.strike,
            "is_call" => q.is_call,
            "bid" => q.bid, "ask" => q.ask,
            "volume" => q.volume, "open_interest" => q.open_interest,
            "cboe_iv" => q.cboe_iv, "theo" => q.theo,
        ) for q in chain.quotes],
    )
    open(path, "w") do io
        JSON.print(io, obj)
    end
    return path
end

"""Load a chain previously saved with `chain_to_json`.

Accepts a single JSON file or a directory of per-expiry JSON files
(the committed snapshot is split this way to keep each file small).
Directory parts are merged in sorted filename order."""
function chain_from_json(path::AbstractString)
    files = isdir(path) ?
        [joinpath(path, f) for f in sort(filter(f -> endswith(f, ".json"),
                                                readdir(path)))] : [path]
    isempty(files) && error("no JSON fixture found at $path")
    ticker, ts, spot, quotes = "", nothing, 0.0, []
    for (i, f) in enumerate(files)
        obj = JSON.parsefile(f)
        tsi = isempty(obj["timestamp"]) ? nothing :
            DateTime(obj["timestamp"], "yyyy-mm-dd HH:MM:SS")
        qs = [(
            expiry=Date(q["expiry"], "yyyy-mm-dd"),
            strike=Float64(q["strike"]),
            is_call=Bool(q["is_call"]),
            bid=Float64(q["bid"]), ask=Float64(q["ask"]),
            volume=Float64(q["volume"]), open_interest=Float64(q["open_interest"]),
            cboe_iv=Float64(q["cboe_iv"]), theo=Float64(q["theo"]),
        ) for q in obj["quotes"]]
        if i == 1
            ticker, ts, spot = obj["ticker"], tsi, Float64(obj["spot"])
        end
        append!(quotes, qs)
    end
    return (ticker=ticker, timestamp=ts, spot=spot, quotes=quotes)
end
