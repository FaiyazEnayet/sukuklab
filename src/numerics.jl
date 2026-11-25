"""
Reliable root solving for yield inversion and curve calibration.

Two yield solvers used to return NaN for a mathematical root
outside their hard-coded bracket, and the curve solver returned a
midpoint with no signal when it ran out of iterations. This file
is the shared core both paths now run on:

- `YieldSolveResult` reports the outcome of a solve: whether it
  converged, the yield, the absolute and relative residual at the
  returned yield, the final bracket, and the iteration and
  evaluation counts. A missing root, a failure to converge and a
  precision limit are distinct statuses, not a bare NaN.
- `_solve_decreasing` brackets a strictly decreasing function
  adaptively inside its valid domain and then narrows the bracket
  with safeguarded Newton steps (analytic derivative where one is
  supplied) falling back to bisection, so the bracket always
  contains the root and every step makes progress.
- The `YieldNoRootError`, `YieldNoConvergenceError` and
  `YieldPrecisionLimitError` types carry the same failures as
  exceptions for the internal curve solver, whose callers already
  work in try/catch. Invalid input stays an `ArgumentError`,
  as everywhere else in the library.
- `reference_sukuk_price`, `reference_sukuk_ytm`,
  `reference_price` and `reference_ytm` are BigFloat reference
  calculations, implemented as direct sums and bisection in
  BigFloat, independent of the Float64 closed forms and solvers.
  They live outside the fast hot path: the pricing functions never
  call them, and they exist so difficult fixtures can be checked
  against a second implementation rather than against the code
  under test.
"""

"""
    YieldSolveResult(status, yield, abs_residual, rel_residual, bracket, iterations, evaluations)

The outcome of a yield solve. `status` is one of:

- `:converged`: `yield` solves the equation; `abs_residual` and
  `rel_residual` are the residual at that yield, in price units
  and relative to the target price.
- `:no_root`: no root exists for the target (for positive cash
  flows, a non-positive or non-finite target). `yield` is NaN.
- `:no_convergence`: the iteration budget ran out first. `yield`
  is the midpoint of the final bracket, a best available estimate
  that must not be used as a solve.
- `:precision_limit`: the bracket narrowed to one floating-point
  step while the residual stayed above tolerance, so no further
  progress is possible in Float64. `yield` is the bracket end
  with the smaller residual.

`bracket` is the final `(lo, hi)` the solve ended with,
`iterations` counts solve-loop steps (not bracketing), and
`evaluations` counts function evaluations.
"""
struct YieldSolveResult
    status::Symbol
    yield::Float64
    abs_residual::Float64
    rel_residual::Float64
    bracket::Tuple{Float64,Float64}
    iterations::Int
    evaluations::Int
end

"""
    YieldNoRootError(msg, bracket)

The function to invert has no sign change on its valid domain,
so there is no root to find. Carries the final bracket probed.
"""
struct YieldNoRootError <: Exception
    msg::String
    bracket::Tuple{Float64,Float64}
end

Base.showerror(io::IO, err::YieldNoRootError) =
    print(io, "YieldNoRootError: ", err.msg)

"""
    YieldNoConvergenceError(msg, bracket, residual)

The solver ran out of iterations before meeting tolerance.
Carries the final bracket and the residual at its midpoint.
"""
struct YieldNoConvergenceError <: Exception
    msg::String
    bracket::Tuple{Float64,Float64}
    residual::Float64
end

Base.showerror(io::IO, err::YieldNoConvergenceError) =
    print(io, "YieldNoConvergenceError: ", err.msg)

"""
    YieldPrecisionLimitError(msg, bracket, residual)

The bracket narrowed to one floating-point step while the
residual stayed above tolerance, so the solve cannot progress
further in Float64. Carries the final bracket and the smallest
residual reached.
"""
struct YieldPrecisionLimitError <: Exception
    msg::String
    bracket::Tuple{Float64,Float64}
    residual::Float64
end

Base.showerror(io::IO, err::YieldPrecisionLimitError) =
    print(io, "YieldPrecisionLimitError: ", err.msg)

