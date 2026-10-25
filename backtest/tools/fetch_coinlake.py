#!/usr/bin/env python3
"""Build a daily bar snapshot from Coinlake's Databento-compatible API.

The same snapshot layout as fetch_binance_klines.py, from a different source:
OHLCV bars and instrument definitions fetched with the databento client
(gateway set to Coinlake), kept as DBN files, and converted to the
backtester's CSV. Output (see doc/plan.md, "Databento data path"):

    <sym>.ohlcv-1d.dbn, definition.dbn   the fetched DBN, decompressed and pinned
    bars.csv         ts,sym,o,h,l,c,v   prices in ticks, volume in VOL_UNIT of base
    instruments.csv  sym,mult,min_qty,min_notional,tick,lot
    snapshot.json    gateway, dataset, requests, range and assumptions
    SHA256SUMS       every file above

Prices stay integers throughout: DBN carries them in units of 1e-9, each is
divided by the tick exactly, and one off the tick grid raises. The tick, lot
and minimum notional are the exchange filters fetch_binance_klines.py applies
(Coinlake's definitions carry the data's precision, not the order filters);
the definitions are fetched, pinned and checked against them: the tick must
be a whole multiple of min_price_increment.

Needs the databento package, DATABENTO_API_KEY and, for a self-signed
gateway, REQUESTS_CA_BUNDLE.
"""

import argparse
import csv
import hashlib
import importlib.util
import json
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal

import databento as db
import zstandard

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("klines", os.path.join(HERE, "fetch_binance_klines.py"))
klines = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(klines)
FILTERS, CASH_UNIT, VOL_UNIT = klines.META, klines.CASH_UNIT, klines.VOL_UNIT

NANO = Decimal("1e-9")
UNDEF_PRICE = 2**63 - 1


