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
"""
function sukuk_price(face, profit_rate, ytm, T; m=2)
    face, profit_rate, ytm, T = float(face), float(profit_rate), float(ytm),
        float(T)
    face <= 0 && throw(ArgumentError("face must be positive"))
    T <= 0 && throw(ArgumentError("T must be positive"))
    m < 1 && throw(ArgumentError("m must be a positive integer"))
    n = round(Int, m * T)
    c = face * profit_rate / m
    y = ytm / m
    if abs(y) < 1e-12
        return c * n + face
    end
    df = 1 / (1 + y)
    # geometric sum: c * (df + df^2 + ... + df^n) + face * df^n
    pv_coupons = c * df * (1 - df^n) / (1 - df)
    return pv_coupons + face * df^n
end

"""
    sukuk_ytm(price, face, profit_rate, T; m=2)

Yield to maturity implied by `price`, by bisection. Returns NaN when
the price is outside the attainable range.
"""
function sukuk_ytm(price, face, profit_rate, T; m=2)
    price = float(price)
    price <= 0 && return NaN
    f(y) = sukuk_price(face, profit_rate, y, T; m=m) - price
    lo, hi = -0.99, 5.0
    flo, fhi = f(lo), f(hi)
    (flo < 0) == (fhi < 0) && return NaN  # price outside attainable range
    for _ in 1:200
        mid = (lo + hi) / 2
        (f(mid) < 0) == (flo < 0) ? (lo = mid; flo = f(mid)) : (hi = mid)
        hi - lo < 1e-12 && break
    end
    return (lo + hi) / 2
end
