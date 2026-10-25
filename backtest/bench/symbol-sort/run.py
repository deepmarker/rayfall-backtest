#!/usr/bin/env python3
"""Compare the first xasc of fresh sorted (timestamp, symbol/rank) tables.

Each warm-up/sample starts a new runtime; only the in-runtime sort is timed.
Run from anywhere. See README.md for controls and interpretation.
"""
import argparse
import csv
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def measure(engine, binary, template, directory, rows, numeric, workers, timeout, amber_library):
    source = template.read_text().replace('__ROWS__', str(rows)).replace('__NUMERIC__', str(numeric))
    source = source.replace('__AMBER_LIBRARY__', str(amber_library))
    script = directory / ('sample' + template.suffix)
    script.write_text(source)
    command = [binary, str(script)]
    env = dict(os.environ, LC_ALL='C')
    env.pop('RAYFORCE_CORES', None)
    env.pop('AMBER_THREADS', None)
    if engine == 'rayforce':
        env['RAYFORCE_CORES'] = str(workers)
    elif engine == 'amberx':
        env['AMBER_THREADS'] = str(workers + 1)
    else:
        command += ['-q', '-s', str(workers)]
    start = time.perf_counter()
    result = {'engine': engine, 'workers': workers, 'key': 'integer' if numeric else 'symbol',
              'rows': rows, 'command': command, 'source_sha256': hashlib.sha256(source.encode()).hexdigest()}
    if engine == 'amberx':
        result['amber_threads'] = workers + 1
    try:
        process = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                 text=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return dict(result, status='timeout', process_ms=(time.perf_counter() - start) * 1000)
    result.update(process_ms=(time.perf_counter() - start) * 1000, returncode=process.returncode,
                  stdout=process.stdout, stderr=process.stderr)
    if engine == 'q' and 'Max number of secondary threads' in process.stderr:
        return dict(result, status='unavailable', reason='q license secondary-thread limit')
    lines = [line for line in process.stdout.splitlines() if line.startswith('BENCH|')]
    if process.returncode or len(lines) != 1:
        return dict(result, status='error')
    _, elapsed, valid, count = lines[0].split('|')
    if valid != '1' or int(count) != rows:
        return dict(result, status='incorrect')
    result.update(status='ok', sort_ms=float(elapsed), valid=True,
                  runtime_metadata=[line[5:] for line in process.stdout.splitlines() if line.startswith('META|')])
    return result