# Relative residual scale: residuals are reported against the
# target price, floored at 1 so a small target does not inflate
# the relative figure.
_rel_residual(abs_residual, target) =
    abs_residual / max(1.0, abs(target))

"""
    _solve_decreasing(f, df, target; domain_lo, domain_hi=Inf, lo, hi, ftol, xtol=1e-12, maxiter=200)

Solve `f(y) = 0` for a strictly decreasing `f` (the price minus
its target), returning a `YieldSolveResult`. `df` is the analytic
derivative of `f`, or `nothing` for pure bisection. The bracket
starts at `(lo, hi)` and expands until `f(lo) > 0 > f(hi)`:
toward `domain_lo` it halves the distance to the boundary (never
crossing it), toward `domain_hi` it doubles the width the same
way, and on an unbounded side it doubles the interval. A root is
then narrowed by safeguarded Newton steps when `df` is supplied
(a Newton step is taken only when it lands strictly inside the
bracket and is finite, otherwise the midpoint is used), so the
bracket always contains the root.

Convergence is declared when the residual at the probed point is
at most `ftol`, or when the bracket width reaches `xtol` (the
yield is then accurate to `xtol`, and the residual at the returned
midpoint is reported as it stands). When the midpoint stops
moving in floating point before either tolerance is met, the
result is `:precision_limit`; when `maxiter` steps pass without
convergence it is `:no_convergence`; when no sign change is found
it is `:no_root`. A function value of `+Inf` or `-Inf` is a usable
sign (an overflowed price is still above its target); a NaN
evaluation is a precision limit, since the function has lost
meaning at that point.
"""
function _solve_decreasing(f, df, target;
                           domain_lo::Float64, domain_hi::Float64=Inf,
                           lo::Float64, hi::Float64,
                           ftol::Float64, xtol::Float64=1e-12,
                           maxiter::Int=200)
    evaluations = 0
    # Local evaluation wrapper so the count covers every probe.
    function evalf(x)
        evaluations += 1
        return f(x)
    end
    function precision_limit(y, residual)
        return YieldSolveResult(:precision_limit, y, residual,
                                _rel_residual(residual, target),
                                (lo, hi), 0, evaluations)
    end

    flo = evalf(lo)
    fhi = evalf(hi)
    if isnan(flo) || isnan(fhi)
        return precision_limit((lo + hi) / 2, NaN)
    end
    flo == 0 && return YieldSolveResult(:converged, lo, 0.0, 0.0,
                                        (lo, hi), 0, evaluations)
    fhi == 0 && return YieldSolveResult(:converged, hi, 0.0, 0.0,
                                        (lo, hi), 0, evaluations)

    # Expand the bracket until it straddles the root. Each side
    # moves only while its sign is wrong, and at most 200 steps:
    # a genuine root for a positive price is found in a handful,
    # and the cap keeps a rootless function from expanding forever.
    # A step that cannot move its end in floating point (the end is
    # already one float step from the boundary) stops the expansion
    # instead of re-probing the same point.
    expansions = 0
    while !(flo > 0 && fhi < 0) && expansions < 200
        if flo <= 0
            if isfinite(domain_lo)
                lo == domain_lo && break
                new_lo = domain_lo + (lo - domain_lo) / 2
                (new_lo == lo || new_lo == domain_lo) && break
                lo = new_lo
            else
                lo -= (hi - lo)
            end
            flo = evalf(lo)
            isnan(flo) && return precision_limit(lo, NaN)
            flo == 0 && return YieldSolveResult(:converged, lo, 0.0,
                                                0.0, (lo, hi), 0,
                                                evaluations)
        end
        if fhi >= 0
            if isfinite(domain_hi)
                hi == domain_hi && break
                new_hi = domain_hi - (domain_hi - hi) / 2
                (new_hi == hi || new_hi == domain_hi) && break
                hi = new_hi
            else
                hi += (hi - lo)
            end
            fhi = evalf(hi)
            isnan(fhi) && return precision_limit(hi, NaN)
            fhi == 0 && return YieldSolveResult(:converged, hi, 0.0,
                                                0.0, (lo, hi), 0,
                                                evaluations)
        end
        expansions += 1
    end
    if !(flo > 0 && fhi < 0)
        return YieldSolveResult(:no_root, NaN, NaN, NaN, (lo, hi),
                                0, evaluations)
    end

    iterations = 0
    while iterations < maxiter
        mid = (lo + hi) / 2
        if !(lo < mid < hi)
            # The bracket cannot narrow further in floating point.
            # Report the end with the smaller residual.
            if abs(flo) <= abs(fhi)
                return YieldSolveResult(:precision_limit, lo, abs(flo),
                                        _rel_residual(abs(flo), target),
                                        (lo, hi), iterations, evaluations)
            else
                return YieldSolveResult(:precision_limit, hi, abs(fhi),
                                        _rel_residual(abs(fhi), target),
                                        (lo, hi), iterations, evaluations)
            end
        end
        fmid = evalf(mid)
        isnan(fmid) && return YieldSolveResult(
            :precision_limit, mid, NaN, NaN, (lo, hi), iterations,
            evaluations)
        if abs(fmid) <= ftol
            return YieldSolveResult(:converged, mid, abs(fmid),
                                    _rel_residual(abs(fmid), target),
                                    (lo, hi), iterations + 1, evaluations)
        end
        # Safeguarded Newton step from the midpoint: taken only
        # when it lands strictly inside the bracket and is finite.
        candidate = mid
        if df !== nothing
            d = df(mid)
            if isfinite(d) && d != 0
                y_new = mid - fmid / d
                if isfinite(y_new) && lo < y_new < hi
                    candidate = y_new
                end
            end
        end
        if candidate == mid
            if fmid > 0
                lo, flo = mid, fmid
            else
                hi, fhi = mid, fmid
            end
        else
            fc = evalf(candidate)
            isnan(fc) && return YieldSolveResult(
                :precision_limit, candidate, NaN, NaN, (lo, hi),
                iterations + 1, evaluations)
            if abs(fc) <= ftol
                return YieldSolveResult(:converged, candidate, abs(fc),
                                        _rel_residual(abs(fc), target),
                                        (lo, hi), iterations + 1,
                                        evaluations)
            end
            if fc > 0
                lo, flo = candidate, fc
            else
                hi, fhi = candidate, fc
            end
        end
        iterations += 1
        if hi - lo <= xtol
            ym = (lo + hi) / 2
            fm = evalf(ym)
            isnan(fm) && return YieldSolveResult(
                :precision_limit, ym, NaN, NaN, (lo, hi), iterations,
                evaluations)
            return YieldSolveResult(:converged, ym, abs(fm),
                                    _rel_residual(abs(fm), target),
                                    (lo, hi), iterations, evaluations)
        end
    end
    ym = (lo + hi) / 2
    fm = evalf(ym)
    if isnan(fm)
        return YieldSolveResult(:precision_limit, ym, NaN, NaN,
                                (lo, hi), iterations, evaluations)
    end
    return YieldSolveResult(:no_convergence, ym, abs(fm),
                            _rel_residual(abs(fm), target),
                            (lo, hi), iterations, evaluations)
