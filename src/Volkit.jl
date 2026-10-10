"""
Volkit: a pip-installable options toolkit.

Black-Scholes pricing and greeks, SVI smile fits, Heston calibration,
and Carr-Madan FFT pricing, one clean import.
"""
module Volkit

include("black_scholes.jl")
include("svi.jl")
include("heston.jl")
include("fft.jl")

# Plotting lives in ext/VolkitPlotsExt.jl and loads only when the user
# has Plots.jl available. These stubs let the extension add methods.
function plot_smile end
function plot_term_structure end

export bs_price, implied_vol, bs_greeks,
    bs_delta, bs_gamma, bs_vega, bs_theta, bs_rho, bs_vanna, bs_volga,
    fit_svi, fit_surface, surface_vol, svi_vol, svi_total_var,
    check_arbitrage, durrleman_g,
    heston_cf, heston_price, heston_vols, calibrate_heston,
    fft_price, bs_cf,
    plot_smile, plot_term_structure

end
