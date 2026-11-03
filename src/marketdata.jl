"""
Published auction records: loading, validation and model pricing.

One validated loader reads a sourced auction record (a JSON file)
and hands every consumer the same instruments: series and ISIN
identifiers, actual issue and maturity dates, amounts, and the
published profit rates. The auction date is stored on the record as
the observation time, separate from the instrument dates, and no
maturity is ever derived from a tenor label.

Rates are priced under a single explicitly named convention,
`:simple_act_365`: a published profit rate is treated as a simple
annualized discount rate on an Actual/365 basis, so the model price
per 100 face is `100 / (1 + r * T)` with `T` the Actual/365 year
fraction from the issue date to the maturity date. The rates are
published without clearing prices, so no clearing price is recorded
anywhere in the record; the model price is a documented modeling
choice, not a market quote.
"""

using Dates

const AUCTION_CONVENTIONS = (:simple_act_365,)

"""
    AuctionSource(name, url, published, retrieved)

One provenance entry for an auction record: where the data was
published, and when it was retrieved. `published` may be `nothing`
for a living reference page.
"""
struct AuctionSource
    name::String
    url::String
    published::Union{Date,Nothing}
    retrieved::Date
end

"""
    AuctionInstrument(...)

One sukuk series from an auction record, reconstructed from its
published terms: identifiers, actual issue and maturity dates,
tenor label, published profit rate, amount, and the verbatim quote
the rate was taken from. `convention` names the rate-to-price
convention the series is priced under.
"""
struct AuctionInstrument
    series::String
    isin::String
    issuer::String
    currency::String
    tenor_label::String
    tenor_months::Int
    issue_date::Date
    maturity_date::Date
    profit_rate::Float64
    amount_usd_m::Float64
    quote_text::String
    quote_source::String
    convention::Symbol
end

"""
    AuctionRecord(...)

A whole auction: issuer, currency, the shared rate convention, the
auction (observation) date, and the reconstructed instruments with
their sources.
"""
struct AuctionRecord
    issuer::String
    auction::String
    auction_date::Date
    reported::String
    currency::String
    convention::Symbol
    convention_note::String
    sources::Vector{AuctionSource}
    instruments::Vector{AuctionInstrument}
end

# ---------------------------------------------------------------------------
# Minimal strict JSON reader.
#
# The package deliberately carries no JSON dependency: the notebook
# includes this source directly under a minimal project, and the
# demo and test environments stay stdlib-only. The reader covers the
# full JSON data model and rejects malformed input, duplicate object
# keys and trailing characters, always with ArgumentError.
# ---------------------------------------------------------------------------

mutable struct _JsonParser
    chars::Vector{Char}
    pos::Int
end

function _json_parse(text::AbstractString)
    p = _JsonParser(collect(text), 1)
    _json_skip_ws(p)
    value = _json_value(p)
    _json_skip_ws(p)
    p.pos <= length(p.chars) &&
        throw(ArgumentError("JSON: trailing characters after the top-level value"))
    return value
end

function _json_skip_ws(p::_JsonParser)
    while p.pos <= length(p.chars) && p.chars[p.pos] in (' ', '\t', '\n', '\r')
        p.pos += 1
    end
    return p
end

function _json_peek(p::_JsonParser)
    p.pos <= length(p.chars) ||
        throw(ArgumentError("JSON: unexpected end of input"))
    return p.chars[p.pos]
end

function _json_value(p::_JsonParser)
    c = _json_peek(p)
    if c == '{'
        return _json_object(p)
    elseif c == '['
        return _json_array(p)
    elseif c == '"'
        return _json_string(p)
    elseif c == 't'
        _json_literal(p, "true")
        return true
    elseif c == 'f'
        _json_literal(p, "false")
        return false
    elseif c == 'n'
        _json_literal(p, "null")
        return nothing
    else
        return _json_number(p)
    end
end

function _json_literal(p::_JsonParser, word::String)
    for c in word
        _json_peek(p) == c ||
            throw(ArgumentError("JSON: invalid literal, expected \"$word\""))
        p.pos += 1
    end
    return nothing
end

function _json_object(p::_JsonParser)
    p.pos += 1  # consume '{'
    obj = Dict{String,Any}()
    _json_skip_ws(p)
    if _json_peek(p) == '}'
        p.pos += 1
        return obj
    end
    while true
        _json_skip_ws(p)
        _json_peek(p) == '"' ||
            throw(ArgumentError("JSON: object keys must be strings"))
        key = _json_string(p)
        haskey(obj, key) &&
            throw(ArgumentError("JSON: duplicate object key \"$key\""))
        _json_skip_ws(p)
        _json_peek(p) == ':' ||
            throw(ArgumentError("JSON: expected ':' after object key"))
        p.pos += 1
        _json_skip_ws(p)
        obj[key] = _json_value(p)
        _json_skip_ws(p)
        c = _json_peek(p)
        if c == ','
            p.pos += 1
        elseif c == '}'
            p.pos += 1
            return obj
        else
            throw(ArgumentError("JSON: expected ',' or '}' in object"))
        end
    end
