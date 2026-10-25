#!/usr/bin/env python3
"""Build a synthetic bar snapshot for the backtester benchmarks.

    python3 -I tools/synth_bars.py --out DIR --instruments 100 --period 1h \
        --from 2023-10-01 --days 1096 --seed 1

Each instrument follows its own geometric random walk (seeded, so the output
is byte-identical for the same arguments): daily volatility 4 %, no drift,
starting at 100 USDT. A bar opens at the previous close; high and low bracket
open and close. Units match the Binance snapshots: cash unit 1e-8 USDT, tick
0.01, lot 0.001, so mult is 1000; min notional 5 USDT. Output, like
fetch_binance_klines.py:

    bars.csv         ts,sym,o,h,l,c,v   prices in ticks
    instruments.csv  sym,mult,min_qty,min_notional,tick,lot
    snapshot.json    the arguments and assumptions
    SHA256SUMS       of the three files above

Synthetic prices only measure cost; they carry no market structure.
"""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import random

PERIODS = {"1d": dt.timedelta(days=1), "1h": dt.timedelta(hours=1)}
DAILY_VOL = 0.04
START_TICKS = 10_000  # 100 USDT at a 0.01 tick


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--instruments", type=int, required=True)
    ap.add_argument("--period", choices=sorted(PERIODS), required=True)
    ap.add_argument("--from", dest="first", required=True)
    ap.add_argument("--days", type=int, required=True)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    step = PERIODS[a.period]
    per_day = dt.timedelta(days=1) // step
    nbars = a.days * per_day
    sigma = DAILY_VOL / math.sqrt(per_day)
    start = dt.datetime.strptime(a.first, "%Y-%m-%d")
    syms = [f"S{i:04d}" for i in range(a.instruments)]
    rngs = [random.Random(a.seed * 1_000_003 + i) for i in range(a.instruments)]
    last = [START_TICKS] * a.instruments

    with open(os.path.join(a.out, "bars.csv"), "w") as f:
        f.write("ts,sym,o,h,l,c,v\n")
        for k in range(nbars):
            ts = (start + k * step).strftime("%Y-%m-%dT%H:%M:%S.000")
            for i, sym in enumerate(syms):
                r = rngs[i]
                o = last[i]
                c = max(1, round(o * math.exp(r.gauss(0.0, sigma))))
                h = max(o, c) + round(abs(r.gauss(0.0, sigma)) * o / 2)
                l = max(1, min(o, c) - round(abs(r.gauss(0.0, sigma)) * o / 2))
                f.write(f"{ts},{sym},{o},{h},{l},{c},100000000\n")
                last[i] = c

    with open(os.path.join(a.out, "instruments.csv"), "w") as f:
        f.write("sym,mult,min_qty,min_notional,tick,lot\n")
        for sym in syms:
            f.write(f"{sym},1000,1,500000000,0.01,0.001\n")

    with open(os.path.join(a.out, "snapshot.json"), "w") as f:
        json.dump({"source": "synthetic (tools/synth_bars.py)",
                   "instruments": a.instruments, "period": a.period,
                   "first_bar": a.first, "days": a.days, "bars_per_instrument": nbars,
                   "seed": a.seed, "daily_vol": DAILY_VOL,
                   "assumptions": ["geometric random walk per instrument, no drift",
                                   "for cost measurement only"]},
                  f, indent=1, sort_keys=True)
        f.write("\n")

    with open(os.path.join(a.out, "SHA256SUMS"), "w") as f:
        for name in ("bars.csv", "instruments.csv", "snapshot.json"):
            with open(os.path.join(a.out, name), "rb") as g:
                f.write(f"{hashlib.sha256(g.read()).hexdigest()}  {name}\n")


if __name__ == "__main__":
    main()
