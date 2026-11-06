"""
Yield and risk analytics for profit-rate instruments.

All measures are computed from an explicit cash-flow schedule, so
they apply to any structure in `cashflows.jl`: bullet ijara and
wakala sukuk, installment murabaha, or anything else that produces
dated cash flows. Yields are nominal annual rates compounded `m`
times per year, the market convention for quoted sukuk yields.
"""

using Dates
using LinearAlgebra

"""
    price_from_cashflows(cfs, y, anchor; m=2)

Present value of `cfs` at nominal annual yield `y` compounded `m`
times. Times are measured from `anchor` with Actual/365.

This present value is the **full price** (dirty price) of the
remaining cash flows as of `anchor`: it includes the profit accrued
since the previous distribution, which the buyer compensates the
seller for. It is not the clean price; see `price_decomposition`.
"""
function price_from_cashflows(cfs::Vector{CashFlow}, y::Real, anchor::Date;
                              m::Int=2)
    m < 1 && throw(ArgumentError("m must be a positive integer"))
    yp = float(y) / m
    pv = 0.0
    for cf in cfs
        t = yearfrac(anchor, cf.date, :actual_365)
        t < 0 && throw(ArgumentError("cash flow before anchor"))
        pv += cf.amount / (1 + yp)^(m * t)
    end
    return pv
end

"""
    ytm_from_price(cfs, price, anchor; m=2)

Nominal annual yield implied by `price`, by bisection. `price` is
the full price of `cfs` as of `anchor` (see
`price_from_cashflows`). Returns NaN when the price lies outside
the attainable range.
"""
function ytm_from_price(cfs::Vector{CashFlow}, price::Real, anchor::Date;
                        m::Int=2)
    price = float(price)
    price <= 0 && return NaN
    f(y) = price_from_cashflows(cfs, y, anchor; m=m) - price
    lo, hi = -0.99, 5.0
    flo, fhi = f(lo), f(hi)
    (flo < 0) == (fhi < 0) && return NaN
    for _ in 1:200
        mid = (lo + hi) / 2
        fmid = f(mid)
        (fmid < 0) == (flo < 0) ? (lo = mid; flo = fmid) : (hi = mid)
        hi - lo < 1e-12 && break
    end
    return (lo + hi) / 2
end

"""
    PriceDecomposition(full_price, accrued, clean_price)

A settlement price split into its three distinct quantities: the
`full_price` (the present value of the remaining cash flows, what
the buyer pays in total), the `accrued` profit since the previous
distribution (the part of the full price that compensates the
seller), and the `clean_price`, the quoted price, defined as
`full_price - accrued`. The three reconcile exactly:
`clean_price + accrued == full_price`.
"""
struct PriceDecomposition
    full_price::Float64
    accrued::Float64
    clean_price::Float64
end

"""
    price_decomposition(terms, y, settlement; daycount=:thirty_360)

Decompose the price of `terms` at nominal annual yield `y` for a
settlement date into full price, accrued profit and clean price.
The full price discounts the cash flows remaining after
`settlement` at `y`, compounded `terms.freq` times per year;
accrued is `accrued_profit(terms, settlement)`. On the issue date
or a distribution date the accrued part is zero and the clean price
equals the full price.
"""
function price_decomposition(terms::SukukTerms, y::Real, settlement::Date;
                             daycount=:thirty_360)
    settlement < terms.issue &&
        throw(ArgumentError("settlement must not precede issue"))
    cfs = remaining_cashflows(payment_schedule(terms), settlement)
    full = price_from_cashflows(cfs, y, settlement; m=terms.freq)
    accrued = settlement == terms.issue ? 0.0 :
              accrued_profit(terms, settlement; daycount=daycount)
    return PriceDecomposition(full, accrued, full - accrued)
end

