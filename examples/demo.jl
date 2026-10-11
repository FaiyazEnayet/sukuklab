# SukukLab demo: sukuk and fixed-income analytics on real published terms.
#
# Real inputs used here, both public:
# 1. IILM short-term sukuk auction, January 2026 (reported 2026-01-13).
#    Clearing profit rates: 1m 3.81%, 3m 3.84%, 6m 3.82%, 12m 3.45%.
#    Full record in data/iilm_2026-01.json.
# 2. UAE sovereign retail T-Sukuk, second tranche: 5-year, 5.06% annual
#    profit rate, semi-annual distributions, issued 2026-09-30, matures
#    2031-09-30 (Nasdaq Dubai listing reports, October 2026).
#
# The three-holding portfolio at the end is illustrative and labeled so.

using Dates
using SukukLab

println("== 1. Short-end profit-rate curve from the IILM auction ==")
anchor = Date(2026, 1, 13)
# (months, clearing profit rate); treated as simple annualized discount
# rates, Actual/365. See data/iilm_2026-01.json.
iilm = [(1, 0.0381), (3, 0.0384), (6, 0.0382), (12, 0.0345)]
instruments = Tuple{Vector{CashFlow},Float64}[]
for (months, r) in iilm
    mat = anchor + Month(months)
    T = yearfrac(anchor, mat, :actual_365)
    price = 100.0 / (1 + r * T)
    push!(instruments, ([CashFlow(mat, 100.0)], price))
end
curve = bootstrap(instruments, anchor)
for (t, z) in zip(curve.pillars, curve.zeros)
    println("  T=$(round(t; digits=4))y  zero=$(round(100z; digits=4))%")
end
# The curve must reprice its own inputs.
for ((cfs, price), (t, z)) in zip(sort(instruments, by=x -> x[1][end].date),
                                  zip(curve.pillars, curve.zeros))
    repriced = sum(cf.amount * discount(curve, cf.date) for cf in cfs)
    @assert abs(repriced - price) < 1e-9
end
println("  reprice check: all four auction points recovered exactly")
println("  6m/12m forward rate: ",
        round(100 * forward_rate(curve, 0.5, 1.0); digits=4), "%")

println("\n== 2. UAE retail sukuk: schedule and risk from real terms ==")
uae = SukukTerms("UAE retail T-Sukuk 2031", 1000.0, 0.0506,
                 Date(2026, 9, 30), Date(2031, 9, 30), 2, "ijara")
cfs = payment_schedule(uae)
println("  $(length(cfs)) cash flows; first dist ",
        round(cfs[1].amount; digits=2), ", final ",
        round(cfs[end].amount; digits=2))
settle = Date(2026, 10, 10)
y = ytm_from_price(cfs, 1000.0, settle)
println("  YTM at par: ", round(100y; digits=4), "%")
println("  current yield at par: ",
        round(100 * current_yield(1000 * 0.0506, 1000.0); digits=4), "%")
println("  Macaulay duration: ", round(macaulay_duration(cfs, y, settle); digits=4), "y")
println("  modified duration: ", round(modified_duration(cfs, y, settle); digits=4), "y")
println("  convexity: ", round(convexity(cfs, y, settle); digits=4))
println("  DV01 per 1000 face: ", round(dv01(cfs, y, settle); digits=4))
p_up = price_under_shift(cfs, y, 100, settle)
println("  price after +100bp parallel shift: ", round(p_up; digits=2))
println("  accrued profit at settlement: ",
        round(accrued_profit(uae, settle); digits=2))

println("\n== 3. Illustrative three-sukuk portfolio (synthetic) ==")
mk(terms, price, qty, sdate) = begin
    sc = remaining_cashflows(payment_schedule(terms), sdate)
    yy = ytm_from_price(sc, price, sdate)
    Holding(terms.name, price * qty, yy,
            modified_duration(sc, yy, sdate), convexity(sc, yy, sdate))
end
a = SukukTerms("Illustrative 3y 4.5%", 1000.0, 0.045,
               Date(2026, 1, 15), Date(2029, 1, 15), 2, "wakala")
b = SukukTerms("Illustrative 5y 5.0%", 1000.0, 0.050,
               Date(2026, 1, 15), Date(2031, 1, 15), 2, "ijara")
c = SukukTerms("Illustrative 7y 5.25% murabaha", 1000.0, 0.0525,
               Date(2026, 1, 15), Date(2033, 1, 15), 2, "murabaha";
               amortizing=true)
holdings = [mk(a, 990.0, 50, settle), mk(b, 1010.0, 30, settle),
            mk(c, 1000.0, 20, settle)]
println("  portfolio value: ", round(portfolio_value(holdings); digits=2))
println("  weighted YTM: ", round(100 * weighted_ytm(holdings); digits=4), "%")
println("  weighted duration: ",
        round(weighted_duration(holdings); digits=4), "y")
println("  weighted convexity: ",
        round(weighted_convexity(holdings); digits=4))
println("\ndone.")
