using Optim
using Random: Xoshiro

"""
Raw SVI (Gatheral 2004): total implied variance as a function of
log-moneyness k = log(K / F):

    w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2))

Fits minimize squared relative error in total variance. Butterfly
arbitrage is penalized through the Durrleman condition g(k) >= 0;
calendar arbitrage through total variance increasing in expiry.
"""

const SVI_BOUNDS = [(-0.2, 2.0), (0.0, 3.0), (-0.999, 0.999), (-1.0, 1.0), (0.01, 1.0)]
const BUTTERFLY_PENALTY = 1e3
const CALENDAR_PENALTY = 1e3

"""Total variance w(k). p = (a, b, rho, m, sigma)."""
function svi_total_var(p, k)
    a, b, rho, m, sig = p
    k_ = _svi_vec(k)
    return _svi_scalar(a .+ b .* (rho .* (k_ .- m) .+ sqrt.((k_ .- m) .^ 2 .+ sig^2)), k)
end

_svi_vec(x::Number) = [float(x)]
_svi_vec(x::AbstractVector) = float.(x)
_svi_scalar(out, ::Number) = out[1]
_svi_scalar(out, ::AbstractVector) = out

"""Implied vol from SVI params at log-moneyness k and expiry T."""
function svi_vol(p, k, T)
    w = svi_total_var(p, k)
    return sqrt.(max.(w, 1e-12) ./ T)
end

function _w_prime(p, k)
    a, b, rho, m, sig = p
    s = sqrt.(k .^ 2 .- 2 .* m .* k .+ m^2 .+ sig^2)
    return b .* (rho .+ (k .- m) ./ s)
end

function _w_double_prime(p, k)
    a, b, rho, m, sig = p
    s = sqrt.((k .- m) .^ 2 .+ sig^2)
    return b .* sig^2 ./ s .^ 3
end

"""
    durrleman_g(p, k)

Durrleman (2005) butterfly condition. Arbitrage-free iff g(k) >= 0.
"""
function durrleman_g(p, k)
    k_ = _svi_vec(k)
    w = max.(svi_total_var(p, k_), 1e-12)
    wp = _w_prime(p, k_)
    wpp = _w_double_prime(p, k_)
    g = (1 .- k_ .* wp ./ (2 .* w)) .^ 2 .- (wp .^ 2 ./ 4) .* (1 ./ w .+ 0.25) .+ wpp ./ 2
    return _svi_scalar(g, k)
end

"""Butterfly diagnostics for one slice."""
function check_arbitrage(p; k_grid=range(-2.0, 2.0, length=401))
    kg = collect(k_grid)
    g = durrleman_g(p, kg)
    w = svi_total_var(p, kg)
    return (
        butterfly_ok=all(g .>= -1e-9) && all(w .> 0),
        min_g=minimum(g),
        min_w=minimum(w),
    )
end

function _butterfly_penalty(p, k_grid)
    g = durrleman_g(p, k_grid)
    return BUTTERFLY_PENALTY * sum(min.(g, 0.0) .^ 2)
end

function _svi_objective(p, k, w_mkt, k_grid)
    w_mod = svi_total_var(p, k)
    rel = (w_mod .- w_mkt) ./ max.(w_mkt, 1e-8)
    return sum(rel .^ 2) + _butterfly_penalty(p, k_grid)
end

function _svi_starts(w_atm, n_restarts, seed)
    rng = Xoshiro(seed)
    starts = [[w_atm * 0.8, 0.2, -0.3, 0.0, 0.2]]
    for _ in 1:n_restarts
        push!(starts, [
            rand(rng) * w_atm * 1.5,
            0.05 + rand(rng) * 0.75,
            -0.9 + rand(rng) * 1.2,
            -0.3 + rand(rng) * 0.6,
            0.05 + rand(rng) * 0.45,
        ])
    end
    return starts
end

function _fit_one(k, w_mkt, w_atm, k_grid, n_restarts, seed, cal_ref)
    lower = first.(SVI_BOUNDS)
    upper = last.(SVI_BOUNDS)
    function objective(p)
        val = _svi_objective(p, k, w_mkt, k_grid)
        if cal_ref !== nothing
            viol = min.(svi_total_var(p, k_grid) .- cal_ref, 0.0)
            val += CALENDAR_PENALTY * sum(viol .^ 2)
        end
        return val
    end
    best, best_fun = nothing, Inf
    for x0 in _svi_starts(w_atm, n_restarts, seed)
        res = optimize(objective, lower, upper, x0, Fminbox(LBFGS()),
                       Optim.Options(iterations=2000))
        if Optim.minimum(res) < best_fun
            best, best_fun = Optim.minimizer(res), Optim.minimum(res)
        end
    end
    return Tuple(Float64.(best)), best_fun