"""
    ytm_from_clean_price(terms, clean_price, settlement; daycount=:thirty_360)

Nominal annual yield implied by a quoted clean price: the accrued
profit at `settlement` is added back to give the full price, which
is then inverted with `ytm_from_price`. Returns NaN when the implied
full price lies outside the attainable range.
"""
function ytm_from_clean_price(terms::SukukTerms, clean_price::Real,
                              settlement::Date; daycount=:thirty_360)
    settlement < terms.issue &&
        throw(ArgumentError("settlement must not precede issue"))
    cfs = remaining_cashflows(payment_schedule(terms), settlement)
    accrued = settlement == terms.issue ? 0.0 :
              accrued_profit(terms, settlement; daycount=daycount)
    return ytm_from_price(cfs, float(clean_price) + accrued, settlement;
                          m=terms.freq)
end

"""
    current_yield(annual_distribution, price)

Annual distributions divided by price. A running snapshot, not a
maturity measure.
"""
function current_yield(annual_distribution::Real, price::Real)
    annual_distribution = float(annual_distribution)
    price = float(price)
    price <= 0 && throw(ArgumentError("price must be positive"))
    return annual_distribution / price
end

"""
    macaulay_duration(cfs, y, anchor; m=2)

Present-value-weighted average time to receipt, in years.
"""
function macaulay_duration(cfs::Vector{CashFlow}, y::Real, anchor::Date;
                           m::Int=2)
    p = price_from_cashflows(cfs, y, anchor; m=m)
    p <= 0 && throw(ArgumentError("non-positive present value"))
    yp = float(y) / m
    weighted = 0.0
    for cf in cfs
        t = yearfrac(anchor, cf.date, :actual_365)
        weighted += t * cf.amount / (1 + yp)^(m * t)
    end
    return weighted / p
end

"""
    modified_duration(cfs, y, anchor; m=2)

Price sensitivity: the fractional price change per unit change in
yield. Equals Macaulay duration divided by `(1 + y/m)`.
"""
function modified_duration(cfs::Vector{CashFlow}, y::Real, anchor::Date;
                           m::Int=2)
    return macaulay_duration(cfs, y, anchor; m=m) / (1 + float(y) / m)
end

"""
    convexity(cfs, y, anchor; m=2)

Second-order price sensitivity to yield changes, in years squared.
Positive for standard bullet structures: the duration
approximation understates price gains and overstates losses.
"""
function convexity(cfs::Vector{CashFlow}, y::Real, anchor::Date; m::Int=2)
    p = price_from_cashflows(cfs, y, anchor; m=m)
    p <= 0 && throw(ArgumentError("non-positive present value"))
    yp = float(y) / m
    acc = 0.0
    for cf in cfs
        t = yearfrac(anchor, cf.date, :actual_365)
        acc += t * (t + 1 / m) * cf.amount / (1 + yp)^(m * t)
    end
    return acc / (p * (1 + yp)^2)
end

"""
    dv01(cfs, y, anchor; m=2)

Absolute price change for a one basis point rise in yield.
"""
function dv01(cfs::Vector{CashFlow}, y::Real, anchor::Date; m::Int=2)
    p = price_from_cashflows(cfs, y, anchor; m=m)
    return modified_duration(cfs, y, anchor; m=m) * p * 1e-4
end

"""
    price_under_shift(cfs, y, bps, anchor; m=2)

Reprice the cash flows after a parallel shift of `bps` basis points
in the yield.
"""
function price_under_shift(cfs::Vector{CashFlow}, y::Real, bps::Real,
                           anchor::Date; m::Int=2)
    return price_from_cashflows(cfs, float(y) + float(bps) / 1e4, anchor; m=m)
end

# ---------------------------------------------------------------------------
# Settlement-aware pricing.
#
# A valuation needs three things stated together: when it happens
# (the settlement date), how accrued profit is counted (the day
# count), and what the discounting basis is. The basis is a type,
# not a bare number, because the same number means different things
# under different conventions: a nominal annual yield compounded
# `m` times per year is not a continuously compounded curve rate,
# and the two must never be silently swapped.
# ---------------------------------------------------------------------------

"""
    NominalYield(rate, m)

A nominal annual yield compounded `m` times per year: the market
convention for quoted sukuk yields. `rate` is the annual rate as a
decimal, `m` the compounding frequency (a positive integer).
Distinct from a `ZeroCurve`, whose rates are continuously
compounded: `NominalYield(0.05, 2)` and a flat 5% curve price the
same cash flows differently, and the type system keeps them apart.
"""
struct NominalYield
    rate::Float64
    m::Int

    function NominalYield(rate::Real, m::Int)
        m < 1 && throw(ArgumentError("m must be a positive integer"))
        isfinite(rate) ||
            throw(ArgumentError("nominal yield must be finite"))
        return new(float(rate), m)
    end
