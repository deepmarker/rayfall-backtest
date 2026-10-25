# Rayforce symbol-rank precheck fix

The [candidate patch](../../../symbol-sort/rayforce-symbol-ranks.patch)
prepares lexical symbol ranks before dispatching the already-sorted check.
Both the specialized `(symbol, time)` loop and generic loop then compare
integers, with no symbol resolution in their workers. A shared helper serves
both `ray_key_cols_sorted` and `sort_table_by_keys`.

The installed runtime and external Rayforce checkout were not modified.
The patch was built in the isolated `backtest/data/audit-rayforce-fp` source
copy, against upstream commit `646459984df6c151279bcdce1fb88a90df74b953`.
It applies cleanly to that checkout with `git apply --check`.

## Matched local builds

Both builds use the same isolated tree and compiler, recompiling `sort.c`
from the upstream source for the baseline, then from the patched source.
The source checkout's absent Git metadata is overridden explicitly with
`GIT_HASH=64645998 RAY_VERSION=2.10.0`; the patch itself is identified by
`patch-provenance.json`. These are optimized builds without a sanitizer.
Binary hashes and individual measurements are retained in the environment
and sample files. The [local baseline](../symbol-sort-local-baseline/summary.md)
was measured immediately before the final patched build.

Same 2,630,400-row workload and fresh-process method as the original
comparison: three timed observations after one discarded warm-up per cell.
The host is a shared desktop, so submillisecond differences are not decisive.

| Secondary workers | Baseline symbols, ms | Patched symbols, ms | Baseline integers, ms | Patched integers, ms |
|---:|---:|---:|---:|---:|
| 0 | 52.036 | 21.773 | 21.254 | 22.069 |
| 1 | 85.375 | 17.608 | 16.648 | 16.925 |
| 4 | 291.224 | 14.876 | 14.113 | 14.165 |
| 16 | 1227.420 | 14.496 | 13.487 | 14.071 |

The symbol case improves about 20 times at four secondary workers and
85 times at sixteen. Integer-control timings stay close. The patched symbol
result is faster than the earlier PeachQ/q/Amber results on this workload;
this is not a general database performance comparison.

## Correctness and costs

All 24 measured sorts and eight warm-ups passed full row-count/key checks
and the reversed-input control. The existing sort-related test selection,
including a new 200,000-row regression, passed **175/175** with both zero
and four secondary workers. `validation.txt` records the commands/results.
The regression checks nonlexical intern order, both key orders, both sort
directions, a late inversion, and continued rejection of symbol nulls.
This is focused validation, not the complete Rayforce test suite.

Full reverse-sorted input was checked separately with reversal outside
timing, keeping the same expected ascending output. Three observations per
cell after one warm-up gave:

| Secondary workers | Baseline, ms | Patched, ms |
|---:|---:|---:|
| 0 | 50.544 | 50.765 |
| 4 | 42.751 | 43.127 |

Raw observations are in `reversed-samples.jsonl`. The reversed workload adds
`(set input (reverse b))` before timing and times `(xasc input [ts sym])`;
the original `b` is retained for the independent small reversed control.

Rank preparation introduces upfront work and temporary memory for symbol
keys, even if an unsorted input could previously bail out at its first pair.
The existing `build_enum_rank` allocates through the maximum used intern ID,
not just the distinct IDs present in the column. Large sparse domains,
many tiny partitions and high symbol cardinality need further performance
coverage before an upstream merge. Null/type gates remain unchanged, and
rank-allocation failure declines the shortcut rather than claiming sortedness.
If the scan rejects ordering, the normal sort may prepare those ranks again.

## Reproduce

In a separate Rayforce checkout at the base commit, apply the patch and run:

```sh
git apply /path/to/dm/backtest/bench/symbol-sort/rayforce-symbol-ranks.patch
make -j8 release
make -j8 test-release TEST_FILTER=sort TEST_CORES=4
```

Then run from dm, selecting the resulting executable:

```sh
python3 backtest/bench/symbol-sort/run.py --engines rayforce \
  --rayforce /path/to/rayforce/rayforce --out /tmp/symbol-sort-rank-fix
```

The candidate patch and these results have not been posted upstream.
