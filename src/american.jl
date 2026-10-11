"""
American option pricing via the Barone-Adesi and Whaley (1987)
quadratic approximation.

This is an approximation, not a PDE solve. It is accurate for most
liquid options and weakest for deep in-the-money puts close to expiry,
where the early exercise boundary moves fast. Treat it as a fast
estimate of the early exercise premium, not the truth.
"""

"""
    baw_price(S0, K, T, r, sigma; q=0.0, kind=:call)

American option price via Barone-Adesi-Whaley. Falls back to the
European price when early exercise can never be optimal (q = 0 calls)
or at expiry.
"""
function baw_price(S0, K, T, r, sigma; q=0.0, kind=:call)
    S0, K, T = float(S0), float(K), float(T)
    if T <= 0
        return kind === :call ? max(S0 - K, 0.0) : max(K - S0, 0.0)
    end
    if kind !== :call && kind !== :put
        throw(ArgumentError("kind must be :call or :put"))
    end
    # A non-dividend call is never exercised early.
    if kind === :call && q <= 0
        return bs_price(S0, K, T, r, sigma; q=q, kind=:call)
    end
    b = r - q
    Nn = 2b / sigma^2
    Mm = 2r / sigma^2
    Kk = 1 - exp(-r * T)
    disc_qT = exp(-q * T)
    if kind === :call
        q2 = (-(Nn - 1) + sqrt((Nn - 1)^2 + 4Mm / Kk)) / 2
        S_star = _baw_call_critical(K, T, r, q, sigma, q2, disc_qT)
        eu = bs_price(S0, K, T, r, sigma; q=q, kind=:call)
        if S0 >= S_star
            return S0 - K
        end
        d1s = _d1(S_star, K, T, r, q, sigma)
        A2 = (S_star / q2) * (1 - disc_qT * _normcdf(d1s))
        return eu + A2 * (S0 / S_star)^q2
    else
        q1 = (-(Nn - 1) - sqrt((Nn - 1)^2 + 4Mm / Kk)) / 2
        S_crit = _baw_put_critical(K, T, r, q, sigma, q1, disc_qT)
        eu = bs_price(S0, K, T, r, sigma; q=q, kind=:put)
        if S0 <= S_crit
            return K - S0
        end
        d1s = _d1(S_crit, K, T, r, q, sigma)
        A1 = -(S_crit / q1) * (1 - disc_qT * _normcdf(-d1s))
        return eu + A1 * (S0 / S_crit)^q1
    end
end

"""Critical stock price for the American call: f(S) = 0 on (K, inf)."""
function _baw_call_critical(K, T, r, q, sigma, q2, disc_qT)
    f(S) = S - K - bs_price(S, K, T, r, sigma; q=q, kind=:call) -
           (S / q2) * (1 - disc_qT * _normcdf(_d1(S, K, T, r, q, sigma)))
    lo, hi = K, 2K
    flo = f(lo)
    flo >= 0 && return lo
    while f(hi) < 0
        hi *= 2
        hi > 1e12 && return Inf  # effectively never exercised
    end
    for _ in 1:200
        mid = (lo + hi) / 2
        if f(mid) < 0
            lo = mid
        else
            hi = mid
        end
        hi - lo < 1e-10 * max(hi, 1.0) && break
    end
    return (lo + hi) / 2
end

"""Critical stock price for the American put: g(S) = 0 on (0, K)."""
function _baw_put_critical(K, T, r, q, sigma, q1, disc_qT)
    g(S) = K - S - bs_price(S, K, T, r, sigma; q=q, kind=:put) +
           (S / q1) * (1 - disc_qT * _normcdf(-_d1(S, K, T, r, q, sigma)))
    hi = K
    ghi = g(hi)
    ghi >= 0 && return hi
    lo = K / 2
    while g(lo) < 0
        lo /= 2
        lo < 1e-12 && return 0.0
    end
    # g(lo) > 0, g(hi) < 0: root where g crosses zero going down
    for _ in 1:200
        mid = (lo + hi) / 2
        if g(mid) < 0
            hi = mid
        else
            lo = mid
        end
        hi - lo < 1e-10 * max(hi, 1.0) && break
    end
    return (lo + hi) / 2
end

"""
    baw_early_exercise_premium(S0, K, T, r, sigma; q=0.0, kind=:call)

How much of the BAW American price is early exercise premium.
"""
function baw_early_exercise_premium(S0, K, T, r, sigma; q=0.0, kind=:call)
    baw_price(S0, K, T, r, sigma; q=q, kind=kind) -
        bs_price(S0, K, T, r, sigma; q=q, kind=kind)
end
