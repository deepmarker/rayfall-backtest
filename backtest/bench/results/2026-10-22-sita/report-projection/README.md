# Narrow reporting intermediates before sorting and joining

The updated profile identified gathering/copying as the largest self-cycle
cost. Two report queries carried columns that their subsequent calculations
do not use:

- Attribution sorted all eight position columns, then selected only
  `sym`, `ts` and `mv` for grouped deltas. Project those three first.
- Limit validation filtered the full positions record and carried it through
  two left joins. Project `ts`, `sym`, `qty` and `mark` before those joins.

The implementation changes only these temporary inputs. Reporting outputs,
integer equations, record schemas and validation coverage remain the same.
The production file includes explanatory comments in addition to the two
query changes; the exact timed prototypes are retained as
`before-report.rfl` and `after-report.rfl`.

## Matched measurement

Installed Rayforce `2.10.0.r212.gd7153e72-1`, same binary and unchanged
backtester kernel, 100 hourly instruments, 2,630,400 input bars, 26,304
steps, features-mode cross-sectional momentum. Each sample is a fresh
process. Both variants receive one discarded warm-up, then three timed
processes per variant in shuffled order (seed 22). Data construction is not
included, but loading and the entire backtest/check/report process are.
Default runtime worker setting is unchanged.

| Median | Before | Projected | Change |
|---|---:|---:|---:|
| Post-run checks | 1245.34 ms | 1135.68 ms | 8.8% less |
| Entire process | 4.233 s | 4.078 s | 3.7% less |
| Peak RSS | 1849.3 MiB | 1608.4 MiB | 240.9 MiB less, 13.0% |

Check-time ranges were 1231.20–1275.04 ms before and 1119.34–1177.33 ms
after. Whole-process ranges were 4.183–4.235 s before and 4.060–4.181 s
after. The host was shared and its governor uncontrolled; this is a small
matched experiment, not a universal speedup guarantee. Three observations
are enough to identify this candidate, not to characterize every workload.
Raw phase timings, wall times and peak RSS are in `samples.json`.

A separate full hourly run compared every column, type and row of the old
and projected attribution outputs using `check_tbl`, then ran all accounting
checks (`verification.log`). After applying the change, `make test` passed
fixtures 1–6, vector/reference equivalence, and the independent accounting
oracle (50 seeds, three instruments, 16 steps, REJECT). See `tests.log`.

`measurement-driver.py` is the exact executed experiment, retained as
provenance with its historical absolute prototype paths. `environment.json`
records source and binary hashes. The reusable benchmark entry point is
`bench/run.sh`; the prior report source here can be loaded by a copy of
`bench/bench.rfl` for a fresh comparison.

## Further candidates

The engine's flat join path allocates and gathers each left output column
in `src/ops/join.c` even when the output left indices happen to be the
identity permutation. A one-to-one left join preserving every left row is
an opportunity to retain those column vectors rather than copy them.
This is a source-based candidate, not an implemented or timed improvement.
It needs explicit checks for identity, join kind, row count and duplicate
right keys, plus null/domain/COW ownership regressions. It should be tested
separately rather than inferred from this projection result.