end

"""
    ValuationContext(settlement, basis; daycount=:thirty_360)

One typed valuation context: the `settlement` date, the `daycount`
used for accrued profit, and the pricing `basis`, either a
`NominalYield` or a `ZeroCurve`. A bare number is not a basis and
is rejected, so the compounding convention is always explicit.
Cash flows dated on or before the settlement date are settled and
never priced: the buyer receives only the flows after settlement.
"""
struct ValuationContext{B}
    settlement::Date
    daycount::DayCount
    basis::B
end

function ValuationContext(settlement::Date, basis::NominalYield;
                          daycount::Union{Symbol,DayCount}=:thirty_360)
    dc = daycount isa DayCount ? daycount : DayCount(daycount)
    return ValuationContext{NominalYield}(settlement, dc, basis)
end

function ValuationContext(settlement::Date, curve::ZeroCurve;
                          daycount::Union{Symbol,DayCount}=:thirty_360)
    dc = daycount isa DayCount ? daycount : DayCount(daycount)
    return ValuationContext{ZeroCurve}(settlement, dc, curve)
end

"""
    price_from_curve(cfs, curve)

Present value of `cfs` on a `ZeroCurve`, as of the curve anchor:
each cash flow discounted by its discount factor. Cash flows
before the anchor are rejected. This is the full price at the
anchor; for value at a later settlement date, see `price`, which
rescales by the discount factor to settlement.
"""
function price_from_curve(cfs::Vector{CashFlow}, curve::ZeroCurve)
    return sum(cf.amount * discount(curve, cf.date) for cf in cfs;
               init=0.0)
end

# Value at settlement of flows dated after it, on a curve anchored
# at or before the settlement date. Dividing by the discount factor
# to settlement moves the anchor value to the settlement date; when
# the curve anchors on the settlement date the factor is exactly 1.
function _curve_price_at(cfs::Vector{CashFlow}, curve::ZeroCurve,
                         settlement::Date)
    remaining = [cf for cf in cfs if cf.date > settlement]
    df_settle = discount(curve, settlement)
    return sum(cf.amount * discount(curve, cf.date) for cf in remaining;
               init=0.0) / df_settle
end

"""
    price(ctx, cfs) / price(ctx, terms)

Full (dirty) price of the cash flows under the valuation context
`ctx`: the present value, at the settlement date, of the flows
dated after settlement. Settled flows are excluded. With a
`NominalYield` basis the flows are discounted at the nominal yield
compounded `basis.m` times per year; with a `ZeroCurve` basis they
are discounted on the curve and rescaled to the settlement date.
With terms, the price is the full price from
`price_decomposition(ctx, terms)`.
"""
function price(ctx::ValuationContext{NominalYield},
               cfs::Vector{CashFlow})
    remaining = remaining_cashflows(cfs, ctx.settlement)
    return price_from_cashflows(remaining, ctx.basis.rate, ctx.settlement;
                                m=ctx.basis.m)
end

function price(ctx::ValuationContext{ZeroCurve}, cfs::Vector{CashFlow})
    return _curve_price_at(cfs, ctx.basis, ctx.settlement)
end

function price(ctx::ValuationContext, terms::SukukTerms)
    return price_decomposition(ctx, terms).full_price
end

"""
    price_decomposition(ctx, terms)

Decompose the price of `terms` under the valuation context `ctx`
into full price, accrued profit and clean price. The full price
discounts the cash flows remaining after settlement on the
context basis; accrued is `accrued_profit` at settlement under
the context day count. On the issue date or a distribution date
the accrued part is zero and the clean price equals the full
price. The three reconcile exactly: clean plus accrued equals the
full price.
"""
function price_decomposition(ctx::ValuationContext, terms::SukukTerms)
    ctx.settlement < terms.issue &&
        throw(ArgumentError("settlement must not precede issue"))
    cfs = remaining_cashflows(payment_schedule(terms), ctx.settlement)
    full = price(ctx, cfs)
    accrued = ctx.settlement == terms.issue ? 0.0 :
              accrued_profit(terms, ctx.settlement; daycount=ctx.daycount)
    return PriceDecomposition(full, accrued, full - accrued)
