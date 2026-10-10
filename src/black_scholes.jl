using SpecialFunctions: erf

# Normal CDF/PDF from erf (SpecialFunctions no longer ships normcdf).
_normcdf(x) = 0.5 * (1 + erf(x / sqrt(2)))
_normpdf(x) = exp(-x^2 / 2) / sqrt(2pi)

"""
    bs_price(S0, K, T, r, sigma; q=0.0, kind=:call)

European Black-Scholes price. `K` may be a scalar or a vector.
"""
function bs_price(S0, K, T, r, sigma; q=0.0, kind=:call)
    K_ = _asvec(K)
    d1 = _d1.(S0, K_, T, r, q, sigma)
    d2 = d1 .- sigma .* sqrt(T)
    disc_q, disc_r = exp(-q * T), exp(-r * T)
    out = if kind === :call
        disc_q .* S0 .* _normcdf.(d1) .- disc_r .* K_ .* _normcdf.(d2)
    elseif kind === :put
        disc_r .* K_ .* _normcdf.(-d2) .- disc_q .* S0 .* _normcdf.(-d1)
    else
        throw(ArgumentError("kind must be :call or :put"))
    end
    return _asscalar(out, K)
end

_asvec(x::Number) = [float(x)]
_asvec(x::AbstractVector) = float.(x)
_asscalar(out, ::Number) = out[1]
_asscalar(out, ::AbstractVector) = out

function _d1(S0, K, T, r, q, sigma)
    (log(S0 / K) + (r - q + sigma^2 / 2) * T) / (sigma * sqrt(T))
end

"""Delta."""
function bs_delta(S0, K, T, r, sigma; q=0.0, kind=:call)
    K_ = _asvec(K)
    d1 = _d1.(S0, K_, T, r, q, sigma)
    out = if kind === :call
        exp(-q * T) .* _normcdf.(d1)
    elseif kind === :put
        exp(-q * T) .* (_normcdf.(d1) .- 1)
    else
        throw(ArgumentError("kind must be :call or :put"))
    end
    return _asscalar(out, K)
end

"""Gamma (same for calls and puts)."""
function bs_gamma(S0, K, T, r, sigma; q=0.0)
    K_ = _asvec(K)
    d1 = _d1.(S0, K_, T, r, q, sigma)
    out = exp(-q * T) .* _normpdf.(d1) ./ (S0 .* sigma .* sqrt(T))
    return _asscalar(out, K)
end

"""Vega: dPrice/d(sigma), per 1.0 vol point."""
function bs_vega(S0, K, T, r, sigma; q=0.0)
    K_ = _asvec(K)
    d1 = _d1.(S0, K_, T, r, q, sigma)
    out = S0 .* exp(-q * T) .* _normpdf.(d1) .* sqrt(T)
    return _asscalar(out, K)
end

"""Theta: dPrice/dT, per year (negative for long options)."""
function bs_theta(S0, K, T, r, sigma; q=0.0, kind=:call)
    K_ = _asvec(K)
    d1 = _d1.(S0, K_, T, r, q, sigma)
    d2 = d1 .- sigma .* sqrt(T)
    term1 = .-(S0 .* _normpdf.(d1) .* sigma .* exp(-q * T)) ./ (2 .* sqrt(T))
    out = if kind === :call
        term1 .- r .* K_ .* exp(-r * T) .* _normcdf.(d2) .+
               q .* S0 .* exp(-q * T) .* _normcdf.(d1)
    elseif kind === :put
        term1 .+ r .* K_ .* exp(-r * T) .* _normcdf.(-d2) .-
               q .* S0 .* exp(-q * T) .* _normcdf.(-d1)
    else
        throw(ArgumentError("kind must be :call or :put"))
    end
    return _asscalar(out, K)
end

"""Rho: dPrice/dr, per 1.0 rate point."""
function bs_rho(S0, K, T, r, sigma; q=0.0, kind=:call)
    K_ = _asvec(K)
    d1 = _d1.(S0, K_, T, r, q, sigma)
    d2 = d1 .- sigma .* sqrt(T)
    out = if kind === :call
        K_ .* T .* exp(-r * T) .* _normcdf.(d2)
    elseif kind === :put
        .-(K_ .* T .* exp(-r * T) .* _normcdf.(-d2))
    else
        throw(ArgumentError("kind must be :call or :put"))
    end
    return _asscalar(out, K)
end

"""Vanna: d(Delta)/d(sigma), analytic."""
function bs_vanna(S0, K, T, r, sigma; q=0.0)
    K_ = _asvec(K)
    d1 = _d1.(S0, K_, T, r, q, sigma)
    d2 = d1 .- sigma .* sqrt(T)
    out = .-exp(-q * T) .* _normpdf.(d1) .* d2 ./ sigma
    return _asscalar(out, K)
end

"""Volga: d(Vega)/d(sigma), analytic."""
function bs_volga(S0, K, T, r, sigma; q=0.0)
    K_ = _asvec(K)
    d1 = _d1.(S0, K_, T, r, q, sigma)
    d2 = d1 .- sigma .* sqrt(T)
    out = bs_vega.(S0, K_, T, r, sigma; q=q) .* d1 .* d2 ./ sigma
    return _asscalar(out, K)
end

"""
    bs_greeks(S0, K, T, r, sigma; q=0.0, kind=:call)

NamedTuple of first and second order greeks.
"""
function bs_greeks(S0, K, T, r, sigma; q=0.0, kind=:call)
    (
        delta=bs_delta(S0, K, T, r, sigma; q=q, kind=kind),
        gamma=bs_gamma(S0, K, T, r, sigma; q=q),
        vega=bs_vega(S0, K, T, r, sigma; q=q),
        theta=bs_theta(S0, K, T, r, sigma; q=q, kind=kind),
        rho=bs_rho(S0, K, T, r, sigma; q=q, kind=kind),
        vanna=bs_vanna(S0, K, T, r, sigma; q=q),
        volga=bs_volga(S0, K, T, r, sigma; q=q),
    )
end

"""
    implied_vol(price, S0, K, T, r; q=0.0, kind=:call)

Implied volatility via Newton-Raphson with a bisection fallback.
Returns NaN when the price violates arbitrage bounds.
"""
function implied_vol(price, S0, K, T, r; q=0.0, kind=:call, tol=1e-10)
    disc_r, disc_q = exp(-r * T), exp(-q * T)
    fwd = S0 * disc_q / disc_r
    lo_b, hi_b = if kind === :call
        max(disc_r * (fwd - K), 0.0), S0 * disc_q
    elseif kind === :put
        max(disc_r * (K - fwd), 0.0), disc_r * K
    else
        throw(ArgumentError("kind must be :call or :put"))
    end
    (price <= lo_b || price >= hi_b) && return NaN
    # Brenner-Subrahmanyam start
    sig = clamp(sqrt(2 * pi / T) * price / S0, 1e-4, 5.0)
    converged = false
    for _ in 1:100
        v = bs_vega(S0, K, T, r, sig; q=q)
        v < 1e-12 && break
        step = (bs_price(S0, K, T, r, sig; q=q, kind=kind) - price) / v
        sig -= step
        sig <= 0 && break
        if abs(step) < tol
            converged = true
            break
        end
    end
    if !converged || !(0 < sig < 5.0)
        lo, hi = 1e-6, 5.0
        for _ in 1:200
            mid = (lo + hi) / 2
            if bs_price(S0, K, T, r, mid; q=q, kind=kind) < price
                lo = mid
            else
                hi = mid
            end
            hi - lo < tol && break
        end
        sig = (lo + hi) / 2
    end
    return sig
end
