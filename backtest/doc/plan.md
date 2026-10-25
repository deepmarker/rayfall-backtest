# Rayforce-native backtesting plan

Date: 2026-10-13

Status: milestones 1–5 are done (contracts, accounting kernel, first complete
strategy, portfolio validation, benchmark and architecture review). They run
on a stock Rayforce build (`dev` `64645998` since 2026-10-21), which has every
upstream fix they asked for. See *Progress* at the end. The milestone 5
design topics are listed just before the upstream tracking table. Milestone 6,
a data path from Coinlake's Databento-compatible API, is a candidate, not
started; its design is in *Progress* (2026-10-17).

## Objective and agreed direction

Build a reproducible strategy research and portfolio simulation framework
directly in Rayforce, using Rayfall for the first implementation.

The agreed scope is to:

- Build a complete reference backtester in Rayfall, including an auditable
  accounting kernel.
- Expose a small trading-domain API in Rayfall for writing strategies.
- Benchmark realistic portfolio and sequential event workloads before deciding
  whether any component needs another implementation language.

OCaml, embedded Lua, a new language parser, live trading, and a graphical
strategy builder are outside this initial scope. A later implementation change
should preserve the strategy and accounting contracts established here.

## Intellectual foundations

Brian Peterson's quantstrat work informs the separation of indicators, signals,
rules, orders, transactions, portfolios, and accounts, together with systematic
strategy evaluation. Orders and fills must remain distinct so that execution
decisions can be inspected independently of theoretical signals.

Lasse Heje Pedersen's *Efficiently Inefficient* informs the research process:
state the economic reason for a strategy, then assess its returns after trading
and financing costs, its risk exposures, liquidity requirements, and capacity.
These are design influences; this project does not aim to reproduce quantstrat's
R interfaces or implement every strategy discussed in the book.

References:

