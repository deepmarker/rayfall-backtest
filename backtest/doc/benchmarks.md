# Rayfall backtester: benchmarks

Date: 2026-10-14

The [2026-10-21 audit](audit-2026-10-21.md) adds current-build measurements,
frame-pointer profiles and a NautilusTrader loading comparison on sita.
The results below retain the original fafnir environment and revision.

Status: milestone 5 of [the plan](plan.md). This page publishes the
benchmark inputs, commands, environment, revisions, measurements and
conclusions that the milestone asks for. The raw results are in
`bench/results/2026-10-14-fafnir/`.

## Targets

These were agreed before the representative runs:

| Workload | Target |
|---|---|
| one daily backtest, 3 years, 100 instruments | under 1 s |
| one hourly backtest, 3 years, 100 instruments | under 30 s |

The grid also covers 12 and 500 instruments to show how cost scales.

## Inputs

- **Data:** synthetic snapshots from `tools/synth_bars.py`, 1096 days from
  2023-10-01, with 12, 100 or 500 instruments, daily (1096 bars per
  instrument) or hourly (26304). Each instrument is a seeded geometric random
  walk with 4 % daily volatility, in the Binance snapshots' units. The data
  measures cost only; it has no market structure. The largest snapshot is
  13,152,000 bars.
- **Configuration:** `run.rfl`'s: 100,000 USDT, 10 bp fee, 40 %
  per-instrument limit, 100 % gross, `SCALE` buys.
- **Strategies:** `xsmom` and `trend` with their windows scaled to bars per
  day, so hourly runs still rebalance weekly. The rules are the daily ones, so
  the hourly numbers are about cost, not strategy behaviour.

The modes split a run into its costs:

| Mode | Measures |
|---|---|
| `kernel` | accounting alone: `bt_run` with no targets |
| `hold` | adds building the per-step view and the context |
| `xsmom`, `trend` | a strategy on the view, then the run checks and metrics |
| `xsmomf` | `xsmom` in features mode, then the run checks and metrics |

## Commands

```sh
bench/reduced.sh OUT              # the grid below, about 15 minutes
python3 -I bench/summary.py OUT   # the tables below
```

`bench/reduced.sh` runs `bench/run.sh` four times: the reference and the
vectorised kernel, on daily and on hourly bars. Strategies on the view are
measured on daily bars only, because on hourly bars building the view alone
took 37 s at 12 instruments and 444 s at 100 in a first full grid that was
stopped. Each configuration is one instrumented run of `bench/bench.rfl` for
the phase times and the peak RSS. Configurations that took under 10 s are
then timed by `hyperfine` 2: one warm-up, then five runs of the whole
process.

## Environment and revisions

| | |
|---|---|
| Machine | fafnir: Intel Core i7-10700K (8 cores, 16 threads), 31 GiB RAM, Arch Linux, kernel 7.2.8 |
| Rayforce | `rayforce-git` 2.10.0.r145.g75243572 (dev `75243572`), threads automatic (16) |
| Framework | the backtester at this commit (`9a34cce11` plus the milestone 5 changes) |
| hyperfine | 2.0.0 |

fafnir was not idle. A Databend load used about four cores throughout, and
the load average before each grid was 0.1 to 6.5. The `hyperfine` spreads are
small (under 2 % in most cells), but the absolute times include that
contention.

## Measurements

Each cell is the time of one complete process: loading, the run, the checks
and the metrics. A cell reads "mean ± stddev" when `hyperfine` repeated it,
and "(1 run)" otherwise. The phases column splits the vectorised run's own
time.

### Daily bars