end

function _json_array(p::_JsonParser)
    p.pos += 1  # consume '['
    arr = Any[]
    _json_skip_ws(p)
    if _json_peek(p) == ']'
        p.pos += 1
        return arr
    end
    while true
        _json_skip_ws(p)
        push!(arr, _json_value(p))
        _json_skip_ws(p)
        c = _json_peek(p)
        if c == ','
            p.pos += 1
        elseif c == ']'
            p.pos += 1
            return arr
        else
            throw(ArgumentError("JSON: expected ',' or ']' in array"))
        end
    end
end

function _json_string(p::_JsonParser)
    p.pos += 1  # consume opening quote
    io = IOBuffer()
    while true
        c = _json_peek(p)
        p.pos += 1
        if c == '"'
            return String(take!(io))
        elseif c == '\\'
            e = _json_peek(p)
            p.pos += 1
            if e == 'u'
                print(io, _json_unicode_escape(p))
            elseif e == '"'
                print(io, '"')
            elseif e == '\\'
                print(io, '\\')
            elseif e == '/'
                print(io, '/')
            elseif e == 'b'
                print(io, '\b')
            elseif e == 'f'
                print(io, '\f')
            elseif e == 'n'
                print(io, '\n')
            elseif e == 'r'
                print(io, '\r')
            elseif e == 't'
                print(io, '\t')
            else
                throw(ArgumentError("JSON: invalid escape '\\$e' in string"))
            end
        else
            print(io, c)
        end
    end
end

function _json_unicode_escape(p::_JsonParser)
    code = _json_hex4(p)
    if 0xD800 <= code <= 0xDBFF
        # High surrogate: a low surrogate must follow.
        if p.pos + 1 <= length(p.chars) && p.chars[p.pos] == '\\' &&
           p.chars[p.pos + 1] == 'u'
            p.pos += 2
            lo = _json_hex4(p)
            0xDC00 <= lo <= 0xDFFF ||
                throw(ArgumentError("JSON: invalid low surrogate in string"))
            code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
        else
            throw(ArgumentError("JSON: unpaired high surrogate in string"))
        end
    end
    return Char(code)
end

function _json_hex4(p::_JsonParser)
    value = 0
    for _ in 1:4
        c = _json_peek(p)
        p.pos += 1
        digit = c in '0':'9' ? c - '0' :
                c in 'a':'f' ? c - 'a' + 10 :
                c in 'A':'F' ? c - 'A' + 10 :
                throw(ArgumentError("JSON: invalid hex digit in \\u escape"))
        value = value * 16 + digit
    end
    return value
end

function _json_number(p::_JsonParser)
    start = p.pos
    while p.pos <= length(p.chars) &&
          (p.chars[p.pos] in '0':'9' || p.chars[p.pos] in ('-', '+', '.', 'e', 'E'))
        p.pos += 1
    end
    token = join(p.chars[start:(p.pos - 1)])
    value = tryparse(Float64, token)
    value === nothing &&
        throw(ArgumentError("JSON: invalid number \"$token\""))
    return value
end

# ---------------------------------------------------------------------------
# Record loading and strict validation.
# ---------------------------------------------------------------------------

function _req(d::Dict{String,Any}, key::AbstractString, ctx::AbstractString)
    haskey(d, key) ||
        throw(ArgumentError("$ctx: missing required field \"$key\""))
    return d[key]
end

function _req_string(d::Dict{String,Any}, key::AbstractString,
                     ctx::AbstractString)
    value = _req(d, key, ctx)
    value isa AbstractString ||
        throw(ArgumentError("$ctx: \"$key\" must be a string"))
    isempty(strip(value)) &&
        throw(ArgumentError("$ctx: \"$key\" must not be blank"))
    return String(value)
end

function _opt_string(d::Dict{String,Any}, key::AbstractString,
                     ctx::AbstractString)
    haskey(d, key) || return nothing
    value = d[key]
    value === nothing && return nothing
    value isa AbstractString ||
        throw(ArgumentError("$ctx: \"$key\" must be a string"))
    return String(value)
end

