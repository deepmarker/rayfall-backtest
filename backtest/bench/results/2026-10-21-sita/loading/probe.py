"""Offline loading phases; invoke with nautitest/.venv/bin/python.

Canonical Parquet is derived with the installed official DBN CLI and Arrow.
Integer price payloads are retained; conversion is reported separately.
"""
import argparse
import json
import resource
import subprocess
from pathlib import Path
from time import perf_counter

p = argparse.ArgumentParser()
p.add_argument('mode', choices=['prepare', 'decode', 'import', 'replay'])
p.add_argument('dbn', type=Path)
p.add_argument('cache', type=Path)
p.add_argument('--instrument', required=True)
p.add_argument('--legacy', action='store_true')
p.add_argument('--bars', action='store_true')
a = p.parse_args()
a.cache.mkdir(parents=True, exist_ok=True)
result = {'mode': a.mode, 'input': a.dbn.name, 'legacy': a.legacy}
start = perf_counter()
if a.mode == 'prepare':
    import pyarrow as pa
    import pyarrow.csv as pc
    import pyarrow.parquet as pq
    csv = a.cache / 'source.csv'
    t = perf_counter()
    with csv.open('wb') as f:
        subprocess.run(['dbn', '-C', '-s', str(a.dbn)], stdout=f, check=True)
    result['dbn_to_csv_ms'] = (perf_counter() - t) * 1000
    t = perf_counter()
    table = pc.read_csv(csv)
    for name in ('ts_event', 'ts_recv'):
        if name in table.column_names:
            i = table.schema.get_field_index(name)
            table = table.set_column(i, name, table.column(name).cast(pa.timestamp('ns', tz='UTC')))
    pq.write_table(table, a.cache / 'exact.parquet', compression='snappy')
    result['csv_to_parquet_ms'] = (perf_counter() - t) * 1000
    result['rows'] = len(table)
    result['source_ts_first'] = table['ts_event'].cast(pa.int64())[0].as_py()
    result['source_ts_last'] = table['ts_event'].cast(pa.int64())[-1].as_py()
    result['parquet_bytes'] = (a.cache / 'exact.parquet').stat().st_size
    result['price_type'] = str(table.schema.field('open' if a.bars else 'price').type)
else:
    from nautilus_trader.adapters.databento.loaders import DatabentoDataLoader
    from nautilus_trader.model.identifiers import InstrumentId
    from nautilus_trader.persistence.catalog.parquet import ParquetDataCatalog
    catalog = ParquetDataCatalog(str(a.cache / ('catalog-legacy' if a.legacy else 'catalog-rust')))
    t = perf_counter()
    if a.mode == 'replay':
        rows = catalog.bars() if a.bars else catalog.trade_ticks()
        result['query_ms'] = (perf_counter() - t) * 1000
    else:
        rows = DatabentoDataLoader().from_dbn_file(
            a.dbn, instrument_id=InstrumentId.from_str(a.instrument),
            price_precision=8, as_legacy_cython=a.legacy,
            bars_timestamp_on_close=False)
        result['decode_ms'] = (perf_counter() - t) * 1000
        if a.mode == 'import':
            t = perf_counter()
            catalog.write_data(rows)
            result['write_ms'] = (perf_counter() - t) * 1000
    result['rows'] = len(rows)
    if rows:
        result['ts_first'] = rows[0].ts_event
        result['ts_last'] = rows[-1].ts_event
        result['ts_init_first'] = rows[0].ts_init
    if a.mode in ('import', 'replay'):
        result['catalog_bytes'] = sum(f.stat().st_size for f in Path(catalog.path).rglob('*') if f.is_file())
    if a.mode == 'replay' and not a.bars:
        result['rows_in_source_day'] = len(catalog.trade_ticks(start='2025-01-01', end='2025-01-02'))
result['process_ms'] = (perf_counter() - start) * 1000
result['peak_rss_kb'] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
print(json.dumps(result))
