# Rayforce #933: Rayforce, PeachQ and q comparison

Measured 2026-10-21 on sita (Ryzen AI 7 350, 16 logical CPUs), with
[the standalone runner](../../../symbol-sort/README.md). No data files or
backtester are required. See `environment.json` for binary hashes and
`samples.jsonl` for every observation and runtime build string.

Versions: Rayforce `2.10.0.r206.g64645998`, PeachQ package `0.88-1`, KX q
`5`, build `2026.07.23`. PeachQ reports q compatibility version `5`; it is
identified separately by its package version and executable hash.

The workload is the first `xasc` of 2,630,400 already-sorted rows with keys
`(timestamp, symbol)`, 100 symbols per timestamp. The control substitutes
lexical integer ranks. Each cell below is a median of three fresh processes,
following a separate discarded warm-up process. Only `xasc` is timed; input
construction, startup, result checks and printing are excluded. No sorted
attributes from a prior operation are reused.

| Runtime | Secondary workers requested | Symbols, ms | Integer ranks, ms |
|---|---:|---:|---:|
| Rayforce | 0 | 53.707 | 21.090 |
| Rayforce | 1 | 83.625 | 17.886 |
| Rayforce | 4 | 287.313 | 13.885 |
| Rayforce | 16 | 1175.980 | 13.314 |
| PeachQ | 0 | 33.140 | 33.282 |
| PeachQ | 1 | 28.892 | 27.752 |
| PeachQ | 4 | 27.718 | 27.321 |
| PeachQ | 16 | 43.227 | 46.462 |
| q | 0 | 35.132 | 31.915 |
| q | 1 | 33.753 | 33.171 |
| q | 4 | 28.175 | 26.796 |
| q | 16 | unavailable | unavailable |

Zero requests no secondary workers; the caller is the serial baseline.
Settings are secondary-worker requests, not total CPU cores, and each runtime
is free to use fewer workers for a particular sort. Rayforce uses
`RAYFORCE_CORES=N`; PeachQ and q use `-s N`. The local q license refuses
settings above four. The unavailable cells were not substituted or estimated.

At the common setting 4, Rayforce's symbol case is about 10 times slower
than PeachQ/q, while its integer control is about twice as fast. From setting
0 to 16, Rayforce's symbol case slows by about 22 times while its integer
case improves. PeachQ and q show no comparable symbol-specific collapse in
this matrix. These measurements support the lock-contention diagnosis;
they do not establish either competitor's internal sort implementation or
compare general database performance.

All 66 measured sorts and 22 warm-up sorts passed full key-value/row-count
checks and a small reversed-input sorting control. There were no runtime
errors or timeouts apart from q's two expected license-limit rejections.
The desktop was not reserved and cases were run sequentially, grouped by
runtime; small timing differences should not be treated as a ranking.
Individual ranges and sample standard deviations are in `summary.csv`.

Reproduce from the dm root:

```sh
python3 backtest/bench/symbol-sort/run.py --out /tmp/symbol-sort-results
```

The results and runnable reproducer were posted in
[this comment on rayforce#933](https://github.com/RayforceDB/rayforce/issues/933#issuecomment-6316177401).
See the [PeachQ source analysis](../../../symbol-sort/peachq-analysis.md)
for the implementation difference behind the timings.