function _req_date(d::Dict{String,Any}, key::AbstractString,
                   ctx::AbstractString)
    raw = _req(d, key, ctx)
    raw isa AbstractString ||
        throw(ArgumentError("$ctx: \"$key\" must be an ISO date string"))
    isempty(strip(raw)) &&
        throw(ArgumentError("$ctx: \"$key\" is blank; an actual date is required"))
    date = tryparse(Date, raw)
    date === nothing &&
        throw(ArgumentError("$ctx: \"$key\" is not a valid ISO date: \"$raw\""))
    return date
end

function _opt_date(d::Dict{String,Any}, key::AbstractString,
                   ctx::AbstractString)
    raw = _opt_string(d, key, ctx)
    raw === nothing && return nothing
    date = tryparse(Date, raw)
    date === nothing &&
        throw(ArgumentError("$ctx: \"$key\" is not a valid ISO date: \"$raw\""))
    return date
end

function _req_number(d::Dict{String,Any}, key::AbstractString,
                     ctx::AbstractString)
    value = _req(d, key, ctx)
    value isa Real ||
        throw(ArgumentError("$ctx: \"$key\" must be a number"))
    return Float64(value)
end

"""
    load_auction_record(path) -> AuctionRecord

Load and validate a sourced auction record from its JSON file.
Validation is strict and every failure is an `ArgumentError`:
missing or blank issue/maturity dates, an unknown rate-to-price
convention, an instrument carrying a different issuer or currency
than the record, duplicate series or ISINs, rates outside (0, 1),
non-positive amounts, and instruments maturing at or before their
issue date are all rejected.
"""
function load_auction_record(path::AbstractString)
    isfile(path) ||
        throw(ArgumentError("auction record not found: $path"))
    parsed = _json_parse(read(path, String))
    parsed isa Dict{String,Any} ||
        throw(ArgumentError("auction record: top level must be a JSON object"))
    ctx = "auction record"

    issuer = _req_string(parsed, "issuer", ctx)
    currency = _req_string(parsed, "currency", ctx)
    convention_name = _req_string(parsed, "rate_convention", ctx)
    convention = Symbol(convention_name)
    convention in AUCTION_CONVENTIONS ||
        throw(ArgumentError("$ctx: unknown rate convention \"$convention_name\""))
    auction_date = _req_date(parsed, "auction_date", ctx)
    auction = _req_string(parsed, "auction", ctx)
    reported = _req_string(parsed, "reported", ctx)
    convention_note = _req_string(parsed, "rate_convention_note", ctx)

    raw_sources = _req(parsed, "sources", ctx)
    raw_sources isa Vector ||
        throw(ArgumentError("$ctx: \"sources\" must be an array"))
    isempty(raw_sources) &&
        throw(ArgumentError("$ctx: \"sources\" must not be empty"))
    sources = AuctionSource[]
    for (k, raw) in enumerate(raw_sources)
        raw isa Dict{String,Any} ||
            throw(ArgumentError("$ctx: source $k must be an object"))
        sctx = "$ctx source $k"
        push!(sources, AuctionSource(_req_string(raw, "name", sctx),
                                     _req_string(raw, "url", sctx),
                                     _opt_date(raw, "published", sctx),
                                     _req_date(raw, "retrieved", sctx)))
    end

    raw_instruments = _req(parsed, "instruments", ctx)
    raw_instruments isa Vector ||
        throw(ArgumentError("$ctx: \"instruments\" must be an array"))
    isempty(raw_instruments) &&
        throw(ArgumentError("$ctx: \"instruments\" must not be empty"))
    instruments = AuctionInstrument[]
    for (k, raw) in enumerate(raw_instruments)
        raw isa Dict{String,Any} ||
            throw(ArgumentError("$ctx: instrument $k must be an object"))
        series = _req_string(raw, "series", "$ctx instrument $k")
        ictx = "$ctx series $series"
        inst_issuer = something(_opt_string(raw, "issuer", ictx), issuer)
        inst_issuer == issuer || throw(ArgumentError(
            "$ictx: issuer \"$inst_issuer\" differs from the record issuer \"$issuer\""))
        inst_currency = something(_opt_string(raw, "currency", ictx), currency)
        inst_currency == currency || throw(ArgumentError(
            "$ictx: currency \"$inst_currency\" differs from the record currency \"$currency\""))
        issue_date = _req_date(raw, "issue_date", ictx)
        maturity_date = _req_date(raw, "maturity_date", ictx)
        maturity_date > issue_date || throw(ArgumentError(
            "$ictx: maturity $maturity_date is not after issue $issue_date"))
        rate = _req_number(raw, "profit_rate", ictx)
        0 < rate < 1 || throw(ArgumentError(
            "$ictx: profit_rate $rate is outside (0, 1)"))
        amount = _req_number(raw, "amount_usd_m", ictx)
        amount > 0 || throw(ArgumentError(
            "$ictx: amount_usd_m must be positive"))
        months_value = _req_number(raw, "tenor_months", ictx)
        isinteger(months_value) && months_value > 0 || throw(ArgumentError(
            "$ictx: tenor_months must be a positive integer"))
        push!(instruments, AuctionInstrument(
            series,
            _req_string(raw, "isin", ictx),
            inst_issuer,
            inst_currency,
            _req_string(raw, "tenor_label", ictx),
            Int(months_value),
            issue_date,
            maturity_date,
            rate,
            amount,
            _req_string(raw, "quote", ictx),
            _req_string(raw, "quote_source", ictx),
            convention))
    end
    length(unique(i.series for i in instruments)) == length(instruments) ||
        throw(ArgumentError("$ctx: duplicate series identifiers"))
    length(unique(i.isin for i in instruments)) == length(instruments) ||
        throw(ArgumentError("$ctx: duplicate ISINs"))

    return AuctionRecord(issuer, auction, auction_date, reported, currency,
                         convention, convention_note, sources, instruments)