end

"""
    fit_svi(strikes, vols, T, S0, r; q=0.0, n_restarts=8, seed=0)

Fit raw SVI to one expiry slice. Returns (params, info) with
params = (a, b, rho, m, sigma).
"""
function fit_svi(strikes, vols, T, S0, r; q=0.0, n_restarts=8, seed=0)
    strikes = float.(strikes)
    vols = float.(vols)
    F = S0 * exp((r - q) * T)
    k = log.(strikes ./ F)
    w_mkt = vols .^ 2 .* T
    k_grid = collect(range(minimum(k) - 0.5, maximum(k) + 0.5, length=241))
    w_atm = _interp_atm(sortperm(k), k, w_mkt)
    params, _ = _fit_one(k, w_mkt, w_atm, k_grid, n_restarts, seed, nothing)
    vols_fit = svi_vol(params, k, T)
    arb = check_arbitrage(params; k_grid=k_grid)
    info = (
        rmse_vol=sqrt(sum((vols_fit .- vols) .^ 2) / length(vols)),
        max_abs_err_vol=maximum(abs.(vols_fit .- vols)),
        butterfly_ok=arb.butterfly_ok,
        min_g=arb.min_g,
    )
    return params, info
end

function _interp_atm(perm, k, w_mkt)
    ks, ws = k[perm], w_mkt[perm]
    i = searchsortedfirst(ks, 0.0)
    i == 1 && return ws[1]
    i > length(ks) && return ws[end]
    t = (0.0 - ks[i-1]) / (ks[i] - ks[i-1])
    return ws[i-1] + t * (ws[i] - ws[i-1])
end

"""
    fit_surface(strikes_list, vols_list, expiries, S0, r; q=0.0, n_restarts=4, seed=0)

Fit SVI per expiry with a calendar-spread penalty: slices are fit in
expiry order and each pays when its total variance dips below the
previous slice on a shared grid. Returns (params_list, info) with a
surface-level calendar diagnostic.
"""
function fit_surface(strikes_list, vols_list, expiries, S0, r; q=0.0, n_restarts=4, seed=0)
    expiries = float.(expiries)
    order = sortperm(expiries)
    n = length(expiries)
    params_list = Vector{NTuple{5,Float64}}(undef, n)
    slice_infos = Vector{Any}(undef, n)
    k_grid = collect(range(-1.5, 1.5, length=241))
    prev_w = nothing
    for (pos, idx) in enumerate(order)
        strikes = float.(strikes_list[idx])
        vols = float.(vols_list[idx])
        T = expiries[idx]
        F = S0 * exp((r - q) * T)
        k = log.(strikes ./ F)
        w_mkt = vols .^ 2 .* T
        w_atm = _interp_atm(sortperm(k), k, w_mkt)
        params, _ = _fit_one(k, w_mkt, w_atm, k_grid, n_restarts, seed + pos, prev_w)
        vols_fit = svi_vol(params, k, T)
        arb = check_arbitrage(params; k_grid=k_grid)
        slice_infos[idx] = (
            rmse_vol=sqrt(sum((vols_fit .- vols) .^ 2) / length(vols)),
            butterfly_ok=arb.butterfly_ok,
        )
        params_list[idx] = params
        prev_w = svi_total_var(params, k_grid)
    end
    cal_ok = true
    for i in 1:n-1
        w1 = svi_total_var(params_list[order[i]], k_grid)
        w2 = svi_total_var(params_list[order[i+1]], k_grid)
        any(w2 .< w1 .- 1e-9) && (cal_ok = false)
    end
    return params_list, (calendar_ok=cal_ok, slice_infos=slice_infos)
end

"""Interpolate the fitted surface in total variance across expiries."""
function surface_vol(params_list, expiries, strikes, T, S0, r; q=0.0)
    expiries = float.(expiries)
    strikes = float.(strikes)
    F = S0 * exp((r - q) * T)
    k = log.(strikes ./ F)
    Ts = sort(expiries)
    order = sortperm(expiries)
    lo, hi = argmin(expiries), argmax(expiries)
    T <= Ts[1] && return svi_vol(params_list[lo], k, T)
    T >= Ts[end] && return svi_vol(params_list[hi], k, T)
    i = searchsortedfirst(Ts, T) - 1
    T1, T2 = Ts[i], Ts[i+1]
    w1 = svi_total_var(params_list[order[i]], k)
    w2 = svi_total_var(params_list[order[i+1]], k)
    w = w1 .+ (w2 .- w1) .* ((T - T1) / (T2 - T1))
    return sqrt.(max.(w, 1e-12) ./ T)
end