end

# ---------------------------------------------------------------------------
# BigFloat reference calculations.
#
# Direct per-period sums and bisection in BigFloat, written
# independently of the Float64 closed forms and solvers above.
# The bisection runs a fixed 400 iterations with a stop when the
# midpoint stops moving, which is far past the point where the
# BigFloat bracket is narrower than any Float64 tolerance.
# ---------------------------------------------------------------------------

function _reference_bisect(f, lo::BigFloat, hi::BigFloat,
                           domain_lo::BigFloat, target::BigFloat)
    flo = f(lo)
    fhi = f(hi)
    expansions = 0
    while !(flo > 0 && fhi < 0) && expansions < 200
        if flo <= 0
            lo = domain_lo + (lo - domain_lo) / 2
            flo = f(lo)
        end
        if fhi >= 0
            hi += (hi - lo)
            fhi = f(hi)
        end
        expansions += 1
    end
    (flo > 0 && fhi < 0) ||
        throw(ArgumentError("reference solve found no root"))
    for _ in 1:400
        mid = (lo + hi) / 2
        (lo < mid < hi) || return mid
        fmid = f(mid)
        abs(fmid) <= big(10)^-30 * max(one(BigFloat), abs(target)) &&
            return mid
        if fmid > 0
            lo = mid
        else
            hi = mid
        end
    end
    return (lo + hi) / 2