end

"""
    key_rate_dv01(ctx, terms, i; bump_bps=1.0)

Key-rate DV01 of `terms` at pillar `i` of the context curve: the
fall in the settlement full price, per one basis point rise in
that pillar's zero rate, holding the other pillars fixed. Positive
when the price falls as the pillar rises, which is the usual case
for a pillar that discounts the remaining flows. It can be
negative for a pillar that moves only the settlement discount
factor: the curve anchors before settlement, so raising such a
pillar lowers the factor to settlement and raises the settlement
price while the flows are untouched. A pillar that touches
neither the flows nor the settlement factor leaves the price
exactly unchanged.
"""
function key_rate_dv01(ctx::ValuationContext{ZeroCurve}, terms::SukukTerms,
                       i::Int; bump_bps::Real=1.0)
    bump_bps == 0 && throw(ArgumentError("bump_bps must be nonzero"))
    base = price(ctx, terms)
    bumped = ValuationContext(ctx.settlement,
                              bump_pillar(ctx.basis, i, bump_bps);
                              daycount=ctx.daycount)
    return (base - price(bumped, terms)) / float(bump_bps)
end

"""
    key_rate_dv01s(ctx, terms; bump_bps=1.0)

Key-rate DV01 at every pillar of the context curve, in pillar
order. The entries sum to `curve_dv01` up to second-order cross
terms between pillars.
"""
function key_rate_dv01s(ctx::ValuationContext{ZeroCurve},
                        terms::SukukTerms; bump_bps::Real=1.0)
    return [key_rate_dv01(ctx, terms, i; bump_bps=bump_bps)
            for i in eachindex(ctx.basis.pillars)]
end

"""
    curve_dv01(ctx, terms; bump_bps=1.0)

Parallel curve DV01 of `terms`: the fall in the settlement full
price, per one basis point rise in every pillar of the context
curve at once. The sum of the key-rate DV01s agrees with this up
to second-order cross terms between pillars.
"""
function curve_dv01(ctx::ValuationContext{ZeroCurve}, terms::SukukTerms;
                    bump_bps::Real=1.0)
    bump_bps == 0 && throw(ArgumentError("bump_bps must be nonzero"))
    curve = ctx.basis
    bumped = ZeroCurve(curve.anchor, copy(curve.pillars),
                       curve.zeros .+ float(bump_bps) / 1e4)
    base = price(ctx, terms)
    moved = price(ValuationContext(ctx.settlement, bumped;
                                   daycount=ctx.daycount), terms)
    return (base - moved) / float(bump_bps)
end

# ---------------------------------------------------------------------------
# Batched curve pricing and numerical benchmarks.
#
# Pricing one instrument at a time rebuilds its schedule, filters the
# remaining flows and recomputes every year fraction on each call. For
# a portfolio that work is repeated per instrument even though the
# curve and settlement are shared. A PricedBatch prepares every
# schedule once, as flat year fractions and amounts, and prices the
# whole portfolio into a preallocated vector with a reused discount
# buffer, so the hot loop allocates nothing.
# ---------------------------------------------------------------------------

"""
    PricedBatch(times, amounts, offsets, discounts, prices, settle_t, settlement)

A portfolio prepared for batched curve pricing. `times` and
`amounts` hold every remaining cash flow of every instrument in one
flat layout, `offsets[i]` is the first flat index of instrument `i`
(with `offsets[end]` one past the last flow), `discounts` is a
scratch buffer reused on every pricing pass, `prices` holds one
price per instrument, and `settle_t` is the settlement year fraction
from the curve anchor. Build one with `prepare_batch`; never
construct it by hand.
"""
struct PricedBatch
    times::Vector{Float64}
    amounts::Vector{Float64}
    offsets::Vector{Int}
    discounts::Vector{Float64}
    prices::Vector{Float64}
    settle_t::Float64
    settlement::Date
