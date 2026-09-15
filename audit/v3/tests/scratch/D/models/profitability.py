"""WS-D profitability sweep for Cap v2 liquidations.

Liquidator burns `repaid` cUSD (face value) and receives collateral worth repaid*(1+b) at the
ORACLE price. With market/oracle deviation d (oracle = market*(1+d)) and cUSD acquisition cost c
(USD per cUSD), the margin per cUSD repaid is  m = (1+b)/(1+d) - c.

Size: maxLiquidatable/debt = min(1, (T-h)/(T-(1+b)*lt), h/((1+b)*lt)); the recoverableDebt cap
binds iff h <= (1+b)*lt (equivalently unrecoverableDebt > 0), at which point repaid = TC/(1+b)
and every tranche is drained.
"""
T, LT, B0 = 1.25, 0.8, 0.02

def size(h, b=B0, T=T, lt=LT):
    if h >= 1: return 0.0, False
    formula = (T - h) / (T - (1 + b) * lt)
    cap = h / ((1 + b) * lt)
    return min(1.0, formula, cap), cap <= formula

print("## Table 1: fraction of debt liquidated per call and whether the recoverableDebt cap binds (b=2%)")
print("| health | maxLiquidatable/debt | cap binds (drains all collateral) | remainder -> writeOff (per $1 debt) |")
print("|---|---|---|---|")
for h in [0.999, 0.95, 0.9, 0.85, 0.82, 0.816, 0.8, 0.75, 0.7, 0.6, 0.5]:
    s, binds = size(h)
    # remainder = debt - recoverable = 1 - h/((1+b)lt) per $1 of debt when it binds
    rem = max(0.0, 1 - h / ((1 + B0) * LT)) if binds else 0.0
    print(f"| {h:.3f} | {s*100:6.2f}% | {'yes' if binds else 'no'} | {rem:.4f} |")

print()
print("## Table 2: margin per cUSD repaid, m = (1+b)/(1+d) - c   (positive = profitable, before gas and dust)")
for c in [1.00, 0.98, 0.95]:
    print(f"\n### cUSD acquired at ${c:.2f}")
    devs = [-0.05, -0.02, -0.01, 0.0, 0.005, 0.01, 0.02, 0.03, 0.05]
    print("| bonus \\ oracle-vs-market | " + " | ".join(f"{d*100:+.1f}%" for d in devs) + " |")
    print("|---|" + "---|" * len(devs))
    for b in [0.0, 0.01, 0.02, 0.05, 0.10]:
        row = []
        for d in devs:
            m = (1 + b) / (1 + d) - c
            row.append(f"{m*100:+.2f}%")
        print(f"| b={b*100:.0f}% | " + " | ".join(row) + " |")

print()
print("## Table 3: break-even oracle overstatement d* = (1+b)/c - 1 (liquidation unprofitable for d > d*)")
print("| bonus | c=1.00 | c=0.98 | c=0.95 |")
print("|---|---|---|---|")
for b in [0.0, 0.01, 0.02, 0.05, 0.10]:
    print(f"| {b*100:.0f}% | " + " | ".join(f"{((1+b)/c-1)*100:+.2f}%" for c in [1.0, 0.98, 0.95]) + " |")

print()
print("## Table 4: dollars, deploy params, TC0 = $1,000,000, debt = $500,000 (ltv 0.5), price falls to p")
print("| price | TC | health | repaid | collateral received (USD @oracle) | liquidator gross (b) | writeOff remainder |")
print("|---|---|---|---|---|---|---|")
D = 500_000
for p in [0.65, 0.62, 0.6, 0.55, 0.52, 0.51, 0.5, 0.45, 0.4, 0.3, 0.2, 0.1]:
    TC = 1_000_000 * p
    h = TC * LT / D
    s, binds = size(h)
    repaid = s * D
    recv = repaid * (1 + B0)
    rem = max(0.0, D - TC / (1 + B0)) if binds else 0.0
    print(f"| {p:.2f} | {TC:,.0f} | {h:.3f} | {repaid:,.0f} | {recv:,.0f} | {recv-repaid:,.0f} | {rem:,.0f} |")