def ticks(nanos, unit, what):
    """nanos (an integer count of 1e-9) as a whole number of `unit`."""
    step = int(unit / NANO)
    if step <= 0 or unit != step * NANO:
        raise SystemExit(f"{what}: unit {unit} is not a whole number of 1e-9")
    if nanos % step:
        raise SystemExit(f"{what}: {nanos}e-9 is not a whole number of {unit}")
    return nanos // step


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--gateway", required=True)
    p.add_argument("--dataset", required=True, help="e.g. BIN.ARCHIVE")
    p.add_argument("--start", required=True, help="first day, YYYY-MM-DD")
    p.add_argument("--end", required=True, help="end day, exclusive, YYYY-MM-DD")
    p.add_argument("--out", required=True)
    p.add_argument("syms", nargs="+")
    a = p.parse_args()
    unknown = [s for s in a.syms if s not in FILTERS]
    if unknown:
        raise SystemExit(f"no exchange filters for {unknown} in fetch_binance_klines.META")
    os.makedirs(a.out)
    client = db.Historical(gateway=a.gateway)

    requests = []
    def fetch(name, **kw):
        # The stream arrives zstd-compressed, framed wherever the server
        # flushed it, so its bytes vary between two fetches of the same data:
        # the snapshot keeps and pins the DBN itself.
        path = os.path.join(a.out, name)
        client.timeseries.get_range(dataset=a.dataset, start=a.start, end=a.end, path=path + ".zst", **kw)
        with open(path + ".zst", "rb") as src, open(path, "wb") as dst:
            zstandard.ZstdDecompressor().copy_stream(src, dst)
        os.remove(path + ".zst")
        requests.append({"file": name, "dataset": a.dataset, "start": a.start, "end": a.end, **kw})
        return db.DBNStore.from_file(path)

    defs = fetch("definition.dbn", symbols=a.syms, schema="definition")
    tick_of = {}
    for d in defs:
        sym = d.raw_symbol
        tick = FILTERS[sym]["tick"]
        # The order tick must be a whole number of the data's price increment.
        ticks(int(tick / NANO), Decimal(d.min_price_increment) * NANO, f"{sym} tick vs min_price_increment")
        tick_of.setdefault(sym, set()).add(d.min_price_increment)
    missing = [s for s in a.syms if s not in tick_of]
    if missing:
        raise SystemExit(f"no definition for {missing}")

    rows = []
    for sym in a.syms:
        store = fetch(f"{sym}.ohlcv-1d.dbn", symbols=[sym], schema="ohlcv-1d")
        uom = [d.unit_of_measure_qty for d in defs if d.raw_symbol == sym]
        if len(set(uom)) != 1:
            raise SystemExit(f"{sym}: unit_of_measure_qty changes over the range ({sorted(set(uom))}); not handled")
        size_nanos = uom[0]
        for r in store:
            what = f"{sym} {r.ts_event}"
            o, h, l, c = (ticks(x, FILTERS[sym]["tick"], what) for x in (r.open, r.high, r.low, r.close))
            if not (l <= min(o, c) and h >= max(o, c)):
                raise SystemExit(f"{what}: inconsistent OHLC {o} {h} {l} {c}")
            v = ticks(r.volume * size_nanos, VOL_UNIT, what + " volume")
            ts = datetime.fromtimestamp(r.ts_event / 1e9, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000")
            rows.append((ts, sym, o, h, l, c, v))
    rows.sort()
    per_sym = {s: sum(1 for r in rows if r[1] == s) for s in a.syms}
    if len(set(per_sym.values())) != 1:
        raise SystemExit(f"instruments have different bar counts: {per_sym}")

    with open(os.path.join(a.out, "bars.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["ts", "sym", "o", "h", "l", "c", "v"])
        w.writerows(rows)
    instruments = []
    with open(os.path.join(a.out, "instruments.csv"), "w", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["sym", "mult", "min_qty", "min_notional", "tick", "lot"])
        for sym in sorted(a.syms):
            m = FILTERS[sym]
            mult = klines.ticks(m["tick"] * m["lot"], CASH_UNIT, f"{sym} mult")
            min_notional = klines.ticks(m["min_notional"], CASH_UNIT, f"{sym} min_notional")
            w.writerow([sym, mult, 1, min_notional, str(m["tick"]), str(m["lot"])])
            instruments.append({"sym": sym, "tick": str(m["tick"]), "lot": str(m["lot"]), "mult": mult,
                                "min_notional_usdt": str(m["min_notional"]),
                                "definition_min_price_increment_1e-9": sorted(tick_of[sym])})
    # Pinned like the DBN files, so it holds nothing that varies between two
    # fetches of the same data: no gateway address, client version or time.
    meta = {
        "source": f"Coinlake Databento-compatible API, {a.dataset}",
        "requests": requests,
        "accounting": {"currency": "USDT", "cash_unit": str(CASH_UNIT)},
        "volume_unit": str(VOL_UNIT) + " of the base asset",
        "range": {"first_bar": rows[0][0][:10], "end": a.end, "bars_per_instrument": per_sym[a.syms[0]]},
        "instruments": instruments,
        "assumptions": [
            "tick, lot and min notional are the exchange filters of fetch_binance_klines.py, applied to the whole "
            "range; every price was checked to be a whole number of ticks",
            "Coinlake builds bars from raw trades, each at its own time; days whose raw trades file is incomplete "
            "use aggregated trades and are reported degraded (doc/databento-bars.md)",
            "bar ts is the UTC open of the day; the close is available at ts + 1d",
        ],
    }
    with open(os.path.join(a.out, "snapshot.json"), "w") as f:
        json.dump(meta, f, indent=1, sort_keys=True)
        f.write("\n")
    names = sorted(n for n in os.listdir(a.out) if n != "SHA256SUMS")
    with open(os.path.join(a.out, "SHA256SUMS"), "w") as f:
        for n in names:
            f.write(f"{sha256(os.path.join(a.out, n))}  {n}\n")


if __name__ == "__main__":
    sys.exit(main())
