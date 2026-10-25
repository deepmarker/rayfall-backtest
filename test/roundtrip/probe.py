"""Probe Rayforce's legacy text round trips without using print/ser as an oracle.

Only repository-authored expressions are evaluated. This is not a data reader.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent


def source(case):
    # Each predicate first runs on the original value, outside the caught
    # round trip, so broken fixture construction cannot become an XFAIL.
    negative = ''
    if 'reject' in case:
        negative = f"""(if (try (accepts {case['reject']}) (fn [error] false))
  (raise "roundtrip: oracle accepted a negative control"))
"""
    return f'''(set original {case["value"]})
(set accepts (fn [got] {case["check"]}))
(if (not (accepts original)) (raise "roundtrip: invalid source fixture"))
{negative}(println "CORPUS_SOURCE_OK")
(try
  (do
    (set restored (first (eval (parse (format "%" (list original))))))
    (if (accepts restored)
      (println "CORPUS_ROUNDTRIP_OK")
      (println "CORPUS_ROUNDTRIP_MISMATCH")))
  (fn [error]
    (println "CORPUS_ROUNDTRIP_ERROR")
    (println error)))
'''


def probe(binary, directory, case, timeout):
    path = directory / (case['id'] + '.rfl')
    path.write_text(source(case))
    environment = dict(os.environ, TMPDIR=str(directory))
    try:
        run = subprocess.run(
            [binary, str(path)], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, env=environment,
        )
    except subprocess.TimeoutExpired:
        return {'id': case['id'], 'status': 'ERROR', 'detail': 'timeout'}
    output = run.stdout.decode('utf-8', errors='replace')
    markers = [line.strip() for line in output.splitlines()
               if line.startswith('CORPUS_')]
    if run.returncode or not markers or markers[0] != 'CORPUS_SOURCE_OK':
        status = 'ERROR'
    elif markers == ['CORPUS_SOURCE_OK', 'CORPUS_ROUNDTRIP_OK']:
        status = 'XPASS' if case['known_issue'] else 'PASS'
    elif markers in (
        ['CORPUS_SOURCE_OK', 'CORPUS_ROUNDTRIP_MISMATCH'],
        ['CORPUS_SOURCE_OK', 'CORPUS_ROUNDTRIP_ERROR'],
    ):
        status = 'XFAIL' if case['known_issue'] else 'FAIL'
    else:
        status = 'ERROR'
    return {
        'id': case['id'], 'status': status, 'issue': case['known_issue'],
        'returncode': run.returncode, 'stdout': output,
        'stderr': run.stderr.decode('utf-8', errors='replace'),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rayforce', default=os.environ.get('RAYFORCE', 'rayforce'))
    parser.add_argument('--strict', action='store_true',
                        help='fail on known failures as well as regressions')
    parser.add_argument('--json', type=Path, help='write full diagnostics to this file')
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--scratch-root', type=Path,
                        default=Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache'))
                        / 'rayfall-backtest' / 'roundtrip',
                        help='scratch parent; choose disk-backed storage')
    args = parser.parse_args()
    binary = shutil.which(args.rayforce)
    if not binary:
        parser.error(f'Rayforce executable not found: {args.rayforce}')
    cases = json.loads((HERE / 'cases.json').read_text())
    names = [case['id'] for case in cases]
    if len(set(names)) != len(names):
        parser.error('duplicate case IDs')
    scratch = args.scratch_root.resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='probe-', dir=scratch) as temporary:
        results = [probe(binary, Path(temporary), case, args.timeout) for case in cases]
    for result in results:
        issue = result.get('issue')
        print(f'{result["status"]:6} {result["id"]}' + (f' (#{issue})' if issue else ''))
        if result['status'] in ('FAIL', 'ERROR'):
            print(result.get('detail') or result.get('stderr') or result.get('stdout'))
    with open(binary, 'rb') as executable:
        digest = hashlib.file_digest(executable, 'sha256').hexdigest()
    report = {'binary': binary, 'binary_sha256': digest,
              'adapter': 'legacy-format-parse-eval', 'results': results}
    counts = {status: sum(r['status'] == status for r in results)
              for status in ('PASS', 'XFAIL', 'XPASS', 'FAIL', 'ERROR')}
    print('Summary: ' + ', '.join(f'{n} {status}' for status, n in counts.items()))
    if args.json:
        args.json.write_text(json.dumps(report, indent=2) + '\n')
    failures = {'FAIL', 'ERROR', 'XPASS'} | ({'XFAIL'} if args.strict else set())
    return int(any(result['status'] in failures for result in results))


if __name__ == '__main__':
    raise SystemExit(main())
