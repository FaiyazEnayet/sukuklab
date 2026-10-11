# Real market data demo: SPY option chain from CBOE (free, ~15 min delayed).
#
#   julia --project=. examples/demo_real.jl          # committed fixture, offline
#   julia --project=. examples/demo_real.jl --live   # refetch from CBOE
#
# Pipeline: fetch -> clean -> implied dividend yields from put-call parity
# -> OTM smiles -> SVI surface fit -> per-expiry Heston calibration ->
# BAW early-exercise diagnostic.

using Volkit
using Dates
using Printf
using Statistics

const RISK_FREE = 0.04  # assumption; short rates move, set your own

is_monthly(d::Date) = dayofweek(d) == 5 && 15 <= dayofmonth(d) <= 21

function main()
    live = "--live" in ARGS
    datadir = joinpath(@__DIR__, "..", "data")
    if live
        chain = fetch_chain("SPY")
        mkpath(datadir)
        tag = Dates.format(Date(chain.timestamp), "yyyy-mm-dd")
        path = joinpath(datadir, "spy_chain_$tag.json")
        chain_to_json(chain, path)
        println("saved fixture: $path")
    else
        names = filter(f -> startswith(f, "spy_chain_") && endswith(f, ".json"),
                         readdir(datadir))
        isempty(names) && error("no fixture in data/; run once with --live")
        path = joinpath(datadir, last(sort(names)))
        println("using fixture: $path (offline)")
        chain = chain_from_json(path)
    end

    S0 = chain.spot
    asof = Date(chain.timestamp)
    println("SPY spot: $S0 | data as of: $asof | r = $RISK_FREE (assumed)")

    clean = clean_chain(chain.quotes)
    println("quotes: $(length(chain.quotes)) raw -> $(length(clean)) after cleaning")

    # three nearest monthly expiries with enough liquid quotes
    exps = sort(unique(q.expiry for q in clean))
    monthlies = filter(e -> is_monthly(e) &&
        count(q -> q.expiry == e, clean) >= 12, exps)
    chosen = monthlies[1:min(3, length(monthlies))]
    println("expiries: $chosen")

    Ts, qs, Fs = Float64[], Float64[], Float64[]
    smiles = []
    for e in chosen
        T = (e - asof).value / 365
        q = imply_dividend_yield(clean, e, S0, RISK_FREE, T)
        q = isnan(q) ? 0.0 : max(q, 0.0)
        F = S0 * exp((RISK_FREE - q) * T)
        otm = otm_quotes(clean, Dict(e => F))
        ivs = [implied_vol(x.mid, S0, x.strike, T, RISK_FREE; q=q,
                           kind=x.is_call ? :call : :put) for x in otm]
        keep = .!isnan.(ivs)
        push!(Ts, T); push!(qs, q); push!(Fs, F)
        push!(smiles, (strikes=[x.strike for x in otm][keep],
                       vols=ivs[keep]))
        println("  $e  T=$(round(T; digits=4))  q_impl=$(round(q; digits=4))  " *
                "F=$(round(F; digits=1))  n_otm=$(sum(keep))")
    end

    # SVI surface (per-expiry q, same forwards as the IV extraction above)
    println("\nSVI surface fit:")
    params_list, sinfo = fit_surface(
        [s.strikes for s in smiles], [s.vols for s in smiles],
        Ts, S0, RISK_FREE; q=qs, n_restarts=4, seed=0)
    for (i, e) in enumerate(chosen)
        si = sinfo.slice_infos[i]
        println("  $e  vol RMSE=$(round(si.rmse_vol; digits=5))  " *
                "butterfly_ok=$(si.butterfly_ok)")
    end
    println("  calendar_ok=$(sinfo.calendar_ok)")

    # Heston per expiry (subsampled strikes: the smile is smooth and the
    # Fourier pricer is expensive; 25 points capture it fully)
    println("\nHeston calibration (per expiry, ~25 strikes each):")
    for (i, e) in enumerate(chosen)
        s = smiles[i]
        idx = unique(round.(Int, range(1, length(s.strikes); length=25)))
        ks, vs = s.strikes[idx], s.vols[idx]
        hp, hinfo = calibrate_heston(ks, vs, Ts[i], S0, RISK_FREE;
                                     q=qs[i], seed=0, n_starts=4,
                                     n_grid=2048, u_max=100.0, polish=true)
        println("  $e  vol RMSE=$(round(hinfo.rmse_vol; digits=5))")
        println("      v0=$(round(hp[1]; digits=4)) kappa=$(round(hp[2]; digits=3)) " *
                "theta=$(round(hp[3]; digits=4)) xi=$(round(hp[4]; digits=3)) " *
                "rho=$(round(hp[5]; digits=3))")
    end

    # BAW early-exercise diagnostic on ATM options
    println("\nAmerican early-exercise premium (BAW) at ATM, in bps of mid:")
    for (i, e) in enumerate(chosen)
        s = smiles[i]
        j = argmin(abs.(s.strikes .- Fs[i]))
        for kind in (:call, :put)
            rows = filter(x -> x.expiry == e && x.is_call == (kind === :call), clean)
            isempty(rows) && continue
            x = rows[argmin(abs.([r.strike for r in rows] .- Fs[i]))]
            prem = baw_early_exercise_premium(S0, x.strike, Ts[i], RISK_FREE,
                                              s.vols[j]; q=qs[i], kind=kind)
            println("  $e $kind K=$(x.strike) premium=$(round(prem; digits=4)) " *
                    "($(round(10000 * prem / x.mid; digits=1)) bps of mid)")
        end
    end
    println("\nDone. All numbers above are from real CBOE delayed quotes.")
end

main()
