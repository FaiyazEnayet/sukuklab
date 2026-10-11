"""
Bates (1996) stochastic volatility with log-normal jumps.

    dS/S = (r - q - lambdaJ * muJ) dt + sqrt(v) dW1 + J dN
    dv   = kappa (theta - v) dt + xi sqrt(v) dW2,  corr(dW1, dW2) = rho dt

N is a Poisson process with intensity lambdaJ; conditional on a jump,
log(1 + J) ~ Normal(log(1 + muJ) - sigJ^2 / 2, sigJ^2), so E[J] = muJ
and the drift compensator lambdaJ * muJ keeps discounted prices a
martingale.

When to use it over Heston: short-dated smiles. A pure diffusion needs
time for volatility to move the tails, so it cannot make the steep skew
you see a few days before expiry. Jumps put mass in the tails
instantly, which is exactly what the short end needs. On the SPY
snapshot in data/, Heston leaves vol RMSE 0.081 on the 6-day expiry;
Bates gets 0.006.

The characteristic function is the Heston CF (with jump-compensated
drift) times the compound-Poisson jump component. Pricing reuses the
same Fourier inverter as Heston.
"""

"""
    bates_cf(u, T, S0, r, v0, kappa, theta, xi, rho, lambdaJ, muJ, sigJ; q=0.0)

Characteristic function phi(u) = E[exp(i u log S_T)] for the Bates
model. With lambdaJ = 0 this is exactly the Heston CF. Vectorized over u.
"""
function bates_cf(u, T, S0, r, v0, kappa, theta, xi, rho, lambdaJ, muJ, sigJ;
                  q=0.0)
    u_ = complex.(u)
    iu = im .* u_
    # E[exp(i u log(1 + J))] for log(1 + J) ~ N(m, sigJ^2).
    m = log(1 + muJ) - sigJ^2 / 2
    psi = exp.(iu .* m .- (sigJ^2 / 2) .* u_ .^ 2)
    jump = exp.(lambdaJ * T .* (psi .- 1))
    diffusive = heston_cf(u, T, S0, r - lambdaJ * muJ, v0, kappa, theta, xi,
                          rho; q=q)
    return diffusive .* jump
end

"""
    bates_price(S0, K, T, r, v0, kappa, theta, xi, rho, lambdaJ, muJ, sigJ;
                q=0.0, kind=:call)

European option price under Bates via Fourier inversion.
"""
function bates_price(S0, K, T, r, v0, kappa, theta, xi, rho, lambdaJ, muJ,
                     sigJ; q=0.0, kind=:call, n_grid=8192, u_max=200.0)
    scalar = K isa Number
    K_ = scalar ? [float(K)] : float.(K)
    cf = u -> bates_cf(u, T, S0, r, v0, kappa, theta, xi, rho, lambdaJ, muJ,
                       sigJ; q=q)
    P1, P2 = _prob_integrals_cf(cf, S0, K_, T, r, q;
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

"""Implied vols of Bates model call prices."""
function bates_vols(S0, strikes, T, r, v0, kappa, theta, xi, rho, lambdaJ,
                    muJ, sigJ; q=0.0, n_grid=4096, u_max=200.0)
    prices = bates_price(S0, strikes, T, r, v0, kappa, theta, xi, rho, lambdaJ,
                         muJ, sigJ; q=q, kind=:call, n_grid=n_grid, u_max=u_max)
    return implied_vol.(prices, S0, strikes, T, r; q=q, kind=:call)
end

const BATES_BOUNDS = [
    (0.005, 0.50),   # v0
    (0.10, 10.0),    # kappa
    (0.005, 0.50),   # theta
    (0.05, 1.50),    # xi
    (-0.99, 0.30),   # rho
    (0.01, 5.0),     # lambdaJ: jumps per year
    (-0.40, 0.10),   # muJ: mean proportional jump size
    (0.02, 0.80),    # sigJ: jump size volatility
]

"""
    calibrate_bates(strikes, vols, T, S0, r; q=0.0, seed=0, n_starts=8,
                    n_grid=2048)

Calibrate Bates to a vol smile by least squares on implied vols.
Seeded multi-start local optimization: a quick Heston fit warms the
diffusion block, then each start perturbs it and draws fresh jump
params, best start wins, then a final polish. Returns (params, info)
with params = (v0, kappa, theta, xi, rho, lambdaJ, muJ, sigJ).
"""
function calibrate_bates(strikes, vols, T, S0, r; q=0.0, seed=0, n_starts=8,
                         n_grid=4096, u_max=200.0, polish=true)
    strikes = float.(strikes)
    vols = float.(vols)
    lower = first.(BATES_BOUNDS)
    upper = last.(BATES_BOUNDS)

    function objective(x)
        v0, kappa, theta, xi, rho, lambdaJ, muJ, sigJ = x
        mv = try
            bates_vols(S0, strikes, T, r, v0, kappa, theta, xi, rho, lambdaJ,
                       muJ, sigJ; q=q, n_grid=n_grid, u_max=u_max)
        catch
            return 1e6
        end
        any(.!isfinite.(mv)) && return 1e6
        return sqrt(sum((mv .- vols) .^ 2) / length(vols))
    end

    # Box constraints via logit transform; plain LBFGS in unbounded space.
    _to_u(x) = log.((x .- lower) ./ (upper .- x))
    _to_x(y) = lower .+ (upper .- lower) ./ (1 .+ exp.(-y))
    u_objective(y) = objective(_to_x(y))

    rng = Xoshiro(seed)
    # Warm start: cheap Heston fit for the diffusion block.
    hp, _ = calibrate_heston(strikes, vols, T, S0, r; q=q, seed=seed,
                             n_starts=3, n_grid=n_grid, u_max=u_max,
                             polish=false)
    best_x, best_fun, n_iters = nothing, Inf, 0
    for s in 1:n_starts
        x0 = if s == 1
            [hp[1], hp[2], hp[3], hp[4], hp[5], 0.5, -0.10, 0.25]
        else
            dj = 0.8 .+ 0.4 .* rand(rng, 5)
            [hp[1] * dj[1], hp[2] * dj[2], hp[3] * dj[3], hp[4] * dj[4],
             hp[5], 0.01 + 4.99 * rand(rng), -0.40 + 0.50 * rand(rng),
             0.02 + 0.78 * rand(rng)]
        end
        # keep starts strictly inside the box for the logit
        x0 = min.(max.(x0, lower .+ 1e-6), upper .- 1e-6)
        res = optimize(u_objective, _to_u(x0), LBFGS(),
                       Optim.Options(iterations=250))
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
    p = Float64.(best_x)
    mv = bates_vols(S0, strikes, T, r, p...; q=q, n_grid=n_grid, u_max=u_max)
    info = (
        rmse_vol=sqrt(sum((mv .- vols) .^ 2) / length(vols)),
        max_abs_err_vol=maximum(abs.(mv .- vols)),
        n_starts=n_starts,
        n_iters=n_iters,
    )
    return Tuple(p), info
end
