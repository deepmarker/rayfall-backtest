"""Run from dm root: python3 backtest/bench/results/2026-10-21-sita/loading/run.py.

Requires dbn, rayforce, /usr/bin/time, and nautitest's existing Python env.
Generated datasets and catalogs stay under backtest/data (ignored by Git).
Each measurement is a new process with a warm OS page cache. Existing import
artifacts are reused on resume; delete only the experiment's cache directory
and results.jsonl for a completely fresh measurement.
"""
import json
import subprocess
from pathlib import Path

workspace = Path.cwd()
root = Path(__file__).resolve().parent
cache_root = workspace / 'backtest/data/audit-loading'
python = str(workspace / 'nautitest/.venv/bin/python')
inputs = [
    ('trades', Path('go/EXECS_BFU_BTCUSDT_2025-01-01_00-00-00.000000_24h0m0s.dbn.zst'), 'BTCUSDT.BINANCE', False),
    ('bars', Path('julia/cointegration/data/OHLCV_BFU_MORPHOUSDT_2024-01-01_00-00-00.000000_1095d0h0m_24h0m0s.dbn.zst'), 'MORPHOUSDT.BINANCE', True),
]
results = root / 'results.jsonl'


def saved():
    return [json.loads(line) for line in results.read_text().splitlines()] if results.exists() else []


def record(result):
    with results.open('a') as f:
        f.write(json.dumps(result) + '\n')
    print(json.dumps(result), flush=True)


for name, dbn, instrument, bars in inputs:
    out = cache_root / name
    tail = [str(workspace / dbn), str(out), '--instrument', instrument] + (['--bars'] if bars else [])
    modes = [('prepare', False), ('import', True), ('import', False)]
    modes += [('decode', True)] * 3 + [('decode', False)] * 3 + [('replay', True)] * 3
    for mode, legacy in modes:
        if sum(r.get('mode') == mode and r.get('legacy') == legacy and r.get('input') == dbn.name for r in saved()) >= (3 if mode in ('decode', 'replay') else 1):
            continue
        raw = subprocess.check_output([python, str(root / 'probe.py'), mode] + tail + (['--legacy'] if legacy else []), text=True)
        record(json.loads(raw))
    types = '[TIMESTAMP I64 I64 I64 I64 I64 I64 I64 I64 SYM]' if bars else '[TIMESTAMP TIMESTAMP I64 I64 I64 SYM SYM I64 I64 I64 I64 I64 I64 SYM]'
    parq = json.dumps(str(out / 'exact.parquet'))
    native = json.dumps(str(out / 'native'))
    for mode in ('import', 'parquet', 'native'):
        for rep in range(1 if mode == 'import' else 3):
            if sum(r.get('mode') == 'rf-' + mode and r.get('input') == dbn.name for r in saved()) >= (1 if mode == 'import' else 3):
                continue
            if mode == 'import':
                code = f'(set elapsed (timeit (set n (.parquet.splayed {types} {parq} {native}))))\n(println (format "{{\\"mode\\": \\"rf-import\\", \\"rows\\": %, \\"load_ms\\": %}}" n elapsed))'
            else:
                load = f'(.parquet.read {{types: {types}}} {parq})' if mode == 'parquet' else f'(.db.splayed.get {native})'
                price, size = ('open', 'volume') if bars else ('price', 'size')
                code = f'''(set elapsed (timeit (set t {load})))
(set touched (timeit (set summary (list (min (at t 'ts_event)) (max (at t 'ts_event)) (sum (% (at t '{price}) 1000000000)) (sum (at t '{size}))))))
(println (format "{{\\"mode\\": \\"rf-{mode}\\", \\"rows\\": %, \\"load_ms\\": %, \\"touch_ms\\": %, \\"price_remainder_sum\\": %, \\"size_sum\\": %, \\"ts_first\\": %, \\"ts_last\\": %}}" (count t) elapsed touched (at summary 2) (at summary 3) (+ 946684800000000000 (as 'I64 (at summary 0))) (+ 946684800000000000 (as 'I64 (at summary 1)))))'''
            path = out / f'{mode}-{rep}.rfl'
            path.write_text(code)
            rss = path.with_suffix('.rss')
            raw = subprocess.check_output(['/usr/bin/time', '-f', '%M %e', '-o', str(rss), 'rayforce', str(path)], text=True)
            result = json.loads(raw)
            memory, wall = rss.read_text().split()
            result.update(input=dbn.name, peak_rss_kb=int(memory), wall_s=float(wall))
            if mode == 'import':
                result['native_bytes'] = sum(p.stat().st_size for p in (out / 'native').rglob('*') if p.is_file())
            record(result)