end

"""
    prepare_batch(terms, settlement, curve)

Prepare `terms` for batched pricing on `curve` at `settlement`:
build each instrument's remaining schedule once and lay the cash
flows out flat, with a preallocated discount buffer and price
vector. The curve anchor must not be after settlement, and
settlement must not precede any instrument's issue date. An
instrument with no flows after settlement prices at zero.
"""
function prepare_batch(terms::Vector{SukukTerms}, settlement::Date,
                       curve::ZeroCurve)
    isempty(terms) && throw(ArgumentError("terms must not be empty"))
    curve.anchor > settlement &&
        throw(ArgumentError("curve anchor must not be after settlement"))
    for t in terms
        settlement < t.issue &&
            throw(ArgumentError("settlement must not precede issue"))
    end
    times = Float64[]
    amounts = Float64[]
    offsets = Int[1]
    for t in terms
        for cf in remaining_cashflows(payment_schedule(t), settlement)
            push!(times, yearfrac(curve.anchor, cf.date, :actual_365))
            push!(amounts, cf.amount)
        end
        push!(offsets, length(times) + 1)
    end
    nflows = length(times)
    return PricedBatch(times, amounts, offsets,
                       Vector{Float64}(undef, nflows),
                       Vector{Float64}(undef, length(terms)),
                       yearfrac(curve.anchor, settlement, :actual_365),
                       settlement)
end

"""
    price_batch!(batch, curve)

Price every instrument in `batch` on `curve` into the batch's
preallocated price vector, reusing its discount buffer. The same
batch can be repriced on another curve without rebuilding the
schedules. Allocates nothing after warmup. Returns the price
vector.
"""
function price_batch!(batch::PricedBatch, curve::ZeroCurve)
    df_settle = discount(curve, batch.settle_t)
    @inbounds for k in eachindex(batch.times)
        batch.discounts[k] = discount(curve, batch.times[k])
    end
    @inbounds for i in eachindex(batch.prices)
        s = 0.0
        for k in batch.offsets[i]:(batch.offsets[i + 1] - 1)
            s += batch.amounts[k] * batch.discounts[k]
        end
        batch.prices[i] = s / df_settle
    end
    return batch.prices
end

"""
    price_batch(terms, settlement, curve) / price_batch(ctx, terms)

Price every instrument in `terms` on `curve` at `settlement` in one
batched pass, returning a vector with one full price per instrument
in the same order as `terms`. The `ValuationContext` form takes the
settlement date and curve from the context. Prices agree with the
per-instrument `price` path; see the SU4 testset for the
cross-check against an independent high-precision oracle.
"""
function price_batch(terms::Vector{SukukTerms}, settlement::Date,
                     curve::ZeroCurve)
    batch = prepare_batch(terms, settlement, curve)
    return price_batch!(batch, curve)
end

function price_batch(ctx::ValuationContext{ZeroCurve},
                     terms::Vector{SukukTerms})
    return price_batch(terms, ctx.settlement, ctx.basis)
end

"""
    BenchmarkRow(n_instruments, n_cashflows, repeats, allocations_bytes, seconds_per_instrument, seconds_total, baseline_allocations_bytes, baseline_seconds_per_instrument)

One row of a benchmark report: the portfolio size, the number of
cash flows priced, the repeat count, the bytes allocated by one
batched pricing pass (after warmup), the median seconds per
instrument over the repeats, the median total seconds, and the same
two figures for the baseline loop that prices each instrument
separately through the valuation context.
"""
struct BenchmarkRow
    n_instruments::Int
    n_cashflows::Int
    repeats::Int
    allocations_bytes::Int
    seconds_per_instrument::Float64
    seconds_total::Float64
    baseline_allocations_bytes::Int
    baseline_seconds_per_instrument::Float64
end

"""
    BenchmarkReport(julia_version, nthreads, blas_threads, blas_config, rows)

A benchmark report: the Julia version, thread count and BLAS
configuration the numbers were measured under, plus one
`BenchmarkRow` per portfolio size. Times are wall-clock medians
over the repeats; allocations are bytes allocated by one pricing
pass after warmup.
"""
struct BenchmarkReport
    julia_version::VersionNumber
    nthreads::Int
    blas_threads::Int
    blas_config::String
    rows::Vector{BenchmarkRow}
