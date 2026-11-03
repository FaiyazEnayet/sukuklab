"""Build the standalone dashboard from checked-in Julia evidence."""
import csv
import hashlib
import json
import math
from datetime import date
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    return json.loads((ROOT / path).read_text(encoding="utf-8"))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def plot(points, xticks, yticks, bounds, label, marker=None):
    xmin, xmax, ymin, ymax = bounds
    x = lambda n: 53 + 333 * (n - xmin) / (xmax - xmin)
    y = lambda n: 183 - 150 * (n - ymin) / (ymax - ymin)
    parts = [f'<svg viewBox="0 0 420 218" role="img" aria-label="{escape(label)}">']
    for value, caption in yticks:
        v = y(value)
        parts.append(f'<path class="gridline" d="M53 {v:.3f}H386"/><text x="47" y="{v+4:.3f}" text-anchor="end">{caption}</text>')
    for value, caption in xticks:
        v = x(value)
        parts.append(f'<path class="gridline" d="M{v:.3f} 33V183"/><text x="{v:.3f}" y="204" text-anchor="middle">{caption}</text>')
    coords = " ".join(f"{x(a):.3f},{y(b):.3f}" for a, b in points)
    parts.append(f'<polyline class="curve" points="{coords}"/>')
    if marker is None:
        parts.extend(f'<circle class="point" cx="{x(a):.3f}" cy="{y(b):.3f}" r="4"><title>{a:.6f} years · {b:.4f}%</title></circle>' for a, b in points)
    else:
        parts.append(f'<circle class="point" id="price-marker" cx="{x(marker[0]):.3f}" cy="{y(marker[1]):.3f}" r="5"/>')
    return "".join(parts) + "</svg>"