- [Peterson: Quantitative Strategy Evaluation with quantstrat/blotter](https://github.com/braverock/quantstrat/blob/master/vignettes/quantstrat-RFinance-2018.Rmd)
- [Pedersen: Efficiently Inefficient](https://www.lhpedersen.com/books)
- [Rayforce documentation](https://rayforcedb.com/docs/)
- [Rayfall control flow and functions](https://rayforcedb.com/docs/language/control-flow/)
- [Rayfall script execution](https://rayforcedb.com/docs/getting-started/quick-start/)

## Provisional first use case

Start with hourly or daily crypto spot portfolio research, market orders, one
venue, and one accounting currency. This is a working assumption to confirm
before implementing instrument-specific behavior.

Introduce linear perpetual futures only after spot accounting is validated.
Their first supported release must include funding, collateral, margin, and
explicit liquidation semantics. Do not treat perpetuals as spot instruments
with unrestricted short positions.

Detailed limit-order queue simulation, inverse contracts, options, cross-venue
collateral transfers, and full order-book execution research are deferred.
Sequential event benchmarks are still included to establish the limits of the
Rayfall implementation.

## Architecture

The initial pipeline runs within Rayforce:

```text
Validated historical data snapshot
    -> vectorized features and signals
    -> portfolio targets
    -> trading rules and order requests
    -> sequential simulation and accounting
    -> orders, fills, ledger, positions, and equity
    -> vectorized analysis and reports
```

Use vectorized operations for data preparation, indicators, rankings, target
calculations, and reporting. Use explicit sequential transitions wherever the
result depends on cash, outstanding orders, previous fills, or other evolving
state. A vectorized return calculation alone is not the accounting engine.

Rayfall provides functions, conditionals, bindings, error handling, folds, and
scans. These support a reference implementation, but neither the performance
nor the best representation of complex simulation state is established yet.
Pin the Rayforce revision and validate the required operations in that build.

## Simulation and accounting contract

The conceptual core is:

```text
step(state, event) -> updated_state, emitted_records
```

This notation specifies an interface, not final Rayfall syntax. State includes
cash balances, positions, outstanding orders, strategy state, and relevant
instrument metadata. Events include market observations, rebalance triggers,
order lifecycle events, fills, and eventually funding and margin events.

Define the following before implementing the first strategy:

- Market timestamp, availability timestamp, and deterministic sequence keys.
- Ordering of observations, strategy decisions, order activation, fills, and
  valuation when timestamps coincide.
- Price and quantity scales, rounding, minimum size, and instrument multipliers.
- Cash reservation, insufficient-capital handling, and competing-order priority.
- Position cost basis, realized and unrealized P&L, and valuation conventions.
- Treatment of missing observations, stale prices, and data gaps.

Initial bar execution should use an explicit convention: a decision based on a
completed bar becomes eligible to trade at a later observation, such as the
next bar's open, with configured costs. Missing that observation must trigger
a documented policy. A completed bar cannot retroactively supply a fill inside
it. Bar-based execution must be labeled as a model with limited intrabar detail.

Record desired positions, submitted orders, accepted or rejected orders,
fills, and accounting entries separately. Strategy functions request actions;
the engine controls fills, balances, and valuation.

## Data contracts and reproducibility

Specify schemas for instrument metadata, market observations, universe
membership, features, targets, orders, fills, ledger entries, positions,
valuations, and run manifests.

Use stable instrument identities and historical metadata. A historical universe
must not silently use today's listings. Retain market and availability times
where available; when availability is modeled, record the assumption. Feature
construction must obey those times and declare its warm-up requirements.

Each run manifest records:

- Data snapshot identifiers and checksums or equivalent immutable references.
- Rayforce version or revision and framework/strategy revisions.
- Parameters, universe rules, date ranges, and warm-up interval.
- Event ordering, execution, cost, rounding, and valuation assumptions.
- Random seed if a stochastic model is used.

Results must be reproducible from the manifest and retained inputs. Data
validation failures must be visible rather than silently repaired.

## Rayfall strategy API

Start with a small domain library rather than a new syntax or parser. Strategy
authors compose ordinary Rayfall functions with framework-provided operations.

| Component | Responsibility |
|---|---|
| Universe | Determine eligible instruments at the decision time |
| Features | Calculate causal inputs with explicit warm-up requirements |
| Signals | Express forecasts or entry and exit conditions |
| Portfolio construction | Convert forecasts into desired positions |
| Constraints | Apply exposure, liquidity, and capital limits |
| Trading rules | Convert targets and current state into order requests |
| Execution configuration | Select engine-owned fill and cost assumptions |

Implement the target-based contract first: at each rebalance, a strategy returns
desired positions using data available at that time. Reserve an extension point
for event-driven strategies, but do not require event callbacks in the MVP.

Keep full-history research tables separate from the data view exposed to a
decision function. Tests must establish that future observations do not affect
earlier decisions. This API boundary is a causality convention, not a security
sandbox for arbitrary Rayfall code.

## Implementation milestones

### Semantics and feasibility

Write the event, schema, accounting, and strategy contracts. Verify required
Rayfall operations against the pinned build. Create a tiny synthetic dataset
with manually calculated orders, fills, cash, positions, and equity.

Acceptance: event ordering and expected accounting results are unambiguous;
basic state transitions can be expressed and executed in Rayfall.

### Reference accounting kernel

Implement market-order lifecycle handling, spot positions, cash reservation,
fees, valuation, and append-only output records. Keep the execution model
deterministic initially.

Acceptance: manually calculated fixtures reconcile, including rejected orders,
partial closes, fees, missing prices, and simultaneous demands on shared cash.
Cash and quantity rounding follow the stated contracts.

### First complete strategy

Implement a volatility-scaled time-series trend example using the target-based
API, a local validated data snapshot, a script entry point, a run manifest, and
a report. Include a simple buy-and-hold baseline under comparable assumptions.

Acceptance: repeated runs produce identical ordered results and accounting;
every change in equity is explainable; future-data perturbations leave earlier
decisions unchanged. Profitability is not an acceptance criterion.

### Portfolio validation

Add multiple instruments, shared capital, ranking, exposure limits, and
rebalancing. Use a cross-sectional momentum example to exercise those paths.

Acceptance: strategies cannot overspend cash, bypass constraints, or depend on
incidental input row ordering. Costs and turnover reconcile to fills.

### Benchmark and architecture review

Measure the validated implementation with representative data and synthetic
scaling fixtures. Review correctness, speed, memory, and implementation
complexity before selecting further optimization work.

Acceptance: publish benchmark inputs, commands, environment, revisions,
measurements, and workload-specific conclusions. Retain Rayfall as the default
unless measured evidence identifies a concrete limitation.

### Databento data path (candidate milestone 6)

Feed the backtester from Coinlake's Databento-compatible API instead of the
Binance public archive: DBN files as the pinned snapshot, converted to Parquet
with the `databento` library, read with Rayforce's Parquet reader, and mapped
to bars and instruments in ticks and lots. Run one strategy in both this
backtester and Nautilus Trader (`nautitest/`) on the same DBN input. Design and
measurements: *Progress*, 2026-10-17, "candidate milestone 6".

Acceptance: a snapshot is fetched through the API and pinned by the checksums
of its DBN files; `make data` rebuilds it; the adapter maps prices to ticks
exactly and raises on any price off the tick grid; the instrument limits come
from `definition` records; runs on minute bars open a native table derived
from the pinned DBN rather than reading Parquet each time; existing strategies
run on it unchanged; the same
strategy in Nautilus Trader agrees within the documented differences of the two
fill models.

## Benchmark design

Measure analytics and stateful execution separately, then measure complete runs.

| Workload | Purpose |
|---|---|
| Single-instrument bar backtest | Establish basic overhead and reproducibility |
| Multi-instrument hourly/daily portfolio | Measure ranking, shared capital, and rebalancing |
| Sequential synthetic market events | Measure state transition throughput |
| Many outstanding orders and partial fills | Exercise state lookup and lifecycle costs |
| Parameter sweep | Measure repeated work, feature reuse, and process-level scaling |
| Increasing history and instrument count | Identify memory growth and partition boundaries |

Record wall time, events or rows per second, peak resident memory, output size,
and time spent in loading, features, decisions, execution, accounting, and
reporting. Distinguish cold loading from warm computation and identify which
inputs or features are reused. Check output equivalence after each optimization.

Use bounded smoke fixtures first, then datasets sized to intended research
workflows. Set performance targets before the representative benchmark runs,
based on expected history, instrument count, experiment count, hardware, and
acceptable iteration time. No numeric throughput target has been agreed yet.

Investigate batching, table layout, state representation, and repeated joins
before proposing another runtime. Existing local
[Rayforce join measurements](upstream/rayforce-joins-ignore-indexes.md) are a useful
workload warning, not a conclusion about the pinned build's current behavior.

## Research reports and evaluation

The first report should include equity, returns, drawdowns, exposure, turnover,
trade counts, gross/net performance, and a reconciliation of trading costs.
State annualization conventions for continuously traded markets. Add financing
attribution when financed instruments are supported.

Each strategy should state its economic hypothesis, benchmark, expected failure
conditions, and required data. Keep a chronological development/evaluation split
and record all tried configurations. Fit parameters on development data only;
avoid repeatedly tuning against the held-out interval.

After the first complete backtest, add parameter sensitivity, cost stress,
liquidity participation constraints, capital scaling, and regime analysis.
Capacity estimates must disclose the assumed impact and liquidity model.

## Completion criteria for the initial scope

- A complete Rayfall backtest runs from a pinned data snapshot and manifest.
- The accounting kernel passes independent, manually calculated fixtures.
- Strategies use a documented target-based Rayfall domain API.
- At least one trend and one cross-sectional portfolio example exercise it.
- Reports explain performance and reconcile positions, cash, and costs.
- Representative benchmarks identify practical limits and next optimizations.
- Architecture conclusions are based on measured workloads rather than the
  assumption that vectorized query speed implies fast sequential simulation.

## Decisions to resolve before implementation

- Confirm first instruments, venue, accounting currency, and bar frequency.
- Choose the pinned Rayforce build and first historical data snapshot.
- Agree on the first execution convention, valuation policy, and cost inputs.
- Select repository placement for reusable Rayfall code, fixtures, and reports.
- Set representative workload sizes, hardware, and acceptable iteration times.

These decisions refine the implementation; they do not reopen the agreed
Rayfall-first direction.

## Progress

### 2026-10-13

- **Contracts:** [contracts.md](contracts.md)
  covers units and rounding, event ordering at each boundary, the order
  lifecycle, cost basis, missing data, record schemas, and a hand-calculated
  walkthrough of fixture 1.
- **Code:** in `backtest/` (repository placement decision: a
  top-level `rayfall/` tree for reusable Rayfall code).
  - `bt.rfl`: the v0 kernel.
  - `test/fixture1.rfl`: the hand-calculated walkthrough, plus the equity,
    ledger and fee identities.
  - `test/fixture2.rfl`: submission-time rejections, input validation,
    and row-order independence.
  - Run them with `make test`.
- **Milestone 1:** done.
- **Milestone 2:** the acceptance fixtures pass. Still open: the
  insufficient-position path is unreachable from targets, so it has no
  fixture yet.
- **Pinned build:** Rayforce `de672402`. The tests need the two upstream
  fixes below until they merge.

### 2026-10-13: milestone 3 (first complete strategy)

Decisions resolved:

- **Instruments:** BTCUSDT, ETHUSDT and SOLUSDT spot on Binance.
- **Bars and accounting:** daily bars, USDT accounting with a cash unit of
  1e-8.
- **Costs:** a 10 bp taker fee and Binance's 5 USDT minimum notional.
- **Data:** the snapshot comes from the Binance public monthly 1d kline
  archive, rather than from our own Databend stack.

Delivered:

- **Snapshot:** `binance-spot-1d-2023-10_2026-09` holds 3288 bars over 1096
  days, a manifest and `SHA256SUMS`. It is not committed. Only its checksums
  are, in `backtest/data/binance-spot-1d-2023-10_2026-09.sha256`.
  `make data` downloads and rebuilds it, and installs it only if it matches
  those checksums byte for byte. The tests depend on that rule.
  `tools/fetch_binance_klines.py` builds it:
  - every zip is checked against the archive's published SHA-256;
  - every day must be present, every price a whole number of ticks, and OHLC
    consistent;
  - the input is never repaired;
  - a rebuild from the same sources is byte-identical.
- **Kernel:** strategy mode (`bt_run_strategy`) with a causal view, a
  `targets` record, and the `min_notional` and `NO_MARK` submission rules.
- **Strategies:** `strategies/trend.rfl` (volatility-scaled, long-only,
  weekly) and `strategies/buyhold.rfl` (baseline).
- **Entry point and reports:** `run.sh` and `run.rfl` produce a manifest,
  CSV outputs and `report.md`. `report.rfl` computes metrics and the exact
  per-instrument P&L attribution.
- **Acceptance tests:**
  - `test/fixture3.rfl` covers causality under future-data perturbation, with
    a probe strategy and a positive control; the test was checked against an
    injected look-ahead.
  - It also covers strategy-result validation, the mark-based rules, and
    attribution against fixture 1.
  - `test/determinism.sh` requires two full runs to produce byte-identical
    output (18 files).

The first result is not an acceptance criterion: profitability isn't one. It is
recorded here for orientation. Evaluation window 2023-12-31 → 2026-10-01:

| | Total return | Annualised volatility | Sharpe | Max drawdown | Fees (USDT) |
|---|---|---|---|---|---|
| trend | 65.4 % | 31.0 % | 0.74 | −36.7 % | 2494 |
| buyhold | 42.9 % | 57.2 % | 0.51 | −61.9 % | 98 |

This is one configuration on one period, with no out-of-sample split yet. The
plan's evaluation rules (a development/held-out split, records of every
configuration tried, and sensitivity and cost stress) apply before reading
anything into it.

Rayfall semantics that cost time here are not bugs; they are documented
upstream or in an open issue:

- Inside a lambda, a `let`-local shadows a query column of the same name
  (rayforce#781 states the rule, but the Select docs do not). The reporting
  code avoids such names.
- Inside a query, a quoted symbol names a source column.
- `map` returns a list.
- `sym-name` resolves IDs to symbols rather than to strings.
- `.sys.args` takes only `-key value` pairs after `--`.

[rayforce#817](https://github.com/RayforceDB/rayforce/pull/817) documents the local-versus-column rule, the `(quote name)` escape and `take` cycling.

### 2026-10-13: milestone 4 (portfolio validation)

Delivered:

- **Universe:** a second snapshot, `binance-spot12-1d-2023-10_2026-09`, with
  twelve large-cap USDT pairs (13152 bars), pinned and built by `make data`
  like the first. The list was chosen with hindsight and has survivorship
  bias; the manual says so. TRXUSDT was dropped: its 2023 prices are finer
  than today's tick, and the fixed-point units cannot represent them.
- **Position limits:** `max_weight_ppm` and `max_gross_ppm` in `cfg`. The
  engine applies them to every requested target, whether it comes from a
  strategy or from target rows, so a strategy cannot bypass them.
  - `targets` records the request, the applied target and the limit that
    cut it.
  - Limits never trade a held position. The first version trimmed holdings
    that drifted past a limit, which made the buy-and-hold baseline trade 27
    times; the rule now applies to requests only.
- **Shared cash:** `buy_policy` `REJECT` (the v0 behaviour) or `SCALE`.
  `SCALE` cuts every buy at a decision by the same fraction when the buys
  cost more than the cash left after the sells. The outcome is then
  independent of instrument order, and it fits exactly, with fee rounding
  bounded.
- **Ordering:** the kernel sorts bars by `(ts, sym)`, so the strategy's view
  never depends on input row order. `st_rank` breaks score ties by symbol.
- **Strategy API:** `ctx` gains `mark_ts` and the two limits. `common.rfl`
  gains `st_eligible`, `st_rank` and `st_lots_all`.
- **Strategy:** `strategies/xsmom.rfl`, weekly cross-sectional momentum (top
  three positive 28-day returns, equal weight).
- **Checks** (`bt_check_identities`, `bt_check_limits`, run by every run):
  - traded notional in fills = ledger trade flows; positions = ledger
    quantities;
  - cash and positions never negative; no fill above its order;
  - every decision within the limits.
- **Acceptance tests:**
  - `test/fixture4.rfl`, hand-calculated: both limits, a drifted hold left
    alone, both buy policies, min-quantity after scaling, eligibility with a
    late listing and a stale mark, ranking ties, row-order independence, a
    strategy asking past a limit, and a positive control for the limit check.
  - `test/fixture5.rfl`, on real data with a binding limit: causality,
    row-order independence (reversed inputs give identical records), and
    every run check.
  - Causality for a ranking strategy needs a perturbation that differs per
    instrument. A shared factor left an injected one-day look-ahead
    undetected; the per-symbol factor catches it.
  - `make test-run` checks determinism for `xsmom` as well as `trend`.

Acceptance, against the milestone's criteria:

- **Strategies cannot overspend cash:** the fill-time cash check; cash ≥ 0 is
  verified on every run.
- **Strategies cannot bypass constraints:** limits are applied in the engine
  and checked after every run, and a positive control proves the check
  fails.
- **No dependence on incidental row ordering:** canonical bar order, sorted
  instruments, symbol tie-breaks, and reversed-input tests on synthetic and
  real data.
- **Costs and turnover reconcile to fills:** checked on every run, along with
  fees.

Results, for orientation only (same window and caveats as milestone 3):

| | Total return | Annualised volatility | Sharpe | Max drawdown | Fees (USDT) | Turnover (× equity / yr) |
|---|---|---|---|---|---|---|
| xsmom (12 instruments) | −12.7 % | 57.4 % | 0.20 | −70.1 % | 11327 | 35.2 |
| buyhold (12 instruments) | 16.4 % | 61.1 % | 0.40 | −67.0 % | 98 | 0.3 |

Over this window, weekly 28-day cross-sectional momentum lost to holding the
universe. Fees of about 11 % of capital explain most of the gap in gross
terms. Its largest loss was DOT (−53.4k USDT), and XRP its largest gain
(+60.0k). Milestone 3's trend and baseline numbers are unchanged under the new
kernel (limits that do not bind, the same fills).

Rayfall findings, all filed upstream: `reverse` rejects tables (#818); `at`
with a missing index returns a `LIST` (#819); comparisons and `and`/`or`
misbehave on a `LIST` (#820). The last two together made `st_eligible` accept
every instrument on a day when one had no bars yet. Fixture 4 caught it, and
the helper now casts to `I64`. Also intentional and documented upstream: a
`{…}` literal does not evaluate its values.

### 2026-10-14: stock Rayforce build

[rayforce#811](https://github.com/RayforceDB/rayforce/pull/811),
[#812](https://github.com/RayforceDB/rayforce/pull/812) and the docs PR
[#817](https://github.com/RayforceDB/rayforce/pull/817) are merged. The pin
moves to `dev` `75243572` (`rayforce-git` 2.10.0.r145.g75243572), the first
build with both code fixes, and the backtester no longer needs a locally
patched binary.

- On that build, with the `rayforce` on `PATH`, fixtures 1–5 pass and both
  determinism runs are byte-identical.
- Every record CSV of the `trend` and `xsmom` runs is identical to the runs on
  the patched `de672402` build. The reports differ only in the recorded
  revision and binary hash.

### 2026-10-14: milestone 5 (benchmark and architecture review)

Decisions:

- **Hardware:** fafnir (i7-10700K, 31 GiB). A first full grid there was
  stopped as too long. The published grid ran alongside a Databend load of
  about four cores, which the report records.
- **Workload:** synthetic daily and hourly bars, 3 years, 12 / 100 / 500
  instruments.
- **Targets:** under 1 s for a daily run and under 30 s for an hourly run, at
  100 instruments.
- **Tooling:** `hyperfine` 2 times whole processes; `bench/bench.rfl` times
  the phases inside a run and records the peak RSS.

Delivered:

- **Harness:** `tools/synth_bars.py` (seeded synthetic snapshots),
  `bench/bench.rfl` (one measurement, by mode), `bench/run.sh` (a grid, with
  timeouts, peak RSS and `hyperfine`), `bench/reduced.sh` (the published
  grid) and `bench/summary.py` (the tables).
- **Vectorised kernel:** `bt.rfl` works on whole per-instrument vectors within
  a step. The only loops left are over time and the `REJECT` buy chain. The
  milestone 4 kernel is kept unchanged as `ref/bt_ref.rfl`, and
  `test/equivalence.rfl` requires identical records from both on the
  fixtures and the real snapshots. That includes a cash-starved strategy, so
  that scaled buys and the sequential fallback are compared too. A
  deliberately introduced difference in event order made it fail.
- **Features mode:** `bt_run_features cfg ins bars prepare strategy`.
  `prepare` runs once over all bars; each decision gets one feature row per
  instrument instead of the view. `xsmom` has a features form, which `run.sh`
  uses, with records identical to the view form. The causality test covers
  it, and catches a `prepare` that reads one bar ahead.
- **Report:** [benchmarks.md](benchmarks.md), with raw results in
  `bench/results/2026-10-14-fafnir/`.

Results (details in [benchmarks.md](benchmarks.md)):

| | Reference kernel, view | Vectorised kernel, features mode | Target |
|---|---|---|---|
| daily, 100 instruments | 2.50 s | 0.31 s | < 1 s |
| hourly, 100 instruments | minutes (the view alone: 444 s) | 7.3 s | < 30 s |
| daily, 500 instruments | 14.6 s | 1.8 s | — |
| hourly, 500 instruments | — | 54 s, of which 29 s of checks | — |

Conclusions:

- The view was the main cost: building it and filtering it again inside the
  strategy at every step.
- The vectorised kernel is 3.8–4.8× faster than the reference at 100–500
  instruments.
- At the largest size, the post-run checks (row-level joins over 13 million
  positions rows) and the positions record's memory (7.9 GB) are the next
  costs.
- Rayfall stays the default. No measurement points at a language or runtime
  limit.

Still open: the parameter sweep, order-level workloads (they need an
event-driven engine), `trend` in features mode, and cheaper checks and a
sparser positions record at scale.

### 2026-10-17: run state in a dictionary, indexed `times`, stock `dev` `93ff47ec`

Upstream closed every open item but #809 between 2026-10-14 and 2026-10-16.
Our PRs [#827](https://github.com/RayforceDB/rayforce/pull/827) (indexed
`times`), [#829](https://github.com/RayforceDB/rayforce/pull/829) (`at`),
[#830](https://github.com/RayforceDB/rayforce/pull/830) and
[#831](https://github.com/RayforceDB/rayforce/pull/831) (`LIST` comparisons,
`min`/`max`), [#839](https://github.com/RayforceDB/rayforce/pull/839)
(dotted `alter` in place) and
[#840](https://github.com/RayforceDB/rayforce/pull/840) (`fold`/`map`
boxing) are merged. Upstream fixed `reverse` on tables (#837), the
already-sorted shortcut for `select … asc:` (#847), and `alter` on a local,
which now raises (#846). The pin moves to `dev` `93ff47ec` (`rayforce-git`
2.10.0.r169.g93ff47ec).

Changes:

- **Run state in one dictionary** (design topic 1). Configuration, inputs,
  positions, pending orders and the seven record tables are keys of the global
  `bt` (`bt.cash`, `bt.qty`, `bt.fills`, …), one level deep. `bt_simulate`
  starts each run with `(set bt {})`, and the entry points pass the strategy
  and `prepare` to it instead of setting mode globals. Functions keep their
  `bt_` names, and so do the constants `bt_reject_reasons` and
  `bt_no_targets`. The empty symbol is written `'` (it was a `bt_none`
  constant built with `(as 'SYM "")`). Both kernels, the report, the runner, the tests and the
  bench were updated together.
- **`(times [i n] …)` for every counted loop** (design topic 2), in both
  kernels and the tests. The only `while` loops left stop on a condition: the
  factor shrink in `bt_constrain`.
- **Workarounds removed:** the `I64`/`F64` casts after `at` (#819/#820) in
  `bt_grid`, the features grids, the strategy targets, `st_bar_counts` and
  `xsmom_prepare`; the row-index reversal in the row-order tests (#818).

Checks:

- `make test` (fixtures 1–5, equivalence) and `make test-run` pass, and
  `make fmt-check` is clean.
- The `trend` and `xsmom` runs give byte-identical outputs from the previous
  commit's tree and this one on the new build: all 18 files of each (record
  CSVs, attribution, report, manifest; the run metadata was fixed).
- Cost: a daily, 100-instrument `xsmomf` run takes 233 ms instead of 211 ms
  for the whole process (`run_ms` about 160 ms instead of 138 ms), and
  `kernel` mode 127 ms instead of 121 ms, on the laptop. Every dotted read
  pays about 2–4 µs: the resolver scans all globals twice before it probes
  the dictionary. Filed as
  [rayforce#869](https://github.com/RayforceDB/rayforce/issues/869), with no
  local workaround. Our fix,
  [#870](https://github.com/RayforceDB/rayforce/pull/870), brings the run back
  to 209 ms, below the globals version's 215 ms.

### 2026-10-17: strategy descriptors, result and timing dictionaries

The run state moved into `bt` earlier the same day, but the code around it
still passed data through loose globals. Every strategy file set `strategy`,
`strategy_name`, `strategy_params` and `strategy_prepare`, and the last file
loaded won. `run.rfl` reset `strategy_prepare` by hand and copied each
strategy's values into `base_*` and `main_*` before loading the next.

Changes:

- **Strategy descriptors.** `(bt_strategy name params run prepare)` builds a
  dictionary, and `bt_run_strategy` takes it. The kernel passes `params` in
  `ctx`, calls `(prepare bars params)`, and runs in features mode when
  `prepare` is a function, so `bt_run_features` is gone. It raises on
  anything that is not a descriptor, or on params that are not a dictionary
  (fixture 3). Each strategy file registers itself under `strategies.<name>`
  and reads its parameters from `ctx`. `xsmom.rfl` registers
  `strategies.xsmom` (features mode, which `run.sh` uses) and
  `strategies.xsmom_view`, sharing one params dictionary. `run.rfl` picks
  `(at strategies <name>)`, the causality helper takes a descriptor of either
  kind (`causal_features` is gone), and the reference kernel takes
  descriptors too, refusing a `prepare`.
- **Run results.** `run_one` returns `{name params metrics attribution}`
  instead of a two-element list read by position.
- **Bench timings.** `bench/bench.rfl` keeps its timings and the values its
  timed calls return in one `bench` dictionary. Each mode builds a descriptor
  with per-day-scaled params and timed `run`/`prepare` wrappers, instead of
  overwriting the strategies' parameter globals.

Functions keep their names (`trend`, `xsmom_f`, the `st_*` helpers), and so
do `run.rfl`'s one-shot inputs and `st_warmup`.

Checks: `make test`, `make test-run` and `make fmt-check` pass; every bench
mode runs; the manual's `sma` example runs as written; and the `trend` and
`xsmom` outputs (all 18 files each, manifest and report included) are
byte-identical to the previous commit's.

### 2026-10-17: candidate milestone 6, a Databento data path (proposed, not started)

**Why.** The snapshots come from the Binance public archive through
`tools/fetch_binance_klines.py`, as CSV. Coinlake now serves a
Databento-compatible Historical API, and `nautitest/` uses it to drive Nautilus
Trader (Coinlake → DBN → `DatabentoDataLoader` → `ParquetDataCatalog`). Taking
the backtester's data from the same API gives both engines identical inputs,
and makes the backtester a second real client of that API.

**Facts measured on 2026-10-17.**

- Rayforce (`dev` `93ff47ec`) reads a Parquet file written by
  `databento.DBNStore.to_parquet`
  (`go/EXECS_BFU_BTCUSDT_2025-01-01_00-00-00.000000_24h0m0s.dbn.parquet`,
  726,611 trades) with `.parquet.read` and no glue code. Timestamps come in as
  `TIMESTAMP` and integers as `I16`/`I32`/`I64`; text comes in as `STR`, and a
  `types:` override makes it `SYM`.
- Reading everything takes 120 ms; four columns with `symbol` as `SYM`, 26 ms.
  A grouped `select` over `.parquet.scan` takes 22 ms without materialising the
  file first (laptop).
- `price` in that file is `F64`, because `to_parquet` writes float prices by
  default. `price_type="fixed"` keeps DBN's exact integers in units of 1e-9.
- Coinlake's `timeseries.get_range` streams `trades`, `ohlcv-1s/1m/1h/1d` and
  `definition` (`go/coinlake/backend/api/timeseries/timeseries.go`); the book
  schemas need `batch.submit_job`. The `nautitest` README still says get_range
  returns 501, which is out of date.

**Design.**

1. *Fetch.* `ohlcv-1d` (or `-1h`) and `definition` for the universe, through
   the Databento client against Coinlake, saved as `.dbn.zst`.
2. *Pin the DBN files, not the Parquet.* `data/<name>.sha256` lists the DBN
   checksums, and `make data` refuses a rebuild that differs, as now. Parquet
   bytes depend on the pyarrow version; DBN is the canonical artifact, and
   Nautilus Trader reads it directly.
3. *Convert* with `DBNStore.to_parquet(price_type="fixed")` in `make data`.
   The conversion is a derived step, not part of the pin.
4. *Adapt* in Rayfall (`tools/` or a `data.rfl` loader):
   - bars `[ts sym o c …]` in ticks: each 1e-9 price divided by the
     instrument's tick size from `definition`, raising on a price off the grid
     (no float on the path);
   - OHLCV `ts_event` is the bar's open time, already the kernel's convention;
   - `instruments` (`mult`, `min_qty`, `min_notional`) from `definition`
     instead of the Binance archive; record which `definition` fields map to
     which limit, and where Coinlake has no value.
5. *Scale: a native cache derived from the pinned DBN.* For daily bars the
   format does not matter (about 13,000 rows). For minute bars or trades,
   import the Parquet once into a native table (`.parquet.parted`, or
   `.parquet.splayed`) and have every run open that. The cache is derived like
   the Parquet: rebuilt from the pinned DBN in seconds, never pinned itself.
   `.parquet.scan` stays useful for one-off exploration.

   Measured 2026-10-17 on fafnir (Rayforce `r145`, 75243572; warm page cache,
   one sample each, one process per row). Input: the real one-day Databento
   BTCUSDT trades file tiled over 28 days, 20,345,108 rows, 7 columns, 246 MB
   Snappy Parquet in 28 row groups; text read as `SYM` throughout.

   | | Open | 1-day filtered count | 1-min OHLCV bars, all rows | Sum by side | Peak RSS | On disk |
   |---|---|---|---|---|---|---|
   | `.parquet.read` | 716 ms | 22 ms | 110 ms | 8.8 ms | 3.8 GB | 246 MB |
   | `.parquet.scan` | 0 ms | 241 ms | 437 ms | 157 ms | 2.6 GB | 246 MB |
   | splayed | 0.2 ms | 10.6 ms | 110 ms | 8.9 ms | 1.1 GB | 933 MB |
   | parted (1M-row partitions) | 3.2 ms | 18.7 ms | 79 ms | 10.9 ms | 0.7 GB | 817 MB |

   Import: `.parquet.splayed` 0.4 s, `.parquet.parted` 2.5 s. Query times are
   the best of three. Once in memory, a `.parquet.read` table and a splayed one
   query alike (the same columns); the difference is the load each process
   pays, 0.7 s and 3.8 GB peak, against a lazy native open. `.parquet.scan`
   decodes the file again for every query, 5–20 times slower. Native files are
   uncompressed, about 3.5 times the Parquet's size. Cold-cache reads would
   add more to the larger native files; not measured.

**Cross-check with Nautilus Trader.** Run one strategy (`nautitest`'s planned
moving-average crossover, or `buyhold`) in both engines on the same DBN input.
Nautilus Trader is event-driven and order-level, this backtester bar-level and
vectorised; their results should agree within documented fill-model
differences. Nautilus Trader also covers the order-level workloads milestone 5
left open, which need an event-driven engine.

**Out of scope.** A native DBN reader in Rayforce: the Parquet step is cheap
and uses the official library (an upstream feature request later, if ever).
Querying Databend directly: it would bypass the API's symbology and billing.
Replacing the hand-calculated CSV fixtures: they stay small and human-readable.

**Open questions.**

- Which `definition` fields Coinlake fills for each venue (tick size, lot
  size, minimum notional), and how the gaps are handled.
- Whether `ts_recv`, which is epoch 0 in Coinlake backfills, matters for any
  bar-level use. It should not: bars are keyed by `ts_event`.
- Where the cross-check lives: `nautitest/` (the Nautilus side) and a script
  here that compares the two runs' equity curves and fills.

### 2026-10-17: pin `dev` `ebae11cb`

[rayforce#870](https://github.com/RayforceDB/rayforce/pull/870) (dotted reads)
and [#872](https://github.com/RayforceDB/rayforce/pull/872) (the null symbol
prints as `'`, and the docs say it is SYM's null) are merged. The pin moves to
`dev` `ebae11cb` (`rayforce-git` 2.10.0.r173.gebae11cb). On it, `make test`
and `make test-run` pass, and a daily 100-instrument `xsmomf` run takes about
141 ms of `run_ms` (217 ms for the process), against 160–170 ms on
`93ff47ec`: the `bt` dictionary costs nothing any more. The manual's printing
caveat for `'` is gone.

The package built incrementally reports `2.10.0.r169.g93ff47ec` in
`(.sys.build)`: `src/ops/system.c`, which compiles in the version, is not
rebuilt when only the version changes. A clean package build reports the
right one. Until then the manifest's `rayforce_version` is stale, and its
`rayforce_binary_sha256` is what identifies the binary.

### 2026-10-23: milestone 6, first step: a snapshot through Coinlake's API

`tools/fetch_coinlake.py` builds the `spot` snapshot's instruments and days
(BTC, ETH and SOL, 2023-10-01 to 2026-10-01) from Coinlake's
Databento-compatible API: `ohlcv-1d` and `definition` fetched with the
databento client (`BIN.ARCHIVE`), kept as DBN and converted to the existing
`bars.csv` / `instruments.csv` layout, so every strategy runs unchanged.
`make data-coinlake` rebuilds it and checks `data/coinlake-bin-1d-2023-10_2026-09.sha256`.

- **Pinned bytes.** The DBN arrives zstd-compressed and framed wherever the
  server flushed it (every second, so a slow stream reaches the client), so
  two fetches of the same data compress differently. The snapshot stores and
  pins the decompressed `.dbn`: two fetches were identical file for file.
- **Exact prices.** DBN prices (1e-9 units) are divided by the tick exactly; a
  price off the grid raises. Tick, lot and minimum notional are the exchange
  filters of `fetch_binance_klines.py`: Coinlake's definitions give the data's
  precision (`min_price_increment`, `unit_of_measure_qty`), not the order
  filters, so they are checked (the tick is a whole multiple of
  `min_price_increment`) rather than used. That answers the plan's open
  question on which `definition` fields Coinlake fills.
- **Same bars as Binance's klines.** All 3,288 daily bars equal the `spot`
  snapshot's in open, high, low and close; 3 volumes differ (BTCUSDT
  2026-02-11, a day Coinlake builds from aggregated trades because Binance's
  raw trades file is incomplete, and two ETHUSDT days where the klines count
  fewer trades than the trades file holds; see the repository's
  `doc/binance/archive-findings.md`).
- **Same runs.** `trend` and `buyhold` produce byte-identical records on both
  snapshots (equity, fills, orders, positions, ledger, attribution, targets,
  order events); the reports differ only in the data line.

Not done yet: the Parquet path and native cache for minute bars (daily bars
do not need them), and the Nautilus Trader cross-check.

### Open design topics (discussed 2026-10-14, for milestone 5)

These came up after milestone 4. All three are now done: topic 3 in milestone
5, topics 1 and 2 on 2026-10-17 (see that entry). Each records the facts
measured at the time and the proposal. Timings are on Rayforce `dev` @
2f4605b1.

**1. Kernel state in a dictionary.** *Done 2026-10-17.* `bt.rfl` keeps its run state in about 30
`bt_*` globals. Grouping it in one dictionary would read better: the whole run
could be inspected as one value, and reset with one `set`.

- *Facts.* A dotted name is a dictionary key: `(set bt.cash 100)` creates a
  global dict `bt`, and `bt.cash` is the same value as `(at bt 'cash)`.
  Reads, `set`, `alter`, `insert` and `select … from: bt.fills` all work
  through dotted names, including inside functions.
- *Blocker.* `alter` through a dotted name copies the whole vector on every
  call ([rayforce#821](https://github.com/RayforceDB/rayforce/issues/821)).
  2,000 updates of a 2M vector take 1,650 ms, against 0.6 ms on a plain
  global. Appends and inserts are not affected. At 12 instruments this is
  invisible; at the instrument counts milestone 5 measures, every
  per-instrument update would become O(instruments).
- *Proposal.* Move to one level of keys (`bt.cash`, `bt.qty`, `bt.fills`)
  once #821 is fixed. Do not pass the state functionally through each step
  (`step(state, event)` returning a new state): without in-place updates
  that copies everything at every step.

**2. Loop forms.** *Done 2026-10-17.* The kernel has 11 `while` loops with hand-kept counters.

- `times` (rayforce#594) gives the body no index. kdb+/q's `do[n; …]` has
  none either. An indexed form, `(times [i n] body…)` like Clojure's
  `dotimes`, is proposed upstream
  ([rayforce#822](https://github.com/RayforceDB/rayforce/issues/822)).
- The q idiom is an iterator over `til n`: `each` (`map`), `over` (`fold`),
  `scan`. In Rayfall, 10M passes take about the same time either way
  (`while` 846 ms, `fold` 757 ms, `map` 726 ms, `times` without an index
  500 ms). The call per pass dominates, and building `(til n)` takes 4.6 ms.
- Memory differs. `fold` and `map` box the whole vector up front: 796 MB and
  874 MB peak, against 17 MB for `while`
  ([rayforce#823](https://github.com/RayforceDB/rayforce/issues/823)).
- *Proposal.* Keep `while` for now. Switch to `(times [i n] …)` if #822
  lands. Topic 3 removes most of these loops anyway.

**3. Vectorising the step, as a kdb+/q programmer would.** *Done in milestone
5: the vectorised kernel and features mode, see above. The rest of this topic
is kept as the record of the reasoning.* q style keeps one
loop, over time, and writes each step as whole-vector operations across all
instruments.

- *Sequential by nature* (stay loops):
  - the time loop, since cash and equity at `T` depend on every earlier
    fill;
  - the `REJECT` buy chain, a greedy scan in which a later, smaller buy may
    still fit.
- *Per-instrument loops that become vector code.* Each needs a building
  block, checked on `dev`:

  | Phase | Vector form |
  |---|---|
  | mark | `(set bt_mark (fill bt_mark closes))`: keeps the old mark where there is no new close |
  | snapshot | one `insert` of a column list instead of `n` inserts |
  | limits | caps, room and scaling as vector arithmetic |
  | decide/submit | `delta = target − qty`, rejection reasons as vectors, one bulk insert of orders and events |
  | sell fills | all at once |
  | `SCALE` buy fills | all at once: one fraction, then floor |
  | positions and basis | `(alter 'v set idx vals)` with an index vector |

- *The strategy.* Today it is called every day with `view`, a fresh `select`
  of all bars up to `T`. That is O(rows) per day and O(days × rows) per run,
  and the strategy recomputes its features each time. A q programmer would
  compute the features once, over the whole history, with lagged window
  functions per symbol (`mom: c % xprev[28; c] by sym`), and look up one
  row per instrument at each decision. Causality is then built into the
  columns, and the perturbation tests check it as before. This is the plan's
  own architecture: vectorised features and signals, then a sequential pass
  for what depends on the path.
- *The reference kernel stays.* It was written scalar-first so that it can be
  checked line by line against the hand calculations. A vectorised kernel must
  produce byte-identical records on fixtures 1–5 and both real runs.

**Proposed order for milestone 5** (items 1 and 2 done):

1. A vectorised step kernel (only the time loop and the `REJECT` chain left as
   loops), benchmarked against the reference, with identical outputs
   required.
2. A precomputed-features strategy mode, benchmarked against the per-day
   view.
3. Then the readability refactors: the `bt.*` dictionary (after #821) and
   `times` (if #822 lands).

The milestone also needs the inputs listed in its section: representative
workload sizes (instruments, history, experiments), the hardware, and an
acceptable iteration time.

### Upstream tracking

Rayforce limitations found along the way are reported upstream, not worked
around locally. The local drafts live in the repository's top-level `doc/rayforce-*.md`.

| Upstream | Kind | Status | Effect here |
|---|---|---|---|
| [#809](https://github.com/RayforceDB/rayforce/issues/809) | issue: `I64` overflow wraps silently (as in q) | open | Bounds are documented in the contracts. No local guards |
| [#810](https://github.com/RayforceDB/rayforce/issues/810) | issue: `alter` on a `let`-local writes a global | fixed 2026-10-16 (#846: now raises) | None. Run state is global by design |
| [#811](https://github.com/RayforceDB/rayforce/pull/811) | PR: uncaught `raise` prints its value | merged 2026-10-14 | Test failure messages are invisible without it |
| [#812](https://github.com/RayforceDB/rayforce/pull/812) | PR: multi-branch `if` | merged 2026-10-14 | The kernel's order rules depend on it |
| [#816](https://github.com/RayforceDB/rayforce/issues/816) | issue: `select … asc:` lacks `xasc`'s already-sorted shortcut | fixed 2026-10-16 (#847) | None (performance only) |
| [#817](https://github.com/RayforceDB/rayforce/pull/817) | PR (docs): query name resolution, `take` cycling | merged 2026-10-14 | Documents pitfalls listed in the manual |
| [#818](https://github.com/RayforceDB/rayforce/issues/818) | issue: `reverse` rejects tables | fixed 2026-10-16 (#837) | Row-order tests reverse the tables |
| [#819](https://github.com/RayforceDB/rayforce/issues/819) | issue: `at` with a missing index returns a `LIST` | fixed 2026-10-14 (our PR #829) | Casts removed |
| [#820](https://github.com/RayforceDB/rayforce/issues/820) | issue: comparisons and `and`/`or` on a `LIST` | fixed 2026-10-14 (our PRs #830, #831) | As #819 |
| [#821](https://github.com/RayforceDB/rayforce/issues/821) | issue: `alter` through a dotted name copies the vector | fixed 2026-10-15 (our PR #839) | Run state is in the `bt` dictionary |
| [#822](https://github.com/RayforceDB/rayforce/issues/822) | feature request: indexed `(times [i n] …)` | added 2026-10-14 (our PR #827) | Counted loops use it |
| [#823](https://github.com/RayforceDB/rayforce/issues/823) | issue: `fold`/`map` box a typed vector up front | fixed 2026-10-15 (our PR #840) | Iterators over long ranges are usable |
| [#869](https://github.com/RayforceDB/rayforce/issues/869) | issue: a dotted read scans every global twice | fixed 2026-10-17 (our PR [#870](https://github.com/RayforceDB/rayforce/pull/870)) | None: dotted reads cost what plain globals do |
| [#871](https://github.com/RayforceDB/rayforce/issues/871) | issue: a null symbol in a vector prints as `null`; `'` barely documented | fixed 2026-10-17 (our PR [#872](https://github.com/RayforceDB/rayforce/pull/872), with docs) | None: the kernel writes `'` |
| [#877](https://github.com/RayforceDB/rayforce/issues/877) | feature request: nanosecond `TIMESPAN` durations | added (#917), adopted 2026-10-21 | Periods are spans in configs, strategy contexts, both kernels and benchmarks. Grid indices alone are cast to `I64`; fixture 6 covers nanosecond and long grids |
