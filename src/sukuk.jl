"""
Sukuk pricing.

A fixed-profit-rate sukuk makes periodic profit distributions and
repays the principal (face value) at maturity. Pricing is the present
value of those cash flows at the market profit rate, the same
arithmetic as a conventional fixed-coupon bond. Variable-rate or
amortizing structures are out of scope.
"""

"""
    sukuk_price(face, profit_rate, ytm, T; m=2)

Price of a fixed-profit-rate sukuk with face value `face`, annual
profit rate `profit_rate`, `m` distributions per year, maturity `T`
in years, discounted at annual yield `ytm` (compounded `m` times).

The closed form assumes settlement on a distribution date, so no
profit has accrued and this price is both the full and the clean
price. `m * T` must be a whole number of periods: a maturity that
does not land on a whole number of periods has no closed form here
and is rejected rather than rounded to the nearest period count.
Price such an instrument from its dated schedule instead, with
`payment_schedule` and `price_from_cashflows`, and use
`price_decomposition` for settlement between distribution dates.
The yield must sit above -m, the point where 1 + ytm/m hits
zero; at or below it the price is undefined and rejected. Near
that boundary the price grows without bound, and a price beyond
the largest finite Float64 is reported as Inf rather than NaN.
"""
function sukuk_price(face, profit_rate, ytm, T; m=2)
    face, profit_rate, ytm, T = float(face), float(profit_rate), float(ytm),
        float(T)
    face <= 0 && throw(ArgumentError("face must be positive"))
    T <= 0 && throw(ArgumentError("T must be positive"))
    m = float(m)
    (m >= 1 && m == round(m)) ||
        throw(ArgumentError("m must be a positive whole number of " *
                            "distributions per year"))
    # The discount factor per period is 1 / (1 + ytm/m), which needs
    # a positive base: at ytm = -m the price is undefined, and
    # below it the closed form would read a negative base to a
    # fractional power.
    ytm <= -m && throw(ArgumentError("ytm must be above -$m (the " *
                                     "yield at which 1 + ytm/m hits " *
                                     "zero)"))
    periods = m * T
    abs(periods - round(periods)) > 1e-9 &&
        throw(ArgumentError("T = $T years at m = $(Int(m)) distributions " *
                            "per year is not a whole number of periods; " *
                            "price the dated schedule with " *
                            "payment_schedule and price_from_cashflows"))
    n = round(Int, periods)
    c = face * profit_rate / m
    y = ytm / m
    if abs(y) < 1e-12
        return c * n + face
    end
    df = 1 / (1 + y)
    dfn = df^n
    # Near the domain boundary the discount factor per period is
    # huge and df^n overflows Float64: the true price is then
    # beyond the largest finite Float64, so Inf is the honest
    # answer, not the NaN the closed form would produce from
    # 0 * Inf when the profit rate is zero.
    isfinite(dfn) || return Inf
    # geometric sum: c * (df + df^2 + ... + df^n) + face * df^n
    pv_coupons = c * df * (1 - dfn) / (1 - df)
    total = pv_coupons + face * dfn
    if !isfinite(total)
        # The closed form overflowed in an intermediate product
        # while its terms are finite: recompute by direct
        # summation, which never holds more than the largest term.
        total = 0.0
        term = df
        for _ in 1:n
            total += c * term
            term *= df
        end
        total += face * dfn
    end
    return total
end

# Analytic derivative of sukuk_price with respect to the nominal
# annual yield, from the closed form: with S = 1 + df + ... +
# df^(n-1) = (1 - df^n) / (1 - df) and df = 1 / (1 + ytm/m),
# dP/d(df) = c * (S + df * S') + face * n * df^(n-1) where
# S' = (1 - n*df^(n-1) + (n-1)*df^n) / (1 - df)^2, and
# dP/d(ytm) = dP/d(df) * (-df^2 / m). At df = 1 the closed form
# is 0/0, so the exact values S = n and S' = n*(n-1)/2 are used
# there. Assumes the inputs already passed sukuk_price validation.
function _sukuk_dprice_dytm(face, profit_rate, ytm, T; m=2)
    mm = float(m)
    n = round(Int, mm * float(T))
    c = float(face) * float(profit_rate) / mm
    df = 1 / (1 + float(ytm) / mm)
    if abs(df - 1) < 1e-8
        s = Float64(n)
        sp = Float64(n * (n - 1)) / 2
    else
        s = (1 - df^n) / (1 - df)
        sp = (1 - n * df^(n - 1) + (n - 1) * df^n) / (1 - df)^2
    end
    dprice_ddf = c * (s + df * sp) + float(face) * n * df^(n - 1)
    return dprice_ddf * (-df^2 / mm)
end

"""
    sukuk_ytm_result(price, face, profit_rate, T; m=2, ftol=nothing, xtol=1e-12, maxiter=200)

Yield to maturity implied by `price`, as a `YieldSolveResult`:
the solve status, the yield, the absolute and relative residual
at the returned yield, the final bracket, and the iteration and
evaluation counts. The bracket adapts to the valid domain
(yield above -m), so a root outside the old hard-coded
[-0.99, 5.0] bracket is found instead of reported missing, and
the solve uses safeguarded Newton steps from the analytic price
derivative with bisection as the fallback. A non-positive or
non-finite price has no root (`:no_root`); malformed inputs
(non-positive face, non-positive maturity, a maturity that is
not a whole number of periods, a bad compounding frequency)
throw `ArgumentError`, as `sukuk_price` does. `ftol` is the
absolute residual tolerance, defaulting to 1e-12 of the target
price (floored at 1e-12); `xtol` is the bracket-width tolerance.
"""
function sukuk_ytm_result(price, face, profit_rate, T; m=2,
                          ftol=nothing, xtol::Float64=1e-12,
                          maxiter::Int=200)
    price = float(price)
    if !isfinite(price) || price <= 0
        return YieldSolveResult(:no_root, NaN, NaN, NaN, (-0.99, 5.0),
                                0, 0)
    end
    f = y -> sukuk_price(face, profit_rate, y, T; m=m) - price
    d = y -> _sukuk_dprice_dytm(face, profit_rate, y, T; m=m)
    ftol_eff = ftol === nothing ? 1e-12 * max(1.0, price) : float(ftol)
    return _solve_decreasing(f, d, price; domain_lo=-float(m),
                             lo=-0.99, hi=5.0, ftol=ftol_eff,
                             xtol=xtol, maxiter=maxiter)
end

"""
    sukuk_ytm(price, face, profit_rate, T; m=2)

Yield to maturity implied by `price`, by safeguarded
Newton/bisection on an adaptive bracket over the valid domain
(yield above -m). Returns NaN when the price has no root: a
non-positive or non-finite price. For the full solve outcome,
including the residual, bracket and iteration count, see
`sukuk_ytm_result`.
"""
function sukuk_ytm(price, face, profit_rate, T; m=2)
    r = sukuk_ytm_result(price, face, profit_rate, T; m=m)
    return r.status == :converged ? r.yield : NaN
end