| Mode | Instruments | Reference kernel | Vectorised kernel | Speed-up | Phases (vectorised): run / prepare / strategy, ms | Peak RSS |
|---|---|---|---|---|---|---|
| hold | 12 | 0.22 ± 0.00 s | 0.19 ± 0.00 s | 1.2× | 184 / 0 / 0 | 20 MB |
| kernel | 12 | 0.08 ± 0.00 s | 0.04 ± 0.00 s | 1.8× | 40 / 0 / 0 | 19 MB |
| trend | 12 | 0.37 ± 0.00 s | 0.33 ± 0.00 s | 1.1× | 271 / 0 / 65 | 24 MB |
| xsmom | 12 | 0.36 ± 0.01 s | 0.33 ± 0.00 s | 1.1× | 272 / 0 / 64 | 24 MB |
| xsmomf | 12 | — | 0.14 ± 0.00 s | — | 79 / 3 / 4 | 27 MB |
| hold | 100 | 1.27 ± 0.01 s | 0.80 ± 0.01 s | 1.6× | 777 / 0 / 0 | 207 MB |
| kernel | 100 | 0.58 ± 0.01 s | 0.15 ± 0.01 s | 4.0× | 157 / 0 / 0 | 194 MB |
| trend | 100 | 2.71 ± 0.03 s | 2.10 ± 0.02 s | 1.3× | 1942 / 0 / 1119 | 227 MB |
| xsmom | 100 | 2.50 ± 0.01 s | 2.03 ± 0.02 s | 1.2× | 1903 / 0 / 1091 | 227 MB |
| xsmomf | 100 | — | 0.31 ± 0.01 s | — | 216 / 16 / 7 | 229 MB |
| hold | 500 | 6.09 ± 0.01 s | 3.77 ± 0.03 s | 1.6× | 3707 / 0 / 0 | 431 MB |
| kernel | 500 | 2.86 ± 0.03 s | 0.59 ± 0.01 s | 4.8× | 619 / 0 / 0 | 362 MB |
| trend | 500 | 15.89 s (1 run) | 12.34 s (1 run) | 1.3× | 11424 / 0 / 7626 | 642 MB |
| xsmom | 500 | 14.55 s (1 run) | 12.17 s (1 run) | 1.2× | 11290 / 0 / 7524 | 637 MB |
| xsmomf | 500 | — | 1.78 ± 0.01 s | — | 917 / 129 / 42 | 655 MB |

### Hourly bars

| Mode | Instruments | Reference kernel | Vectorised kernel | Speed-up | Phases (vectorised): run / prepare / strategy, ms | Peak RSS |
|---|---|---|---|---|---|---|
| kernel | 12 | 1.85 ± 0.02 s | 1.02 ± 0.01 s | 1.8× | 1004 / 0 / 0 | 262 MB |
| xsmomf | 12 | — | 1.64 ± 0.01 s | — | 1416 / 55 / 43 | 423 MB |
| kernel | 100 | 14.20 s (1 run) | 3.71 ± 0.08 s | 3.8× | 3501 / 0 / 0 | 1126 MB |
| xsmomf | 100 | — | 7.16 ± 0.14 s | — | 5249 / 463 / 48 | 1859 MB |
| kernel | 500 | 70.98 s (1 run) | 17.61 s (1 run) | 4.0× | 16912 / 0 / 0 | 4907 MB |
| xsmomf | 500 | — | 54.35 s (1 run) | — | 24879 / 2909 / 90 | 7919 MB |

Where the time goes, for the vectorised kernel in features mode:

| Workload | Load | Run | of which `prepare` | Checks | Total |
|---|---|---|---|---|---|
| daily, 100 | 5 ms | 216 ms | 16 ms | 83 ms | 0.31 s |
| daily, 500 | 26 ms | 917 ms | 129 ms | 849 ms | 1.8 s |
| hourly, 100 | 0.10 s | 5.2 s | 0.46 s | 1.9 s | 7.3 s |
| hourly, 500 | 0.49 s | 24.9 s | 2.9 s | 28.7 s | 54.4 s |

## Conclusions

- **Both targets are met** with the vectorised kernel and features mode:
  0.31 s for the daily run at 100 instruments, and 7.3 s for the hourly one.
  On the view, the same daily run takes 2.0 s, and the hourly ones take
  minutes.
