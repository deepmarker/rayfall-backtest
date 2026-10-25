#!/usr/bin/env python3
"""Build a daily-bar snapshot for the Rayfall backtester from the Binance
public kline archive (data.binance.vision, spot, monthly 1d files).

    python3 -I tools/fetch_binance_klines.py --cache DIR --out DIR \
        --from 2023-10 --to 2026-09 BTCUSDT ETHUSDT SOLUSDT

Every zip is checked against the archive's published SHA-256. Rows are
validated, never repaired: a gap, an off-grid timestamp, a price that is not
a whole number of ticks, or an inconsistent OHLC raises. Output (see
doc/contracts.md for units):

    bars.csv         ts,sym,o,h,l,c,v   prices in ticks, volume in VOL_UNIT of base
    instruments.csv  sym,mult,min_qty,min_notional,tick,lot
    snapshot.json    sources with checksums, range, and metadata assumptions
    SHA256SUMS       of the three files above
"""

import argparse
import csv
import datetime as dt
import hashlib
import io
import json
import os
import sys
import urllib.request
import zipfile
from decimal import Decimal

BASE = "https://data.binance.vision/data/spot/monthly/klines"

# Cash unit of the accounting currency (USDT).
CASH_UNIT = Decimal("0.00000001")

# Exchange filters from GET /api/v3/exchangeInfo, fetched 2026-10-13. Binance
# has changed these over time; the snapshot records them as an assumption, and
# tick integrality of every historical price is checked below. TRXUSDT is
# absent for that reason: its 2023 prices are finer than today's 0.0001 tick,
# and the finer tick would make lot x tick a fraction of the cash unit.
META = {
    "ADAUSDT":  {"tick": Decimal("0.0001"), "lot": Decimal("0.1"), "min_notional": Decimal("5")},
    "AVAXUSDT": {"tick": Decimal("0.001"), "lot": Decimal("0.01"), "min_notional": Decimal("5")},
    "BCHUSDT":  {"tick": Decimal("0.1"), "lot": Decimal("0.001"), "min_notional": Decimal("5")},
    "BNBUSDT":  {"tick": Decimal("0.01"), "lot": Decimal("0.001"), "min_notional": Decimal("5")},
    "BTCUSDT":  {"tick": Decimal("0.01"), "lot": Decimal("0.00001"), "min_notional": Decimal("5")},
    "DOGEUSDT": {"tick": Decimal("0.00001"), "lot": Decimal("1"), "min_notional": Decimal("1")},
    "DOTUSDT":  {"tick": Decimal("0.001"), "lot": Decimal("0.01"), "min_notional": Decimal("5")},
    "ETHUSDT":  {"tick": Decimal("0.01"), "lot": Decimal("0.0001"), "min_notional": Decimal("5")},
    "LINKUSDT": {"tick": Decimal("0.001"), "lot": Decimal("0.01"), "min_notional": Decimal("5")},
    "LTCUSDT":  {"tick": Decimal("0.01"), "lot": Decimal("0.001"), "min_notional": Decimal("5")},
    "SOLUSDT":  {"tick": Decimal("0.01"), "lot": Decimal("0.001"), "min_notional": Decimal("5")},
    "XRPUSDT":  {"tick": Decimal("0.0001"), "lot": Decimal("0.1"), "min_notional": Decimal("5")},
}

# Volume is reported to 1e-8 of the base asset, finer than the lot size, so
# it is kept in this unit rather than in lots. It is informational only.
VOL_UNIT = Decimal("0.00000001")

DAY_MS = 86_400_000


def months(first, last):
    y, m = map(int, first.split("-"))
    ly, lm = map(int, last.split("-"))
    while (y, m) <= (ly, lm):
        yield f"{y:04d}-{m:02d}"
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def cached(cache, sym, month):
    """Return (zip bytes, sha256) for one monthly file, verified."""
    name = f"{sym}-1d-{month}.zip"
    url = f"{BASE}/{sym}/1d/{name}"
    path = os.path.join(cache, name)
    if not os.path.exists(path):
        data = fetch(url)
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
    with open(path, "rb") as f:
        data = f.read()
    digest = hashlib.sha256(data).hexdigest()
    expected = fetch(url + ".CHECKSUM").decode().split()[0]
    if digest != expected:
        raise SystemExit(f"{name}: sha256 {digest} != published {expected}")
    return url, data, digest


def ticks(value, unit, what):
    q = Decimal(value) / unit
    if q != q.to_integral_value():
        raise SystemExit(f"{what}: {value} is not a whole number of {unit}")
    return int(q)


