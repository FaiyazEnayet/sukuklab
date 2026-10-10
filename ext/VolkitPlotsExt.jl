module VolkitPlotsExt

using Volkit
using Plots

"""
    plot_smile(strikes, vols_mkt; vols_fit=nothing, T=nothing)

Market smile with optional fitted overlay, in log-moneyness.
"""
function Volkit.plot_smile(strikes, vols_mkt; vols_fit=nothing, T=nothing)
    k = log.(float.(strikes) ./ median(float.(strikes)))
    p = scatter(k, vols_mkt; label="market", markersize=3,
                xlabel="log-moneyness (vs median strike)", ylabel="implied vol",
                title=T === nothing ? "Volatility smile" : "Volatility smile, T=$T")
    if vols_fit !== nothing
        order = sortperm(k)
        plot!(p, k[order], float.(vols_fit)[order]; label="fitted")
    end
    return p
end

"""
    plot_term_structure(expiries, atm_vols_mkt; atm_vols_fit=nothing)

ATM vol term structure, market vs fitted.
"""
function Volkit.plot_term_structure(expiries, atm_vols_mkt; atm_vols_fit=nothing)
    p = scatter(expiries, atm_vols_mkt; label="market", markersize=3,
                xlabel="expiry (years)", ylabel="ATM implied vol",
                title="Term structure")
    if atm_vols_fit !== nothing
        order = sortperm(float.(expiries))
        plot!(p, float.(expiries)[order], float.(atm_vols_fit)[order]; label="fitted")
    end
    return p
end

end