end

"""
    reference_sukuk_price(face, profit_rate, y, T; m=2) -> BigFloat

Price of a fixed-profit-rate sukuk in BigFloat, by direct
per-period summation (not the closed-form geometric sum the
Float64 pricer uses): each distribution discounted on its own,
plus the principal at maturity. The two formulas agree to
Float64 rounding on ordinary inputs and diverge only where the
closed form loses precision, which is the point of having both.
"""
function reference_sukuk_price(face, profit_rate, y, T; m=2)
    face, profit_rate, y, T = big(face), big(profit_rate), big(y),
        big(T)
    face <= 0 && throw(ArgumentError("face must be positive"))
    T <= 0 && throw(ArgumentError("T must be positive"))
    mm = BigFloat(m)
    (mm >= 1 && mm == round(mm)) ||
        throw(ArgumentError("m must be a positive whole number of " *
                            "distributions per year"))
    y <= -mm && throw(ArgumentError(
        "yield must be above -$m (the yield at which 1 + yield/m " *
        "hits zero)"))
    periods = mm * T
    abs(periods - round(periods)) > big(10)^-9 &&
        throw(ArgumentError("T = $T years at m = $(Int(mm)) " *
                            "distributions per year is not a whole " *
                            "number of periods"))
    n = round(Int, periods)
    c = face * profit_rate / mm
    df = 1 / (1 + y / mm)
    total = zero(BigFloat)
    term = df
    for _ in 1:n
        total += c * term
        term *= df
    end
    return total + face * df^n
end

"""
    reference_sukuk_ytm(face, profit_rate, price, T; m=2) -> BigFloat

Yield implied by `price` in BigFloat, by bisection on
`reference_sukuk_price` over the valid domain (yield above -m).
"""
function reference_sukuk_ytm(face, profit_rate, price, T; m=2)
    price = big(price)
    (isfinite(price) && price > 0) ||
        throw(ArgumentError("price must be positive and finite"))
    mm = BigFloat(m)
    f = y -> reference_sukuk_price(face, profit_rate, y, T; m=m) - price
    return _reference_bisect(f, parse(BigFloat, "-0.99"), parse(BigFloat, "5.0"), -mm, price)
end

"""
    reference_price(times, amounts, y; m=2) -> BigFloat

Present value of cash flows at nominal annual yield `y`
(compounded `m` times) in BigFloat, by direct summation over the
flat `(times, amounts)` layout: each amount discounted by
`(1 + y/m)^(-m*t)`. Year fractions are taken as given, so the
reference checks the solver, not the calendar.
"""
function reference_price(times::Vector{Float64},
                         amounts::Vector{Float64}, y; m::Int=2)
    length(times) == length(amounts) ||
        throw(ArgumentError("times and amounts must match in length"))
    m < 1 && throw(ArgumentError("m must be a positive integer"))
    yp = big(y) / BigFloat(m)
    yp <= -1 && throw(ArgumentError(
        "yield must be above -$m (the yield at which 1 + yield/m " *
        "hits zero)"))
    total = zero(BigFloat)
    for (t, a) in zip(times, amounts)
        total += big(a) / (1 + yp)^(BigFloat(m) * big(t))
    end
    return total
end

"""
    reference_ytm(times, amounts, price; m=2) -> BigFloat

Yield implied by `price` for the flat `(times, amounts)` cash
flows in BigFloat, by bisection on `reference_price` over the
valid domain (yield above -m).
"""
function reference_ytm(times::Vector{Float64},
                       amounts::Vector{Float64}, price; m::Int=2)
    price = big(price)
    (isfinite(price) && price > 0) ||
        throw(ArgumentError("price must be positive and finite"))
    m < 1 && throw(ArgumentError("m must be a positive integer"))
    f = y -> reference_price(times, amounts, y; m=m) - price
    return _reference_bisect(f, parse(BigFloat, "-0.99"), parse(BigFloat, "5.0"), -BigFloat(m), price)
end