def to_ms(raw):
    """Binance spot switched kline timestamps from ms to µs on 2025-01-01."""
    t = int(raw)
    return t // 1000 if t >= 10**15 else t


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--from", dest="first", required=True)
    ap.add_argument("--to", dest="last", required=True)
    ap.add_argument("syms", nargs="+")
    a = ap.parse_args()
    os.makedirs(a.cache, exist_ok=True)
    os.makedirs(a.out, exist_ok=True)

    start = dt.datetime.strptime(a.first, "%Y-%m").replace(tzinfo=dt.timezone.utc)
    ly, lm = map(int, a.last.split("-"))
    end = dt.datetime(ly + (lm == 12), lm % 12 + 1, 1, tzinfo=dt.timezone.utc)
    start_ms = int(start.timestamp() * 1000)
    ndays = (end - start).days

    rows, sources = [], []
    for sym in sorted(a.syms):
        meta = META[sym]
        seen = {}
        for month in months(a.first, a.last):
            url, data, digest = cached(a.cache, sym, month)
            sources.append({"url": url, "sha256": digest})
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                (member,) = z.namelist()
                text = z.read(member).decode()
            for rec in csv.reader(io.StringIO(text)):
                open_ms, close_ms = to_ms(rec[0]), to_ms(rec[6])
                what = f"{sym} {open_ms}"
                if (open_ms - start_ms) % DAY_MS or close_ms != open_ms + DAY_MS - 1:
                    raise SystemExit(f"{what}: not a whole UTC day")
                if open_ms in seen:
                    raise SystemExit(f"{what}: duplicate day")
                o, h, l, c = (ticks(x, meta["tick"], what) for x in rec[1:5])
                v = ticks(rec[5], VOL_UNIT, what)
                if min(o, h, l, c) <= 0 or h < max(o, c) or l > min(o, c):
                    raise SystemExit(f"{what}: inconsistent OHLC {o} {h} {l} {c}")
                seen[open_ms] = (o, h, l, c, v)
        expected = {start_ms + i * DAY_MS for i in range(ndays)}
        if set(seen) != expected:
            missing = sorted(expected - set(seen))[:5]
            extra = sorted(set(seen) - expected)[:5]
            raise SystemExit(f"{sym}: day set mismatch, missing {missing} extra {extra}")
        for t in sorted(seen):
            ts = dt.datetime.fromtimestamp(t / 1000, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000")
            rows.append((ts, sym) + seen[t])

    rows.sort(key=lambda r: (r[0], r[1]))
    with open(os.path.join(a.out, "bars.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["ts", "sym", "o", "h", "l", "c", "v"])
        w.writerows(rows)

    instruments = []
    with open(os.path.join(a.out, "instruments.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["sym", "mult", "min_qty", "min_notional", "tick", "lot"])
        for sym in sorted(a.syms):
            m = META[sym]
            mult = ticks(m["tick"] * m["lot"], CASH_UNIT, f"{sym} mult")
            min_notional = ticks(m["min_notional"], CASH_UNIT, f"{sym} min_notional")
            w.writerow([sym, mult, 1, min_notional, str(m["tick"]), str(m["lot"])])
            instruments.append({"sym": sym, "tick": str(m["tick"]), "lot": str(m["lot"]),
                                "mult": mult, "min_notional_usdt": str(m["min_notional"])})

    snapshot = {
        "source": "Binance public archive, spot monthly 1d klines",
        "range": {"first_bar": start.strftime("%Y-%m-%d"), "end": end.strftime("%Y-%m-%d"),
                  "bars_per_instrument": ndays},
        "accounting": {"currency": "USDT", "cash_unit": str(CASH_UNIT)},
        "volume_unit": str(VOL_UNIT) + " of the base asset",
        "instruments": instruments,
        "assumptions": [
            "tick, lot and min notional are the exchange filters at fetch time, "
            "applied to the whole range; every historical price was checked to be "
            "a whole number of ticks",
            "bar ts is the UTC open of the day; the close is available at ts + 1d",
        ],
        "sources": sources,
    }
    with open(os.path.join(a.out, "snapshot.json"), "w") as f:
        json.dump(snapshot, f, indent=1, sort_keys=True)
        f.write("\n")

    with open(os.path.join(a.out, "SHA256SUMS"), "w") as f:
        for name in ("bars.csv", "instruments.csv", "snapshot.json"):
            with open(os.path.join(a.out, name), "rb") as g:
                f.write(f"{hashlib.sha256(g.read()).hexdigest()}  {name}\n")
    print(f"{len(rows)} bars, {len(a.syms)} instruments, {ndays} days -> {a.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
