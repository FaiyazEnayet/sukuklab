using Optim
using Random: Xoshiro

"""
Heston stochastic volatility: characteristic function, Fourier pricing,
and calibration.

    dS/S = r dt + sqrt(v) dW1
    dv   = kappa (theta - v) dt + xi sqrt(v) dW2,  corr(dW1, dW2) = rho dt

The characteristic function uses the Little-trap formulation, which
keeps the complex logarithm on its principal branch.
"""

"""
    heston_cf(u, T, S0, r, v0, kappa, theta, xi, rho; q=0.0)

Characteristic function phi(u) = E[exp(i u log S_T)].
Satisfies phi(-i) = S0 * exp((r-q)T). Vectorized over u.
"""
function heston_cf(u, T, S0, r, v0, kappa, theta, xi, rho; q=0.0)
    u_ = complex.(u)
    iu = im .* u_
    d = sqrt.((rho * xi .* iu .- kappa) .^ 2 .- xi^2 .* (-iu .- u_ .^ 2))
    g = (kappa .- rho * xi .* iu .- d) ./ (kappa .- rho * xi .* iu .+ d)
    exp_dt = exp.(-d .* T)
    C = (r - q) .* iu .* T .+ kappa * theta / xi^2 .* (
        (kappa .- rho * xi .* iu .- d) .* T .- 2 .* log.((1 .- g .* exp_dt) ./ (1 .- g))
    )
    D = (kappa .- rho * xi .* iu .- d) ./ xi^2 .* (1 .- exp_dt) ./ (1 .- g .* exp_dt)
    return exp.(C .+ D .* v0 .+ iu .* log(S0))
end

function _prob_integrals_cf(cf, S0, K, T, r, q; n_grid=8192, u_max=120.0)
    logK = log.(K)
    u = collect(range(0.0, u_max, length=n_grid))
    u[1] = 1e-10
    du = u[2] - u[1]
    phi = cf(u)
    phi_m1 = cf(u .- im)
    phi_neg_i = real(cf(-im))  # S0 * exp((r - q) * T) for a martingale model
    # (n_grid, n_strikes)
    eu = exp.(-im .* u .* logK')
    iu = im .* u
    f2 = real.(eu .* (phi ./ iu))
    f1 = real.(eu .* (phi_m1 ./ (iu .* phi_neg_i)))
    trap(f) = (sum(f[2:end-1, :], dims=1) .+ (f[1:1, :] .+ f[end:end, :]) ./ 2) .* du
    P2 = 0.5 .+ vec(trap(f2)) ./ pi
    P1 = 0.5 .+ vec(trap(f1)) ./ pi
    return P1, P2
end

function _prob_integrals(S0, K, T, r, v0, kappa, theta, xi, rho; q=0.0, n_grid=8192, u_max=120.0)
    cf = u -> heston_cf(u, T, S0, r, v0, kappa, theta, xi, rho; q=q)
    return _prob_integrals_cf(cf, S0, K, T, r, q; n_grid=n_grid, u_max=u_max)
end

"""
    heston_price(S0, K, T, r, v0, kappa, theta, xi, rho; kind=:call)

European option price under Heston via Fourier inversion.
"""
function heston_price(S0, K, T, r, v0, kappa, theta, xi, rho;
                      q=0.0, kind=:call, n_grid=8192, u_max=120.0)
    scalar = K isa Number
    K_ = scalar ? [float(K)] : float.(K)
    P1, P2 = _prob_integrals(S0, K_, T, r, v0, kappa, theta, xi, rho; q=q,
                             n_grid=n_grid, u_max=u_max)
    disc_q, disc_r = exp(-q * T), exp(-r * T)
    call = S0 .* disc_q .* P1 .- K_ .* disc_r .* P2
    out = if kind === :call
        call
    elseif kind === :put
        call .- S0 .* disc_q .+ K_ .* disc_r
    else
        throw(ArgumentError("kind must be :call or :put"))
    end
    return scalar ? out[1] : out
end

"""Implied vols of Heston model call prices."""
function heston_vols(S0, strikes, T, r, v0, kappa, theta, xi, rho;
                     q=0.0, n_grid=4096, u_max=100.0)
    prices = heston_price(S0, strikes, T, r, v0, kappa, theta, xi, rho;
                          q=q, kind=:call, n_grid=n_grid, u_max=u_max)
    return implied_vol.(prices, S0, strikes, T, r; q=q, kind=:call)
end

const HESTON_BOUNDS = [
    (0.005, 0.50),   # v0
    (0.10, 10.0),    # kappa
    (0.005, 0.50),   # theta
    (0.05, 1.50),    # xi
    (-0.99, 0.30),   # rho
]

"""
    calibrate_heston(strikes, vols, T, S0, r; q=0.0, seed=0, n_starts=12,
                     n_grid=4096)

Calibrate Heston to a vol smile by least squares on implied vols:
seeded multi-start local optimization, best start wins, then a final
polish. Returns (params, info) with params = (v0, kappa, theta, xi, rho).
"""
function calibrate_heston(strikes, vols, T, S0, r; q=0.0, seed=0, n_starts=12,
                           n_grid=4096, u_max=100.0, polish=true)
    strikes = float.(strikes)
    vols = float.(vols)
    lower = first.(HESTON_BOUNDS)
    upper = last.(HESTON_BOUNDS)

    function objective(x)
        v0, kappa, theta, xi, rho = x
        mv = try
            heston_vols(S0, strikes, T, r, v0, kappa, theta, xi, rho;
                        q=q, n_grid=n_grid, u_max=u_max)
        catch
            return 1e6
        end
        any(.!isfinite.(mv)) && return 1e6
        return sqrt(sum((mv .- vols) .^ 2) / length(vols))
    end

    # Box constraints via logit transform; plain LBFGS in unbounded space.
    # (Avoids Fminbox, which proved pathologically slow here.)
    _to_u(x) = log.((x .- lower) ./ (upper .- x))
    _to_x(y) = lower .+ (upper .- lower) ./ (1 .+ exp.(-y))
    function u_objective(y)
        return objective(_to_x(y))
    end
    rng = Xoshiro(seed)
    best_x, best_fun = nothing, Inf
    n_iters = 0
    for _ in 1:n_starts
        x0 = lower .+ rand(rng, 5) .* (upper .- lower)
        # keep starts strictly inside the box for the logit
        x0 = min.(max.(x0, lower .+ 1e-6), upper .- 1e-6)
        res = optimize(u_objective, _to_u(x0), LBFGS(),
                       Optim.Options(iterations=200))
        n_iters += res.iterations
        if Optim.minimum(res) < best_fun
            best_x, best_fun = _to_x(Optim.minimizer(res)), Optim.minimum(res)
        end
    end
    if polish
        res = optimize(u_objective, _to_u(best_x), LBFGS(),
                       Optim.Options(iterations=400))
        n_iters += res.iterations
        if Optim.minimum(res) < best_fun
            best_x, best_fun = _to_x(Optim.minimizer(res)), Optim.minimum(res)
        end
    end
    v0, kappa, theta, xi, rho = Float64.(best_x)
    mv = heston_vols(S0, strikes, T, r, v0, kappa, theta, xi, rho;
                     q=q, n_grid=n_grid, u_max=u_max)
    info = (
        rmse_vol=sqrt(sum((mv .- vols) .^ 2) / length(vols)),
        max_abs_err_vol=maximum(abs.(mv .- vols)),
        n_starts=n_starts,
        n_iters=n_iters,
    )
    return (v0, kappa, theta, xi, rho), info
end
