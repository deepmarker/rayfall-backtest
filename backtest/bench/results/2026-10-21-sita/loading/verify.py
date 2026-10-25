"""Reproduce data-quality and default-loader findings from the dm root."""
import hashlib
import importlib.metadata
import json
import subprocess
from pathlib import Path
from nautilus_trader.adapters.databento.loaders import DatabentoDataLoader

root = Path(__file__).resolve().parent
result = {'versions': {name: importlib.metadata.version(name) for name in ['nautilus-trader', 'pyarrow']}, 'files': []}
paths = [
    Path('go/EXECS_BFU_BTCUSDT_2025-01-01_00-00-00.000000_24h0m0s.dbn.zst'),
    *sorted(Path('julia/cointegration/data').glob('*.dbn.zst')),
]
for path in paths:
    item = {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    try:
        rows = DatabentoDataLoader().from_dbn_file(path)
        item['default_loader'] = {'rows': len(rows)}
    except Exception as exc:
        item['default_loader'] = {'error': type(exc).__name__, 'message': str(exc)}
    if path.name.startswith('OHLCV_'):
        rows = [json.loads(line) for line in subprocess.check_output(['dbn', '-J', str(path)], text=True).splitlines()]
        bad = [row for row in rows if not (int(row['low']) <= min(int(row['open']), int(row['close'])) <= max(int(row['open']), int(row['close'])) <= int(row['high']))]
        item.update(rows=len(rows), invalid_ohlc=len(bad), first_invalid=bad[0] if bad else None)
    result['files'].append(item)
(root / 'verification.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
