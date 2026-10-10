using FFTW
using Interpolations: cubic_spline_interpolation

"""
Carr-Madan FFT pricing.

Prices European calls on a log-strike grid in O(N log N), then
interpolates to requested strikes with a cubic spline. Puts come from
put-call parity. Accepts any characteristic function
phi(u) = E[exp(i u log S_T)] with the spot embedded (see heston_cf).
"""

"""Black-Scholes characteristic function of log S_T."""
function bs_cf(u, T, S0, r, sigma; q=0.0)
    u_ = complex.(u)
    iu = im .* u_
    mu = log(S0) + (r - q - sigma^2 / 2) * T
    return exp.(iu .* mu .- 0.5 .* sigma^2 .* u_ .^ 2 .* T)
end

"""
    fft_price(S0, strikes, T, r; sigma=nothing, cf=nothing, kind=:call,
              alpha=1.5, N=4096, eta=0.25, q=0.0)

European prices via Carr-Madan FFT. Pass `sigma` for Black-Scholes or
`cf` (a function of u) for any model with known characteristic
function, e.g. `u -> heston_cf(u, T, S0, r, v0, kappa, theta, xi, rho)`.
"""
function fft_price(S0, strikes, T, r; sigma=nothing, cf=nothing, kind=:call,
                   alpha=1.5, N=4096, eta=0.25, q=0.0)
    (sigma === nothing) == (cf === nothing) &&
        throw(ArgumentError("pass exactly one of sigma or cf"))
    if cf === nothing
        s = sigma
        cf = u -> bs_cf(u, T, S0, r, s; q=q)
    end
    strikes_ = strikes isa Number ? [float(strikes)] : float.(strikes)
    lam = 2 * pi / (N * eta)
    b = 0.5 * N * lam
    v = collect(0:(N-1)) .* eta

    psi_v = exp(-r * T) .* cf.(v .- (alpha + 1) * im) ./
            (alpha^2 + alpha .- v .^ 2 .+ im .* (2 * alpha + 1) .* v)
    w = ones(N)
    w[2:2:end] .= 4.0
    w[3:2:end] .= 2.0
    x = exp.(im .* b .* v) .* psi_v .* w .* eta ./ 3.0
    fft_vals = fft(x)
    k_grid = -b .+ collect(0:(N-1)) .* lam
    calls_grid = exp.(-alpha .* k_grid) ./ pi .* real.(fft_vals)

    spline = cubic_spline_interpolation(range(k_grid[1], k_grid[end], length=N), calls_grid)
    logK = log.(strikes_)
    any((logK .< k_grid[1] + 1.0) .| (logK .> k_grid[end] - 1.0)) &&
        throw(ArgumentError("strike outside FFT grid; increase N or eta"))
    calls = spline.(logK)
    out = if kind === :call
        calls
    elseif kind === :put
        calls .- S0 * exp(-q * T) .+ strikes_ .* exp(-r * T)
    else
        throw(ArgumentError("kind must be :call or :put"))
    end
    return strikes isa Number ? out[1] : out
end