end

# Median of a vector of timings, computed without a Statistics
# dependency: the benchmark runner only needs this one summary.
function _benchmark_median(xs::Vector{Float64})
    s = sort(xs)
    n = length(s)
    return isodd(n) ? s[(n + 1) ÷ 2] : (s[n ÷ 2] + s[n ÷ 2 + 1]) / 2
end

# The baseline loop: price each instrument separately through the
# valuation context, which rebuilds its schedule and recomputes its
# year fractions on every call. Kept as its own function so its
# allocations are measured exactly, without closure overhead.
function _baseline_price_total(ctx::ValuationContext{ZeroCurve},
                               terms::Vector{SukukTerms})
    total = 0.0
    for t in terms
        total += price(ctx, t)
    end
    return total
end

"""
    benchmark_pricing(portfolios, settlement, curve; repeats=5)

Run the benchmark suite: for each portfolio in `portfolios` (one
vector of terms per size), warm up, then time `repeats` batched
pricing passes and the same number of baseline per-instrument
pricing loops, recording allocations and median seconds per
instrument for both. The setup (schedule preparation) is excluded
from the timed passes. Returns a `BenchmarkReport` carrying the
Julia version, thread count and BLAS configuration alongside the
rows. Timing is wall clock on the machine that runs it: compare
rows measured in the same run, not numbers from different machines.
"""
function benchmark_pricing(portfolios::Vector{Vector{SukukTerms}},
                           settlement::Date, curve::ZeroCurve;
                           repeats::Int=5)
    repeats < 1 && throw(ArgumentError("repeats must be a positive integer"))
    isempty(portfolios) && throw(ArgumentError("portfolios must not be empty"))
    ctx = ValuationContext(settlement, curve)
    rows = BenchmarkRow[]
    for terms in portfolios
        batch = prepare_batch(terms, settlement, curve)
        price_batch!(batch, curve)
        allocs = @allocated price_batch!(batch, curve)
        times = Float64[]
        for _ in 1:repeats
            t0 = time_ns()
            price_batch!(batch, curve)
            push!(times, (time_ns() - t0) / 1e9)
        end
        seconds_total = _benchmark_median(times)
        _baseline_price_total(ctx, terms)
        base_allocs = @allocated _baseline_price_total(ctx, terms)
        base_times = Float64[]
        for _ in 1:repeats
            t0 = time_ns()
            _baseline_price_total(ctx, terms)
            push!(base_times, (time_ns() - t0) / 1e9)
        end
        n = length(terms)
        push!(rows, BenchmarkRow(n, length(batch.times), repeats,
                                 allocs, seconds_total / n, seconds_total,
                                 base_allocs,
                                 _benchmark_median(base_times) / n))
    end
    return BenchmarkReport(VERSION, Base.Threads.nthreads(),
                           BLAS.get_num_threads(),
                           string(BLAS.get_config()), rows)
end

"""
    benchmark_table(report)

Render a `BenchmarkReport` as plain text: the environment line
(Julia version, threads, BLAS configuration) followed by one line
per portfolio size with allocations and seconds per instrument for
the batched pass and for the baseline loop.
"""
function benchmark_table(report::BenchmarkReport)
    lines = String[
        "Benchmark (Julia $(report.julia_version), " *
        "threads $(report.nthreads), BLAS $(report.blas_threads) " *
        "threads, $(report.blas_config)):",
        "instruments  cash flows  repeats  alloc bytes  " *
        "us/instrument  baseline us/instrument",
    ]
    for row in report.rows
        us = round(1e6 * row.seconds_per_instrument; digits=2)
        base_us = round(1e6 * row.baseline_seconds_per_instrument;
                        digits=2)
        push!(lines, "$(row.n_instruments)  $(row.n_cashflows)  " *
                     "$(row.repeats)  $(row.allocations_bytes)  " *
                     "$us  $base_us")
    end
    return join(lines, "\n")
end
