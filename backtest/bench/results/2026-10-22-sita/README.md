# Updated Rayforce performance, 2026-10-22

Measured the installed `rayforce-git 2.10.0.r212.gd7153e72-1`, whose source
commit `d7153e72` merges #937. The C review controls link the installed
`/usr/lib/librayforce.a`, not a private patched build. Source and executable
hashes, package versions and raw observations are retained alongside results.
The host is the same sita desktop; it was shared and the governor was not
controlled. Historical timing differences should not all be attributed to
one PR. Benchmark and backtester source code was unchanged for these runs.

## Standalone sort comparison

First ascending sort of 2,630,400 already-ordered `(timestamp, symbol)` rows,
100 symbols per timestamp. Each cell is a median of three fresh processes
following a discarded warm-up; input construction and output checks are
outside timing. The integer control replaces symbols with lexical ranks.

| Runtime | Secondary workers | Symbol keys, ms | Integer ranks, ms |
|---|---:|---:|---:|
| Rayforce | 0 | 53.018 | 20.961 |
| Rayforce | 1 | 18.979 | 17.958 |
| Rayforce | 4 | 15.392 | 14.392 |
| Rayforce | 16 | 14.711 | 15.509 |
| PeachQ | 4 | 26.998 | 25.784 |
| q | 4 | 30.649 | 26.697 |
| Amber | 4 | 32.904 | 26.236 |

The earlier installed Rayforce measured 287.313 ms at four secondary workers
and 1175.980 ms at sixteen: this workload is about 19/80 times faster now.
Serial symbols remain around 53 ms, consistent with retaining the original
string scan when no secondary workers are available. This is one ordering
workload, not a general database ranking.

[Full matrix](sort-comparison/summary.md), including other worker settings,
raw samples and environment, was rerun for all four engines. Peer executable
hashes match the earlier run. All 90 measured sorts and 30 warm-ups passed;
q's two sixteen-worker cases were explicitly unavailable because of its
license. For Amber the worker column is an equivalent: `AMBER_THREADS=N+1`.

```sh
python3 backtest/bench/symbol-sort/run.py \
  --q ~/.kx/bin/q --out /tmp/updated-symbol-sort
```

## Review regression controls

Drivers are from the updated checkout's `bench/sorted_symbols`; their hashes
and the installed archive hash are in [review-controls/environment.json](review-controls/environment.json).
All checked every result value. Instrumented work counts are separate from
uninstrumented timing observations.

- Large constant symbols: zero string resolutions; two runs: two; secondary
  symbols bypassed by a unique leading integer key: zero, in both directions.
  Ascending constant-column median: 0.090 ms, after one discarded warm-up
  and three observations. Full work output is in `constant_work.txt`.
- Small/early/late unsorted sorts: 28/60005/60007 resolutions, unchanged from
  the repaired controls. Ascending medians: 0.024/3.195/3.223 ms; serial
  2.989 ms. Outputs and counts are in `unsorted_work.txt` and `summary.json`.
- High-used-ID eight-row checks and repeated 10k-row partition-helper checks
  remain admitted, with zero resolutions each (`work_count.txt`).
- SYM-first typed scan: 100 lexical symbols with 20,000 rows per run,
  signed I64 or TIMESTAMP secondary. CPUs 0–3, two discarded processes per
  case, then 12 fresh processes per case shuffled with seed 937:

| Secondary | Total participants | Median, ms | Range, ms |
|---|---:|---:|---:|
| I64 | 1 | 11.336 | 10.152–19.759 |
| I64 | 4 | 10.684 | 10.067–11.281 |
| TIMESTAMP | 1 | 11.007 | 10.105–13.411 |
| TIMESTAMP | 4 | 10.816 | 10.095–12.433 |

These timings remain near the repaired typed route (about 9.8 ms on the
prior host state), rather than its 13.5 ms generic-probe regression. This is
not a new matched-object comparison with the old revision. See the raw
[review samples](review-controls/samples.json) for every observation.

## Backtester end-to-end

Reused the same synthetic snapshots and vectorized kernel for 100
instruments, 1096 daily or 26,304 hourly steps. Default runtime worker
setting, `RAYFORCE_CORES` unset, matching the earlier benchmark. Each row
shows the median of three Hyperfine observations after a warm-up:

| Bars | Mode | Previous median, s | Updated median, s |
|---|---|---:|---:|
| Daily | kernel | 0.1201 | 0.0839 |
| Daily | hold | 0.5864 | 0.5745 |
| Daily | xsmom | 1.3810 | 1.3744 |
| Daily | xsmomf | 0.2217 | 0.1886 |
| Daily | trend | 1.4182 | 1.3819 |
| Hourly | kernel | 3.2152 | 2.0658 |
| Hourly | xsmomf | 5.3436 | 4.7230 |

Hourly momentum has substantial wall-time noise: the three updated
observations were 4.244, 4.723 and 7.400 s; the old range was 5.323–5.428 s.
Its updated mean is therefore 5.456 s. Report the median and range together;
this is not a precise 12% speedup claim. Median aggregate CPU time dropped
from 29.926 to 12.300 s. Hourly kernel median aggregate CPU time dropped
from 21.118 to 3.455 s, consistent with much less worker spinning.

The instrumented hourly `xsmomf` run's validation phase stayed around
1.27 s (previously 1.26 s). Its accounting/reporting pipeline still does
substantial work after the initial bar-order check is fixed. Output step,
bar and fill counts match the earlier observations for all seven modes.
The independent accounting oracle passed all 50 seeds, three instruments,
16 steps, REJECT policy (`oracle.log`).

Raw runs, Hyperfine samples, phase timings and RSS are under `daily/` and
`hourly/`; extracted medians/ranges are in `backtester-comparison.json`.
The same run commands, from dm, are:

```sh
HF_RUNS=3 HF_LIMIT_S=20 MODES='kernel hold xsmom xsmomf trend' \
  backtest/bench/run.sh /tmp/reperf-daily 90 100 1d
HF_RUNS=3 HF_LIMIT_S=20 MODES='kernel xsmomf' \
  backtest/bench/run.sh /tmp/reperf-hourly 90 100 1h
```

## Updated CPU profile

Sampled the packaged hourly `xsmomf` run at 499 Hz, user cycles, DWARF
callchains with 8192-byte stacks. The installed build omits frame pointers,
so this uses its separate debug symbols and DWARF unwinding instead of
claiming an FP callgraph. There were 6506 samples and zero lost samples.
The prior optimized FP profile used 999 Hz; compare broad hotspots rather
than exact percentage-point differences across the sampling configurations.

| Function | Self sampled cycles |
|---|---:|
| multi_gather_fn | 20.34% |
| binary_range | 9.68% |
| ray_free_last_ref | 5.84% |
| hashset_find_xrow | 4.42% |
| csv_parse_fn | 3.16% |
| ray_sym_str | 1.31% |

In the previous hourly momentum profile `ray_sym_str` accounted for 61.54%
of self cycles. It is no longer the dominant CPU cost. The next investigation
should target the attribution/reporting pipeline's gathers, joins and
intermediate arithmetic, especially reducing repeated movement of the
2.63M-row position table. Whole-process sampling identifies candidates; it
does not prove which single reporting expression accounts for every sample.

[Self report](profiles/self.txt), [callgraph](profiles/callgraph.txt), command
output and recording diagnostics are retained. The 52 MB raw perf recording
is ignored data under `backtest/data/audit-profiles-2026-10-22/`; its exact
path and commands' parameters are in `provenance.json`.
