#!/usr/bin/env python3
"""Markdown tables from a bench/reduced.sh output directory.

    python3 -I bench/summary.py OUT

For each period, one row per mode and instrument count: the time of one run
(the hyperfine mean ± stddev when it was repeated, else the single
instrumented run), the reference and vectorised kernels side by side, and the
peak RSS of the vectorised run.
"""

import json
import os
import sys


def load(path):
    rows = {}
    if os.path.exists(path):
        for line in open(path):
            r = json.loads(line)
            rows[(r["mode"], r["instruments"])] = r
    return rows


def cell(r):
    if r is None:
        return "—"
    if r["status"] != "ok":
        return r["status"]
    if "hf_mean_s" in r:
        return f'{r["hf_mean_s"]:.2f} ± {r["hf_stddev_s"]:.2f} s'
    return f'{r["wall_s"]:.2f} s (1 run)'


def main():
    out = sys.argv[1]
    for period in ("1d", "1h"):
        ref = load(os.path.join(out, f"ref-{period}", "results.jsonl"))
        vec = load(os.path.join(out, f"vec-{period}", "results.jsonl"))
        keys = sorted(set(ref) | set(vec), key=lambda k: (k[1], k[0]))
        print(f"\n### {'Daily' if period == '1d' else 'Hourly'} bars\n")
        print("| Mode | Instruments | Reference kernel | Vectorised kernel | Speed-up | Phases (vectorised): run / prepare / strategy, ms | Peak RSS |")
        print("|---|---|---|---|---|---|---|")
        for mode, n in keys:
            a, b = ref.get((mode, n)), vec.get((mode, n))
            ta = a and a["status"] == "ok" and a.get("hf_mean_s", a["wall_s"])
            tb = b and b["status"] == "ok" and b.get("hf_mean_s", b["wall_s"])
            speed = f"{ta / tb:.1f}×" if ta and tb else "—"
            phases = (f'{b["run_ms"]:.0f} / {b.get("prepare_ms", 0):.0f} / {b["strategy_ms"]:.0f}'
                      if b and b["status"] == "ok" and "run_ms" in b else "—")
            rss = f'{b["rss_kb"] / 1024:.0f} MB' if b and b.get("rss_kb") else "—"
            print(f"| {mode} | {n} | {cell(a)} | {cell(b)} | {speed} | {phases} | {rss} |")


if __name__ == "__main__":
    main()