end

# ---------------------------------------------------------------------------
# Model pricing and curve construction from a record.
# ---------------------------------------------------------------------------

"""
    model_price(instrument; face=100.0)

Model price of one auction instrument under its designated
rate-to-price convention, per `face` (default 100). Under
`:simple_act_365` this is `face / (1 + r * T)` with `T` the
Actual/365 year fraction from the instrument's issue date to its
maturity date. It is a model value under a documented convention,
never a recorded market clearing price.
"""
function model_price(inst::AuctionInstrument; face::Real=100.0)
    face > 0 || throw(ArgumentError("face must be positive"))
    if inst.convention === :simple_act_365
        T = yearfrac(inst.issue_date, inst.maturity_date, :actual_365)
        return float(face) / (1 + inst.profit_rate * T)
    end
    throw(ArgumentError("unknown rate convention: $(inst.convention)"))
end

"""
    auction_anchor(record) -> Date

The curve anchor for a record: the issue date shared by every
instrument. Curve construction needs one shared issue date because
the model prices are defined from it; a record whose instruments
were issued on different dates is rejected here.
"""
function auction_anchor(record::AuctionRecord)
    dates = unique(i.issue_date for i in record.instruments)
    length(dates) == 1 || throw(ArgumentError(
        "auction curve needs one shared issue date; this record has $(length(dates))"))
    return dates[1]
end

"""
    auction_instruments(record; face=100.0)

Bootstrap input for a record: one `(cashflows, price)` pair per
series, a single cash flow of `face` at the actual maturity date
priced by `model_price` under the record's convention.
"""
function auction_instruments(record::AuctionRecord; face::Real=100.0)
    return Tuple{Vector{CashFlow},Float64}[
        ([CashFlow(i.maturity_date, float(face))], model_price(i; face=face))
        for i in record.instruments]
end

"""
    auction_curve(record; face=100.0) -> ZeroCurve

Bootstrap the zero curve for a record, anchored on the shared
issue date (`auction_anchor`).
"""
function auction_curve(record::AuctionRecord; face::Real=100.0)
    return bootstrap(auction_instruments(record; face=face),
                     auction_anchor(record))
end

"""
    pricing_residuals(record; face=100.0)

Per-series repricing check: the model price under the designated
convention against the price recovered by discounting the series'
cash flow on the bootstrapped curve. Each row carries the series
identifiers, its published terms, both prices and the absolute
residual per `face`.
"""
function pricing_residuals(record::AuctionRecord; face::Real=100.0)
    curve = auction_curve(record; face=face)
    rows = NamedTuple[]
    for (inst, (cfs, price)) in zip(record.instruments,
                                    auction_instruments(record; face=face))
        curve_price = sum(cf.amount * discount(curve, cf.date) for cf in cfs)
        push!(rows, (series=inst.series,
                     isin=inst.isin,
                     tenor_label=inst.tenor_label,
                     profit_rate=inst.profit_rate,
                     amount_usd_m=inst.amount_usd_m,
                     issue_date=inst.issue_date,
                     maturity_date=inst.maturity_date,
                     year_fraction=yearfrac(inst.issue_date,
                                            inst.maturity_date, :actual_365),
                     model_price=price,
                     curve_price=curve_price,
                     abs_residual=abs(curve_price - price)))
    end
    return rows
end
