@testset "stage3_su7_julia_authority" begin
    # SU7: Julia is the validated analytics authority. The canonical
    # results schema (examples/results.json) is the one typed export
    # both renderers consume: examples/make_dashboard.jl renders its
    # snapshot from it, and examples/make_dashboard.py renders the
    # portfolio dashboard from it. This testset recomputes every
    # schema value live from the package and checks the schema file,
    # so either renderer drifting from the package fails here.
    # Declared tolerance: 1e-8 absolute per 1,000 face, the existing
    # valuation parity bar, applied to chart payloads as well.
    repo = joinpath(@__DIR__, "..")
    text = read(joinpath(repo, "examples", "results.json"), String)
    jstr(key) = match(Regex("\"" * key * "\":\\s*\"([^\"]*)\""),
                      text).captures[1]
    jnum(key) = parse(Float64, match(Regex("\"" * key *
                                          "\":\\s*([-0-9.eE+]+)"),
                                     text).captures[1])
    jint(key) = parse(Int, match(Regex("\"" * key * "\":\\s*([0-9]+)"),
                                 text).captures[1])
    jvec(key) = parse.(Float64,
                       split(match(Regex("\"" * key *
                                           "\":\\s*\\[([^\\]]*)\\]"),
                                     text).captures[1], ","))
    jstrvec(key) = [m.captures[1] for m in eachmatch(
        r"\"([^\"]*)\"",
        match(Regex("\"" * key * "\":\\s*\\[([^\\]]*)\\]"),
              text).captures[1])]

    # The schema is versioned, and it names the Julia environment
    # that generated it (major.minor, stable across patch releases).
    @test jstr("schema") == "sukuklab/results/1"
    @test jint("schema_version") == 1
    @test jstr("julia_version") ==
          string(VERSION.major) * "." * string(VERSION.minor)

    # Source dates come from the record itself, not from prose.
    record = load_auction_record(joinpath(repo, "data",
                                          "iilm_2026-01.json"))
    @test jstr("iilm_auction_date") == string(record.auction_date)
    @test jstrvec("iilm_source_published_dates") ==
          [string(s.published) for s in record.sources
           if s.published !== nothing]
    @test jstrvec("iilm_source_retrieved_dates") ==
          [string(s.retrieved) for s in record.sources]

    # Playground pricing (dashboard section 1), recomputed live.
    play_terms = SukukTerms("Playground sukuk", 1000.0, 0.0506,
                            Date(2026, 1, 15),
                            Date(2026, 1, 15) + Year(5), 2, "ijara")
    play_anchor = Date(2026, 1, 15)
    play_cfs = payment_schedule(play_terms)
    play_y = 0.0506
    play_p = price_from_cashflows(play_cfs, play_y, play_anchor; m=2)
    @test jnum("playground_face") == 1000.0
    @test jnum("playground_profit_rate") == 0.0506
    @test jstr("playground_issue") == "2026-01-15"
    @test jstr("playground_maturity") == "2031-01-15"
    @test jint("playground_freq") == 2
    @test jstr("playground_structure") == "ijara"
    @test jstr("playground_anchor") == "2026-01-15"
    # At the anchor (the issue date) accrued profit is zero, so the
    # full price and the clean price coincide; the dashboard labels
    # this value its clean price.
    @test isapprox(jnum("playground_clean_price"), play_p; atol=1e-8)
    @test jint("playground_n_cashflows") == length(play_cfs)
    @test isapprox(jnum("playground_ytm"),
                   ytm_from_price(play_cfs, play_p, play_anchor; m=2);
                   atol=1e-8)
    @test isapprox(jnum("playground_macaulay_duration"),
                   macaulay_duration(play_cfs, play_y, play_anchor; m=2);
                   atol=1e-8)
    @test isapprox(jnum("playground_modified_duration"),
                   modified_duration(play_cfs, play_y, play_anchor; m=2);
                   atol=1e-8)
    @test isapprox(jnum("playground_convexity"),
                   convexity(play_cfs, play_y, play_anchor; m=2);
                   atol=1e-8)
    @test isapprox(jnum("playground_dv01"),
                   dv01(play_cfs, play_y, play_anchor; m=2); atol=1e-8)

    # Cash-flow structures (dashboard section 2), recomputed live.
    @test jnum("structure_face") == 1000.0
    @test jnum("structure_profit_rate") == 0.05
    @test jstr("structure_issue") == "2026-01-15"
    @test jstr("structure_maturity") == "2029-01-15"
    @test jint("structure_freq") == 2
    for (structure, amortizing) in (("ijara", false),
                                     ("murabaha", true),
                                     ("wakala", false))
        terms = SukukTerms("$structure example", 1000.0, 0.05,
                           Date(2026, 1, 15), Date(2029, 1, 15), 2,
                           structure; amortizing=amortizing)
        cfs = payment_schedule(terms)
        @test jstrvec("structure_$(structure)_dates") ==
              [string(cf.date) for cf in cfs]
        @test all(abs.(jvec("structure_$(structure)_amounts") .-
                      [cf.amount for cf in cfs]) .<= 1e-8)
    end

    # UAE price sweep (the dashboard price chart payload), recomputed
    # live from the same remaining cash flows the shared fixture
    # carries. The Python checker independently recomputes this sweep
    # from the fixture, so the two renderers agree through the schema.
    uae = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                     Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
    settle = Date(2026, 10, 10)
    sweep_cfs = remaining_cashflows(payment_schedule(uae), settle)
    sweep_yields = [2.0 + i / 10 for i in 0:70]
    sweep_prices = [price_from_cashflows(sweep_cfs, y / 100, settle; m=2)
                    for y in sweep_yields]
    @test length(jvec("uae_price_sweep_yield_pct")) == 71
    @test length(jvec("uae_price_sweep_prices")) == 71
    @test all(abs.(jvec("uae_price_sweep_yield_pct") .- sweep_yields)
              .<= 1e-12)
    @test all(abs.(jvec("uae_price_sweep_prices") .- sweep_prices)
              .<= 1e-8)

    # The Julia renderer consumes the schema: it reads the results
    # file and computes no analytics inline any more. Every number it
    # prints comes from the export above.
    script = read(joinpath(repo, "examples", "make_dashboard.jl"), String)
    @test occursin("results.json", script)
    for fn in ("price_from_cashflows(", "payment_schedule(",
               "bootstrap(", "ytm_from_price(", "macaulay_duration(",
               "modified_duration(", "convexity(", "dv01(",
               "forward_rate(", "load_auction_record(",
               "auction_instruments(", "auction_anchor(")
        @test !occursin(fn, script)
    end

    # No compliance certification language in the schema or in either
    # generator. (The dashboard template footer carries the standing
    # disclaimer that contract analysis does not establish legal or
    # Sharia compliance; that disclaimer is not a certification.)
    @test !occursin(r"certif"i, text)
    @test !occursin(r"certif"i, script)
    py = read(joinpath(repo, "examples", "make_dashboard.py"), String)
    @test !occursin(r"certif"i, py)
end
