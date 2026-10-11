"""
Volkit: a pip-installable options toolkit.

Black-Scholes pricing and greeks, SVI smile fits, Heston calibration,
and Carr-Madan FFT pricing, one clean import.
"""
module Volkit

include("black_scholes.jl")
include("american.jl")
include("svi.jl")
include("heston.jl")
include("bates.jl")
include("fft.jl")
include("marketdata.jl")
include("sukuk.jl")

# Plotting lives in ext/VolkitPlotsExt.jl and loads only when the user
# has Plots.jl available. These stubs let the extension add methods.
function plot_smile end
function plot_term_structure end

export bs_price, implied_vol, bs_greeks,
    bs_delta, bs_gamma, bs_vega, bs_theta, bs_rho, bs_vanna, bs_volga,
    baw_price, baw_early_exercise_premium, crr_price,
    fit_svi, fit_surface, surface_vol, svi_vol, svi_total_var,
    check_arbitrage, durrleman_g,
    heston_cf, heston_price, heston_vols, calibrate_heston,
    bates_cf, bates_price, bates_vols, calibrate_bates,
    fft_price, bs_cf,
    fetch_chain, parse_chain, clean_chain, otm_quotes,
    imply_dividend_yield, chain_to_json, chain_from_json,
    sukuk_price, sukuk_ytm,
    plot_smile, plot_term_structure

end