def main():
    data_path = "data/iilm_2026-01.json"
    auction = load(data_path)
    results = load("examples/results.json")
    residual = load("examples/iilm_residuals.json")
    fixture = load("test/fixtures/valuation_parity.json")["cases"]["uae_bullet"]
    digest = hashlib.sha256((ROOT / data_path).read_bytes()).hexdigest()
    require(digest == residual["data_file_sha256"] and residual["data_file"] == data_path, "Stale IILM residual artifact")
    instruments = auction["instruments"]
    rows = residual["instruments"]
    require(len(instruments) == len(rows) == len(results["pillar_years"]) == len(results["zero_rates"]), "IILM artifact lengths differ")
    require(auction["auction_date"] == residual["auction_date"] == results["iilm_auction_date"], "Auction dates differ")
    require(auction["rate_convention"] == residual["rate_convention"], "Rate conventions differ")
    anchor = results["iilm_anchor"]
    require(anchor == residual["curve_anchor_issue_date"], "Curve anchors differ")
    with (ROOT / "examples/iilm_residuals.csv").open(encoding="utf-8", newline="") as stream:
        csv_rows = list(csv.DictReader(stream))
    require(len(csv_rows) == len(rows), "Residual CSV length differs")
    ledger = []
    diagnostics = []
    for i, (series, row, csv_row) in enumerate(zip(instruments, rows, csv_rows)):
        require(all(series[k] == row[k] for k in ("series", "isin", "tenor_label", "profit_rate", "amount_usd_m", "issue_date", "maturity_date")), "Series metadata differ")
        require(all((float(csv_row[k]) if isinstance(v, (int, float)) else csv_row[k]) == v for k, v in row.items()), "Residual CSV and JSON differ")
        t = results["pillar_years"][i]
        z = results["zero_rates"][i]
        require(series["issue_date"] == anchor and (date.fromisoformat(series["maturity_date"]) - date.fromisoformat(anchor)).days / 365 == t == row["year_fraction"], "Dated pillar mismatch")
        require(series["series"] == results["iilm_series"][i] and series["isin"] == results["iilm_isins"][i] and series["maturity_date"] == results["iilm_maturities"][i] and series["profit_rate"] == results["iilm_rates"][i], "Canonical series mismatch")
        require(math.isclose(math.exp(-z*t)*residual["face"], row["curve_price_per_100"], abs_tol=1e-10) and abs(row["curve_price_per_100"]-row["model_price_per_100"]) == row["abs_residual_per_100"], "Invalid residual values")
        ledger.append((series["series"], series["isin"], series["tenor_label"], series["issue_date"], series["maturity_date"], f'{series["amount_usd_m"]:g}', f'{series["profit_rate"]:.2%}', f"{t:.6f}", f"{z:.4%}"))
        diagnostics.append((series["series"], f'{row["model_price_per_100"]:.8f}', f'{row["curve_price_per_100"]:.8f}', str(row["abs_residual_per_100"])))
    error = max(r["abs_residual_per_100"] for r in rows)
    require(error == residual["max_abs_residual_per_100"] == results["max_reprice_error"], "Calibration summary mismatch")
    settle = results["uae_settlement"]
    ytm = results["uae_ytm"]
    require(settle == fixture["anchor"] and len(fixture["cashflows"]) == results["uae_n_cashflows"], "Valuation fixture does not match results")
    full = next(check["price"] for check in fixture["ytm_checks"] if check["ytm"] == ytm)
    accrued = results["uae_accrued"]
    dated = [(amount, (date.fromisoformat(day)-date.fromisoformat(settle)).days / 365) for day, amount in fixture["cashflows"]]
    m = fixture["m"]

    def price(y):
        return sum(amount/(1+y/m)**(m*t) for amount, t in dated)

    require(math.isclose(price(ytm), full, abs_tol=1e-8), "Baseline full price mismatch")
    require(math.isclose(price(ytm+.01), results["uae_price_shift_100bp"], abs_tol=1e-8), "Shifted full price mismatch")
    points = list(zip(results["pillar_years"], [z*100 for z in results["zero_rates"]]))
    sweep = [(2+i/10, price((2+i/10)/100)) for i in range(71)]
    lo = math.floor(min(p for _, p in sweep)/50)*50
    hi = math.ceil(max(p for _, p in sweep)/50)*50

    def table(headers, body):
        return '<div class="table-wrap" tabindex="0" role="region" aria-label="Scrollable data table"><table><thead><tr>' + "".join(f'<th scope="col">{escape(h)}</th>' for h in headers) + "</tr></thead><tbody>" + "".join("<tr>"+"".join(f"<td>{escape(str(c))}</td>" for c in r)+"</tr>" for r in body) + "</tbody></table></div>"

    sources = "".join(f'<li><a href="{escape(s["url"], quote=True)}">{escape(s["name"])}</a><small>' + escape(" · ".join(f"{key.title()} {s[key]}" for key in ("published", "retrieved") if key in s)) + "</small></li>" for s in auction["sources"])
    quotes = "".join(f'<li><strong>{escape(r["series"])}</strong> <q>{escape(r["quote"])}</q><small>{escape(r["quote_source"])}</small></li>' for r in instruments)
    fonts = load("portfolio_ui/fonts.json")
    context = {
        "FONTS": fonts["Fraunces"] + fonts["IBM Plex Mono"],
        "AUCTION": escape(auction["auction_date"]), "ANCHOR": escape(anchor), "ISSUER": escape(auction["issuer"]),
        "AUCTION_NAME": escape(auction["auction"]), "REPORTED": escape(auction["reported"]), "SCHEMA": escape(auction["schema"]),
        "SHA": digest, "CONVENTION": escape(auction["rate_convention"]), "NOTE": escape(auction["rate_convention_note"]),
        "CURVE": plot(points, [(t,f"{t:.3f}") for t,_ in points], [(v,f"{v:.2f}") for v in (3.4,3.6,3.8)], (0,1.04,3.32,3.89), "Continuously compounded zero curve, with a falling final segment"),
        "FORWARD": f'{results["forward_6m_12m"]:.4%}',
        "LEDGER": table(("Series","ISIN","Tenor","Issued","Matures","USD m","Auction rate","Years","Zero rate"),ledger),
        "DIAGNOSTICS": table(("Series","Model price / 100","Curve price / 100","Absolute residual"),diagnostics),
        "ERROR": str(error), "STATUS": "Exact" if error == 0 else "Nonzero residual",
        "SOURCES": sources, "QUOTES": quotes,
        "SETTLE": settle, "UAE_ISSUE": fixture["issue"], "MATURITY": fixture["maturity"],
        "FACE": f'{fixture["face"]:,.0f}', "PROFIT": f'{fixture["profit_rate"]:.2%}',
        "FULL": f"{full:,.2f}", "ACCRUED": f"{accrued:.2f}", "CLEAN": f"{full-accrued:,.2f}",
        "YTM": f"{ytm:.3%}", "MAC": f'{results["uae_macaulay_duration"]:.4f}', "MOD": f'{results["uae_modified_duration"]:.4f}',
        "CONVEXITY": f'{results["uae_convexity"]:.4f}', "DV01": f'{results["uae_dv01"]:.4f}', "STRESS": f'{results["uae_price_shift_100bp"]:.2f}',
        "FLOWS": table(("Payment date","Amount"),[(day,f"{amount:,.2f}") for day,amount in fixture["cashflows"]]),
        "PRICE_CHART": plot(sweep, [(v,str(v)) for v in (2,3,4,5,6,7,8,9)],[(v,str(v)) for v in range(int(lo),int(hi)+1,100)], (2,9,lo,hi), "UAE full price versus nominal semiannual yield", (ytm*100,full)),
        "PAYLOAD": json.dumps(dict(auction=auction, results=results, residuals=residual, uae=fixture, dated=dated, full=full, bounds=[lo,hi]),separators=(",",":")).replace("<","\\u003c"),
    }
    import re
    template = (ROOT / "portfolio_ui/dashboard-template.html").read_text(encoding="utf-8")
    output = re.sub(r"@@([A-Z_0-9]+)@@", lambda m: context[m[1]], template)
    dest = ROOT / "docs/dashboard.html"
    dest.parent.mkdir(exist_ok=True)
    dest.write_bytes(output.encode("utf-8"))
    print(f"Wrote {dest.name} ({dest.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
