# Amber extension of the symbol-sort benchmark

Measured on sita on 2026-10-21 using the
[standalone runner](../../../symbol-sort/README.md), Amber package
`amber-git r913.g028c808-1`, matching the checkout at `~/code/amber`
(`v2.9.1-35-g028c808`). The installed and checkout `amber.k` files match.
Binary and library hashes are in `environment.json`.

Same 2,630,400 already-sorted `(timestamp, symbol)` rows, 100 lexically
ordered symbols per timestamp, and lexical integer-rank control as the
[earlier Rayforce/PeachQ/q results](../symbol-sort/README.md). Each median
uses three fresh processes after one discarded warm-up. Only the first
`xasc` is timed; library loading, construction and checks are excluded.

| Secondary-worker equivalent | Amber total threads requested | Symbols, ms | Integer ranks, ms |
|---:|---:|---:|---:|
| 0 | 1 | 42.135 | 34.407 |
| 1 | 2 | 36.519 | 25.917 |
| 4 | 5 | 31.623 | 26.633 |
| 16 | 17 | 38.536 | 29.815 |

Amber uses `AMBER_THREADS=N+1` because its knob counts total threads, unlike
the secondary-worker settings for the other runtimes. This records a thread
budget, not evidence every operation used that many threads. The machine
has 16 logical CPUs; the last setting requests 17 threads to retain the
same secondary-worker-equivalent matrix.

At setting 4 the earlier symbol results were Rayforce 287.313 ms, PeachQ
27.718 ms and q 28.175 ms, compared with Amber's 31.623 ms here. Amber has
no comparable symbol-specific scaling collapse. These are sequential runs
on a shared desktop, not a fresh interleaved comparison, so small differences
between Amber, PeachQ and q should not be treated as a firm ranking.
Amber also chooses its own compact integer storage, and uses a microsecond
clock rather than q's nanosecond clock.

All 24 measured sorts and eight warm-ups passed full key-value and row-count
checks plus the reversed-input control. `samples.jsonl` preserves every
observation, including confirmation of the native timestamp vector type `N`.

```sh
python3 backtest/bench/symbol-sort/run.py --engines amberx \
  --out /tmp/symbol-sort-amber
```

These results have not been posted to the upstream issue.
