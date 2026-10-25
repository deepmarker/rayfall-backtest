"""Compare every decoded price, size and event timestamp to canonical DBN columns.

Run with nautitest/.venv/bin/python from dm root after run.py.
"""
import json
from decimal import Decimal
from pathlib import Path
import pyarrow as pa
import pyarrow.parquet as pq
from nautilus_trader.adapters.databento.loaders import DatabentoDataLoader
from nautilus_trader.model.identifiers import InstrumentId

root = Path(__file__).resolve().parent
cache = Path('backtest/data/audit-loading')
cases = [
    ('trades', Path('go/EXECS_BFU_BTCUSDT_2025-01-01_00-00-00.000000_24h0m0s.dbn.zst'), 'BTCUSDT.BINANCE', False),
    ('bars', Path('julia/cointegration/data/OHLCV_BFU_MORPHOUSDT_2024-01-01_00-00-00.000000_1095d0h0m_24h0m0s.dbn.zst'), 'MORPHOUSDT.BINANCE', True),
]
result = []
for name, path, instrument, bars in cases:
    canonical = pq.read_table(cache / name / 'exact.parquet')
    objects = DatabentoDataLoader().from_dbn_file(path, instrument_id=InstrumentId.from_str(instrument), price_precision=8, bars_timestamp_on_close=False)
    assert len(objects) == len(canonical)
    mismatches = {}
    for field in (['open', 'high', 'low', 'close'] if bars else ['price']):
        expected = canonical[field].to_pylist()
        mismatches[field] = sum(Decimal(str(getattr(obj, field))) * 1000000000 != value for obj, value in zip(objects, expected))
    size = 'volume' if bars else 'size'
    mismatches[size] = sum(Decimal(str(getattr(obj, size))) != value for obj, value in zip(objects, canonical[size].to_pylist()))
    mismatches['ts_event'] = sum(obj.ts_event != value for obj, value in zip(objects, canonical['ts_event'].cast(pa.int64()).to_pylist()))
    item = {'input': path.name, 'rows': len(objects), 'mismatches': mismatches}
    if bars:
        closed = DatabentoDataLoader().from_dbn_file(path, instrument_id=InstrumentId.from_str(instrument), price_precision=8)
        item['default_bar_ts_shift_ns'] = closed[0].ts_event - objects[0].ts_event
    result.append(item)
(root / 'semantic-comparison.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
