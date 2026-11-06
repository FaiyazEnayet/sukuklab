# SU4: numerical benchmark suite. Fixed reference instruments priced
# on a fixed curve, cross-checked against an independent BigFloat
# oracle that re-derives the discounting from the stated Actual/365
# and linear-zero conventions without calling the package curve code.

@testset "stage3_su4_benchmark_suite" begin
    anchor = Date(2026, 1, 15)
    settle = Date(2026, 10, 10)
    pillars = [0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 7.0, 10.0]
    zeros = [0.038, 0.037, 0.036, 0.038, 0.040, 0.042, 0.043, 0.045]
    curve = ZeroCurve(anchor, pillars, zeros)
    ctx = ValuationContext(settle, curve)

    function su4_terms(n)
        terms = SukukTerms[]
        for i in 1:n
            years = 1 + ((i - 1) % 10)
            rate = 0.03 + 0.01 * ((i - 1) % 4)
            push!(terms, SukukTerms("SU4 ref $i", 100.0, rate, anchor,
                                    anchor + Year(years), 2, "ijara"))
        end
        return terms
    end

    function su4_oracle_rate(t::BigFloat)
        t <= BigFloat(pillars[1]) && return BigFloat(zeros[1])
        t >= BigFloat(pillars[end]) && return BigFloat(zeros[end])
        for i in 1:(length(pillars) - 1)
            lo, hi = BigFloat(pillars[i]), BigFloat(pillars[i + 1])
            if lo <= t <= hi
                w = (t - lo) / (hi - lo)
                return BigFloat(zeros[i]) * (1 - w) +
                       BigFloat(zeros[i + 1]) * w
            end
        end
        throw(ArgumentError("oracle rate: t outside pillar range"))
    end

    # Independent high-precision price: calendar-day year fractions
    # and linear zero interpolation recomputed in BigFloat, with the
    # settlement rescaling applied directly. No package curve code.
    function su4_oracle_price(terms)
        cfs = remaining_cashflows(payment_schedule(terms), settle)
        t_settle = BigFloat(Dates.value(settle - anchor)) / 365
        df_settle = exp(-su4_oracle_rate(t_settle) * t_settle)
        total = BigFloat(0)
        for cf in cfs
            t = BigFloat(Dates.value(cf.date - anchor)) / 365
            total += BigFloat(cf.amount) * exp(-su4_oracle_rate(t) * t)
        end
        return Float64(total / df_settle)
    end

    sizes = [10, 100, 1000]

    @testset "oracle_cross_check" begin
        # Batched pricing must agree with the independent oracle to
        # 1e-8 per 100 face at every portfolio size, and with the
        # per-instrument SU3 context path to 1e-9.
        for n in sizes
            terms = su4_terms(n)
            got = price_batch(terms, settle, curve)
            @test length(got) == n
            worst_oracle = maximum(abs(p - su4_oracle_price(t))
                                   for (t, p) in zip(terms, got))
            @test worst_oracle <= 1e-8
            worst_ctx = maximum(abs(p - price(ctx, t))
                                for (t, p) in zip(terms, got))
            @test worst_ctx <= 1e-9
        end
    end

    @testset "preallocated_batch" begin
        terms = su4_terms(100)
        batch = prepare_batch(terms, settle, curve)
        @test length(batch.prices) == 100
        @test length(batch.offsets) == 101
        @test batch.offsets[1] == 1
        @test length(batch.times) == length(batch.amounts)
        @test length(batch.times) == length(batch.discounts)
        @test batch.offsets[end] == length(batch.times) + 1
        # Warmup, then the hot loop allocates nothing and reprices
        # identically on repeat calls.
        first = copy(price_batch!(batch, curve))
        @test @allocated(price_batch!(batch, curve)) == 0
        @test price_batch!(batch, curve) == first
        # Reusing the same batch on a higher curve reprices it lower.
        moved = ZeroCurve(anchor, pillars, zeros .+ 0.001)
        @test all(price_batch!(batch, moved) .< first)
        # Context convenience wrapper agrees with the batch path.
        @test price_batch(ctx, terms) ≈ first
        # Validation: empty portfolio, settlement before an issue,
        # and a curve anchored after settlement are all rejected.
        @test_throws ArgumentError prepare_batch(SukukTerms[], settle,
                                                 curve)
        early = SukukTerms("early", 100.0, 0.05, Date(2026, 2, 1),
                           Date(2027, 2, 1), 2, "ijara")
        @test_throws ArgumentError prepare_batch([early],
                                                 Date(2026, 1, 15), curve)
        late_curve = ZeroCurve(Date(2027, 1, 1), pillars, zeros)
        @test_throws ArgumentError prepare_batch(terms, settle,
                                                 late_curve)
    end

    @testset "benchmark_report" begin
        portfolios = [su4_terms(n) for n in sizes]
        report = benchmark_pricing(portfolios, settle, curve; repeats=5)
        @test report.julia_version == VERSION
        @test report.nthreads == Base.Threads.nthreads()
        @test report.blas_threads ==
              LinearAlgebra.BLAS.get_num_threads()
        @test length(report.rows) == 3
        for (row, n) in zip(report.rows, sizes)
            @test row.n_instruments == n
            @test row.repeats == 5
            @test row.n_cashflows > 0
            @test row.allocations_bytes == 0
            @test row.seconds_per_instrument > 0
            @test isfinite(row.seconds_per_instrument)
            @test row.baseline_allocations_bytes > 0
            @test row.allocations_bytes < row.baseline_allocations_bytes
            @test row.seconds_per_instrument <
                  row.baseline_seconds_per_instrument
        end
        @test_throws ArgumentError benchmark_pricing(portfolios, settle,
                                                     curve; repeats=0)
        @test_throws ArgumentError benchmark_pricing(
            Vector{SukukTerms}[], settle, curve)
        table = benchmark_table(report)
        @test occursin(string(VERSION), table)
        for n in sizes
            @test occursin(string(n), table)
        end
    end
end
