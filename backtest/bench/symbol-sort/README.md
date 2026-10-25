# Already-sorted symbol-key benchmark

Compare Rayforce, PeachQ, KX q and Amber (`amberx`) on the specific workload in
[rayforce#933](https://github.com/RayforceDB/rayforce/issues/933): the first
ascending sort of an already-sorted `(timestamp, symbol)` table.

```sh
python3 backtest/bench/symbol-sort/run.py --out /tmp/symbol-sort-results
```

The runner works from any directory. It requires Python 3's standard library
and the four runtimes on `PATH`; `--rayforce`, `--peachq`, `--q` and `--amberx` select
other binaries. `--engines rayforce q` selects a subset. Output directories
must be new, so results cannot be overwritten accidentally.

Amber's bare interpreter loads `amber.k` from `/usr/share/amber/amber.k` by
default. Use `--amber-library ~/code/amber/amber.k` for a source checkout.
Run Amber alone with `--engines amberx`. Library loading is outside timing.

A quick compatibility check:

```sh
python3 backtest/bench/symbol-sort/run.py \
  --rows 1000 --workers 0 --warmups 0 --runs 1 --out /tmp/symbol-sort-smoke
```

## Workload and controls

- Default: 2,630,400 rows and 100 distinct symbols, lexically ordered within
  each timestamp. Timestamp values are nanoseconds since 2000: `row div 100`.
  No CSV, disk data, network, backtester or instrument definitions are needed.
- The symbol spellings are `s0` through `s99`, sorted lexically. Interning
  them in numeric order makes their internal creation order different from
  their required lexical order.
- The integer control replaces the secondary symbols with their lexical
  ranks `0..99`, preserving the ordering pattern and both column widths.
- Each sample starts a fresh process and times exactly one `xasc` on fresh
  vectors. Construction, process startup, result checks and printing are
  excluded from `sort_ms`. q/PeachQ input column attributes are explicitly
  cleared. No previous sort can supply cached ordering information.
- A discarded warm-up process and three measured processes run per cell by
  default. No engine benchmarks run concurrently. Results retain medians,
  ranges, sample standard deviations and individual measurements. The OS
  cache and CPU state are not reset, and the machine need not be idle.
- After timing, every output key and the row count are checked against the
  expected sorted input. A small reversed-table control verifies that `xasc`
  actually restores order. An incorrect result makes the runner fail.
- `rayforce.rfl` uses Rayfall's `timeit` in milliseconds. The **same** `q.q`
  source runs on PeachQ and q, using nanosecond timestamp subtraction
  converted to milliseconds. Whole-process wall time is also recorded for
  context but is not the compared sort time.
- `amber.k` implements the same values and full result/reversed-input checks
  in Amber's K dialect, with a native timestamp vector. It uses the
  microsecond clock (`t`), converted to milliseconds. Amber chooses its own
  packed integer storage; the integer control does not force 64-bit ranks.
  The microsecond clock has less resolution than q's timestamp clock.

This measures each runtime's public `xasc` operation on the same ordered
values. It does not force the same algorithm: a runtime might scan and return
its input, or generate a permutation and gather. The timing difference alone
cannot establish which implementation it uses.

## Thread settings

`--workers 0 1 4 16` is the default matrix. The settings mean **secondary
workers requested**, not total CPU cores: the caller can also participate.
Rayforce uses `RAYFORCE_CORES=N`; PeachQ and q receive `-s N`. Zero is the
serial baseline. The benchmark does not assume that a particular `xasc`
implementation uses every configured worker.

For Amber the column is a secondary-worker equivalent: `AMBER_THREADS=N+1`
requests 1, 2, 5 and 17 total threads for settings 0, 1, 4 and 16. Amber's
setting is a total thread budget, and 1 forces serial execution. The actual
environment value is recorded in each sample as `amber_threads`. Individual
primitives may use fewer threads. The environment file identifies both the
packaged engine and library because `amberx` itself is a shell launcher.

q may have a license-imposed secondary-thread limit. A rejection explicitly
reporting that limit is saved as `unavailable`, without substituting a smaller
setting. Other errors, timeouts and incorrect results are recorded and make
the runner exit nonzero. This machine's q permits at most four secondary
threads; a q result at setting 16 is therefore unavailable.

KX documents the [secondary-thread setting](https://code.kx.com/q/basics/cmdline/#-s-secondary-threads)
and the [sort interface](https://code.kx.com/q/ref/asc/).

## Artifacts

The output directory contains:

- `environment.json`: host, platform, logical CPUs, parameters, executable
  paths and SHA-256 hashes, plus installed package versions where available.
- `samples.jsonl`: timings, correctness status, command, source hash, runtime
  version/build output, and stdout/stderr for every fresh process.
- `summary.json`, `summary.csv`, `summary.md`: per-runtime, worker-setting
  and key-type comparisons. Warm-up observations are excluded.

Generated scripts live in a temporary directory. Their content is recoverable
from the checked-in templates and recorded row/key parameters.

The [2026-10-21 sita results](../results/2026-10-21-sita/symbol-sort/summary.md)
use Rayforce `2.10.0.r206.g64645998`, PeachQ package `0.88-1`, and q `5`, build
`2026.07.23`. PeachQ's `.z.K` reports its q compatibility version (`5`), so the
package version and binary hash distinguish it from KX q.

The [Amber results](../results/2026-10-21-sita/symbol-sort-amber/README.md)
extend that comparison using package `amber-git r913.g028c808-1`.

A [candidate Rayforce fix and validation](../results/2026-10-21-sita/symbol-sort-rank-fix-final/README.md)
replace the precheck's locked symbol lookups with prepared lexical ranks.
The standalone [patch](rayforce-symbol-ranks.patch) includes a regression test.