def summarize(records, engines, workers, output):
    summary = []
    for engine in engines:
        for nworkers in workers:
            for key in ['symbol', 'integer']:
                cell = [r for r in records if r['engine'] == engine and r['workers'] == nworkers and r['key'] == key]
                samples = [r['sort_ms'] for r in cell if not r['warmup'] and r['status'] == 'ok']
                row = {'engine': engine, 'workers': nworkers, 'key': key,
                       'status': 'ok' if samples else next((r['status'] for r in cell if r['status'] != 'ok'), 'missing'),
                       'samples': len(samples)}
                if samples:
                    row.update(median_ms=statistics.median(samples), min_ms=min(samples), max_ms=max(samples),
                               stdev_ms=statistics.stdev(samples) if len(samples) > 1 else 0)
                summary.append(row)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    with (output / 'summary.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=['engine', 'workers', 'key', 'status', 'samples', 'median_ms', 'min_ms', 'max_ms', 'stdev_ms'])
        writer.writeheader()
        writer.writerows(summary)
    lines = ['| Runtime | Secondary workers requested | Symbols, ms | Integer ranks, ms |',
             '|---|---:|---:|---:|']
    for engine in engines:
        for nworkers in workers:
            cells = [r for r in summary if r['engine'] == engine and r['workers'] == nworkers]
            values = [f"{r['median_ms']:.3f}" if r['status'] == 'ok' else r['status'] for r in cells]
            lines.append(f"| {engine} | {nworkers} | {' | '.join(values)} |")
    (output / 'summary.md').write_text('\n'.join(lines) + '\n')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True, help='new output directory; refuses overwrite')
    parser.add_argument('--rows', type=int, default=2630400)
    parser.add_argument('--workers', type=int, nargs='+', default=[0, 1, 4, 16])
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--warmups', type=int, default=1)
    parser.add_argument('--timeout', type=float, default=30)
    engines = ['rayforce', 'peachq', 'q', 'amberx']
    parser.add_argument('--engines', nargs='+', choices=engines, default=engines)
    parser.add_argument('--amber-library', type=Path, default=Path('/usr/share/amber/amber.k'),
                        help='amber.k vocabulary loaded by the bare amberx interpreter')
    for engine in engines:
        parser.add_argument('--' + engine, default=engine, help='runtime executable name or path')
    args = parser.parse_args()
    args.amber_library = args.amber_library.expanduser().resolve()
    if 'amberx' in args.engines and not args.amber_library.is_file():
        parser.error('amber.k not found; set --amber-library, e.g. ~/code/amber/amber.k')
    if args.rows < 6 or args.runs < 1 or args.warmups < 0 or any(w < 0 for w in args.workers):
        parser.error('need rows >= 6, runs >= 1, warmups >= 0 and nonnegative worker settings')
    binaries = {}
    for engine in args.engines:
        binary = shutil.which(getattr(args, engine))
        if not binary:
            parser.error(f'{engine} executable not found; select engines or set --{engine}')
        binaries[engine] = str(Path(binary).absolute())
    args.out.mkdir(parents=True, exist_ok=False)
    metadata = {'host': platform.node(), 'platform': platform.platform(),
                'logical_cpus': os.cpu_count(), 'rows': args.rows, 'symbols': 100,
                'workers': args.workers, 'runs': args.runs, 'warmups': args.warmups,
                'created_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                'timing': 'one first xasc per fresh process, construction and correctness checks excluded',
                'binaries': {e: {'path': b, 'sha256': hashlib.sha256(Path(b).read_bytes()).hexdigest()}
                             for e, b in binaries.items()}}
    if shutil.which('pacman'):
        p = subprocess.run(['pacman', '-Q', 'rayforce-git', 'peachq', 'amber-git'], capture_output=True, text=True)
        metadata['installed_packages'] = p.stdout.splitlines()
    if 'amberx' in args.engines:
        metadata['amber'] = {'library': str(args.amber_library),
                             'library_sha256': hashlib.sha256(args.amber_library.read_bytes()).hexdigest(),
                             'thread_mapping': 'AMBER_THREADS = secondary workers + 1'}
        # The packaged amberx is a shell launcher; also identify the actual engine.
        if Path('/usr/lib/amber/amber').is_file():
            metadata['amber']['packaged_engine_sha256'] = hashlib.sha256(Path('/usr/lib/amber/amber').read_bytes()).hexdigest()
    (args.out / 'environment.json').write_text(json.dumps(metadata, indent=2) + '\n')
    records = []
    with tempfile.TemporaryDirectory(prefix='symbol-sort-') as temporary:
        directory = Path(temporary)
        for engine in args.engines:
            template = HERE / {'rayforce': 'rayforce.rfl', 'amberx': 'amber.k'}.get(engine, 'q.q')
            for workers in args.workers:
                for numeric in [0, 1]:
                    for iteration in range(args.warmups + args.runs):
                        row = measure(engine, binaries[engine], template, directory, args.rows, numeric, workers, args.timeout, args.amber_library)
                        row.update(warmup=iteration < args.warmups, iteration=iteration)
                        records.append(row)
                        with (args.out / 'samples.jsonl').open('a') as f:
                            f.write(json.dumps(row) + '\n')
                        if row['status'] != 'ok':
                            break
                    print(f"{engine} workers={workers} key={'integer' if numeric else 'symbol'}: {row['status']}", flush=True)
                    summarize(records, args.engines, args.workers, args.out)
    print((args.out / 'summary.md').read_text())
    return int(any(r['status'] not in ('ok', 'unavailable') for r in records))


if __name__ == '__main__':
    raise SystemExit(main())