- **The view was the main cost, not the kernel.** At 100 daily instruments,
  building the view at every step costs 0.6 s and the strategy's own
  filtering another 1.1 s, against 0.16 s of accounting. Features mode removes
  both: `prepare` takes 16 ms once, and the 1096 decisions take 7 ms in total.
  This is a property of the per-step view design, so it holds in any language.
- **The vectorised kernel is 3.8–4.8× faster than the reference** at 100 and
  500 instruments (1.8× at 12), and produces identical records. Per step it
  costs about 0.13 ms at 100 instruments and 0.64 ms at 500, roughly linear in
  the instrument count. Where that time goes inside a step has not been
  profiled.
- **At the largest size, the checks are the next cost.** At hourly 500, the
  post-run checks (identities, limits, attribution) take 28.7 s, more than
  the run. They join over the positions record, which has 13 million rows.
- **Memory follows the records.** The positions record grows with
  instruments × steps: peak RSS is 1.9 GB at hourly 100 and 7.9 GB at
  hourly 500.
- **Rayfall stays the default.** Every measured limit is a design cost of the
  framework (the per-step view, a full positions snapshot every step,
  join-based checks) rather than a limit of the language or runtime. The plan
  keeps Rayfall unless measurements show a concrete limitation, and they do
  not.

Next optimisations, by measured impact:

1. Make the checks cheaper at scale: verify the identities on the equity
   record and on aggregates, rather than through row-level joins over all
   positions.
2. Make the positions record optional or sparse (only instruments with a
   position or a new mark). That would cut memory; whether it also cuts the
   per-step cost needs a profile first.
3. Port `trend` to features mode. Its rolling standard deviation must be
   computed exactly as on the view for the records to stay identical.

## Narrow reporting intermediates

With Rayforce `d7153e72`, projecting the needed position columns before
attribution's sort (eight columns to three) and limit validation's joins
(eight to four) reduced the hourly 100-instrument check median from 1.245 s
to 1.136 s. The whole process fell from 4.233 s to 4.078 s, and peak RSS
from 1849 MiB to 1608 MiB. These are three matched fresh-process observations
per variant on a shared desktop, not a new measurement of the full grid
above. Reporting results and validation coverage are unchanged.

See the [projection experiment](../bench/results/2026-10-22-sita/report-projection/README.md)
for samples, source snapshots, full attribution parity and test results.

## Not covered

- **Parameter sweep:** the ~50-run sweep was not measured. Features mode
  makes it cheaper, since `prepare` depends only on the bars and the
  parameters it uses.
- **Order-level workloads:** sequential market events, many outstanding
  orders and partial fills (from the plan's benchmark design) need an
  event-driven engine that does not exist yet.
- **A quiet machine:** absolute times on an idle machine would be somewhat
  lower. The ratios between modes and kernels are what the conclusions rest
  on.

## Identity left-join gather prototype

An isolated Rayforce prototype retains left columns when a flat LEFT join's
actual output mapping is the identity. On the hourly 100-instrument xsmomf
workload with the projected report, three matched measurements reduced
median checks from 1139.00 to 1033.27 ms (9.3%), whole-process time from
4.007 to 3.917 s (2.3%), and peak RSS by 19.3 MiB. Both variants use the
same local build settings. The engine change is proposed in
[Rayforce PR #943](https://github.com/RayforceDB/rayforce/pull/943) and is not
installed.

[Patch, raw results and validation](../bench/results/2026-10-22-sita/identity-join/README.md)
include ownership and mutation-isolation tests. Radix joins may reorder
rows, so the guard checks every left output index; cardinality alone is
insufficient.

The [PR review correction](../bench/results/2026-10-22-sita/identity-join/review-fix/README.md)
keeps slice-valued columns on the independent gather path and adds a
reordered-radix regression. Fresh matched measurements after the correction
show 8.6% less check time and 18.1 MiB less peak RSS.
