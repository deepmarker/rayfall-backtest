# Rayfall backtester: semantics contracts

Date: 2026-10-21

Status: covers milestones 1–5 of [the plan](plan.md).
`backtest/bt.rfl` implements the kernel and strategy API, and
`report.rfl` and `run.rfl` the runs and reports. The tests in
`backtest/test/` check them, including a hand-calculated fixture.

Pinned build: `rayforce-git` 2.10.0.r206.g64645998, the RayforceDB/rayforce
`dev` head checked on 2026-10-21, including nanosecond `TIMESPAN` values
(rayforce#877, implemented by #917). It carries every fix the backtester asked for
upstream (listed below): the kernel keeps its run state in one dictionary,
whose reads are cheap from this build on (rayforce#870), and loops with the
indexed `times` form. Before the timespan migration it ran on `ebae11cb`.
Earlier milestones ran on `dev` `93ff47ec`, `75243572` and, before that, on
`de672402` with two fixes applied locally. Run records were byte-identical
across those earlier builds. A package built
incrementally can report a stale version in `(.sys.build)`; the run manifest
also records the binary's SHA-256, which identifies it.

## Kernel implementations

`bt.rfl` is the kernel in use. Within each step it works on whole
per-instrument vectors; the only loops left are over time and, under
`REJECT`, along the buys of one step when they do not all fit in the cash.
`ref/bt_ref.rfl` is the scalar reference kernel from milestone 4, written one
instrument and one order at a time so that it can be checked line by line
against the hand calculations. `test/equivalence.rfl` runs both on the
fixtures and on the real snapshots, under both buy policies, and requires all
seven record tables to be identical.

## Scope

The contract covers spot instruments, market orders, a single venue and a
single accounting currency. Bars arrive on a fixed time grid. Strategies set
target positions, which the engine holds to position limits, and execution is
deterministic. Several instruments share one cash balance. Perpetuals, limit
orders, and intrabar execution are out of scope, as the plan states.

## Configuration

| Key | Meaning |
|---|---|
| `cash0` | starting cash, in cash units |
| `fee_ppm` | fee in parts per million of notional |
| `start`, `period`, `steps` | the grid: `T_k = start + k·period`, `end = start + steps·period` |
| `max_weight_ppm` | cap on each requested target's value, in ppm of pre-trade equity (see *Position limits*) |
| `max_gross_ppm` | cap on the total value of all positions after the requested targets, in ppm of pre-trade equity |
| `buy_policy` | `REJECT` or `SCALE`: how buys share cash (see *Order lifecycle*) |

Every key is required; a missing or invalid one raises. A limit of
`1000000` ppm is 100 % of equity. A limit far above that, such as
`1000000000`, never binds.

## Units and rounding

Monetary amounts, prices and quantities are fixed-point `I64` values.
Floating point never enters a balance.

| Quantity | Unit |
|---|---|
| cash, fees, notional, cost basis | integer *cash units*, the smallest unit of the accounting currency (configuration) |
| price | integer *ticks* of the instrument |
| quantity | integer *lots* of the instrument |

Each instrument declares `mult`, the number of cash units in one lot multiplied
by one tick, plus two order limits: `min_qty` in lots and `min_notional` in cash
units. The instruments table therefore has the columns
`sym mult min_qty min_notional`; extra columns are ignored. Instrument validation requires `lot × tick` to be an integer
multiple of the cash unit, and `mult` is that integer. Notional is therefore
exact:

```text
notional = qty × price × mult              (cash units, no rounding)
```

Fees are charged in cash units at `fee_ppm` parts per million of notional,
**rounded up**:

```text
fee = ceil(notional × fee_ppm / 10^6)
```

The kernel computes this as `q·ppm + ceil((r·ppm)/10^6)`, where
`notional = q·10^6 + r`. No intermediate value exceeds the fee itself or
`10^6 · ppm`. The fee always rounds against the account, and
notional is never rounded.

**Overflow.** Core Rayfall `I64` arithmetic wraps silently on overflow. This
is reported upstream as
[rayforce#809](https://github.com/RayforceDB/rayforce/issues/809). Until
upstream changes it, magnitudes must stay below 2^63. The largest product is
`qty × price × mult`. With a cash unit of 1e-8 USD, a lot of 1e-8 BTC and a
tick of 0.01, BTC at 1e6 USD and a 1e4 BTC position give about 1e19, which is
too large. Choose a cash unit of 1e-6 USD or coarser for BTC-sized notionals.
The kernel adds no overflow guards of its own, per the project rule to fix
Rayforce rather than work around it.

## Time and event ordering

The run is defined on an explicit grid `T_k = start + k·period` for
`k = 0..K`, where `T_K = end`. The grid comes from the configuration, not from
the data, so a data gap cannot shift it. `start` and the record time columns
are `TIMESTAMP`; `period` must be a non-null, positive `TIMESPAN`, such as
`1D` or `0D01:00:00`. Bare integer nanoseconds and `TIME` values are rejected;
convert an integer duration explicitly with `(as 'TIMESPAN ns)`.

Timestamp differences, grid offsets and period multiples remain spans.
Rayforce's `div` preserves the duration tag even for span/span, so only its
quotient is cast to `I64` for a grid index. Alignment is checked exactly with
`offset == index × period`, without floating-point division or span modulo.

A bar row has the key `(ts, sym)`. `ts` is the bar's **open** time and must lie
on the grid with `ts < end`. The bar's open price is observable at `ts`, and its
close price at `ts + period`. Bar availability time is therefore
`ts + period` for the close and `ts` for the open. No other availability lag is
modelled in v0, and this assumption belongs in the run manifest.

At each boundary `T`, the kernel runs these phases in a fixed order:

1. **Mark.** For every instrument whose bar `[T − period, T)` exists, set
   `mark = close` and `mark_ts = T`. If an instrument has no such bar, its
   mark is carried forward unchanged and becomes *stale*: `mark_ts < T`.
2. **Snapshot.** Append one `positions` row per instrument and one `equity`
   row. Both are taken *before* any trading at `T`.
3. **Decide.** Only when `T < end`: obtain the requested targets for `T`,
   either from the target rows with `ts = T` or from the strategy (see
   *Strategy API*). An instrument without a target holds its position. The
   position limits turn the requested targets into applied ones (see
   *Position limits*). Each requested target is appended to `targets` with
   its applied value. For each instrument with a target, in instrument order,
   compute `delta = applied target − position`. If the delta is non-zero,
   submit one market order.
4. **Fill.** Only when `T < end`: the orders submitted at `T` execute at the
   **open** of bar `[T, T + period)`. Sells are processed before buys. Within
   each side, orders are processed in ascending `order_id`, which follows
   instrument order, under the configured buy policy. An order is filled at
   most once; any part not filled at `T` lapses. No order carries over to the
   next boundary.

A decision at `T` can only see closes of bars that ended at or before `T`.
The strategy receives a view filtered to exactly those bars.

**Bar fills are a model.** A next-open fill assumes the open price could be
traded at `T`, and it ignores slippage beyond the fee, intrabar path and
liquidity. Reports must label results produced under this model.

## Instrument order and determinism

*Instrument order* is the ascending order of `sym` in the instruments table,
which the kernel sorts on load. Every iteration in the kernel follows either
instrument order or the grid. Neither depends on the row order of the input
files. The kernel also sorts the bars by `(ts, sym)` on load, so the view a
strategy receives is in that order whatever the input order. Order ids and
record sequence numbers are dense counters starting at 0. Rankings in the
strategy helpers break ties by symbol (see *Strategy API*).

## Position limits

Limits apply to requested targets, at the decision-time mark, against the
pre-trade equity of the snapshot at `T`. The value of a target is
`target × mark × mult`. A target with no mark, or one that is not positive,
has value 0 here: submission rejects it, or it closes the position.

1. **Per instrument.** A requested target worth more than
   `floor(equity × max_weight_ppm / 10^6)` is cut to the largest number of lots
   within that cap.
2. **Gross.** The positions held without a request, valued at their marks,
   leave `room = floor(equity × max_gross_ppm / 10^6) − held value`, or 0 if
   that is negative. If the requested targets together are worth more than the
   room, each one is multiplied by the same factor and rounded down to lots.
   The factor is computed in floating point; the exact integer total is then
   checked, and the factor is shrunk until the total fits.

`targets.limit` records the limit that last changed a target: `MAX_WEIGHT`,
`MAX_GROSS`, or null. Limits never trade a held position. A position that
price moves push past a limit stays until the strategy requests a target for
it. Limits bind every source of targets, so a strategy cannot bypass them.
`bt_check_limits` verifies them after a run.

## Order lifecycle and rejection reasons

Every order emits a `SUBMITTED` event, followed by exactly one of `FILLED` or
`REJECTED`. A fill can be smaller than its order only under the `SCALE` buy
policy; its `FILLED` event then has reason `SCALED`, and the rest of the
order lapses.

| Reason | When |
|---|---|
| `SHORT_NOT_ALLOWED` | target < 0 (spot). Rejected at submission |
| `BELOW_MIN_QTY` | 0 < \|delta\| < `min_qty`. Rejected at submission |
| `NO_MARK` | the instrument has no mark yet, so the notional rule cannot be applied. Rejected at submission |
| `BELOW_MIN_NOTIONAL` | \|delta\| × mark × mult < `min_notional`, using the decision-time mark. Rejected at submission |
| `NO_PRICE` | bar `[T, T + period)` is missing for the instrument |
| `INSUFFICIENT_POSITION` | sell qty > position at fill time. Unreachable when every order comes from targets, but checked anyway |
| `INSUFFICIENT_CASH` | buy `notional + fee` > cash at fill time, or cut to 0 lots under `SCALE` |

Under `SCALE`, `BELOW_MIN_QTY` and `BELOW_MIN_NOTIONAL` are checked again on
the cut quantity at the fill price.

**Shared cash.** No cash is reserved at submission. Sells are processed first
and release cash. The buys then share what is left, according to
`buy_policy`:

- **`REJECT`.** Buys fill in instrument order. Each one checks the cash
  available at that moment, after the earlier fills at the same `T`. A buy
  that does not fit is rejected outright, and a later, smaller one may still
  fill.
- **`SCALE`.** The buys with a price are costed at the open, fees included. If
  the total exceeds the cash, each buy is cut to the same fraction
  `f = (cash − n) / total` of its quantity, rounding down to lots, where `n` is
  the number of priced buys. Each fee rounds up by less than one cash unit, so
  keeping back `n` units makes the cut buys fit. The cash check of `REJECT`
  still runs on every fill. The fraction is the same for every buy, so the
  outcome does not depend on instrument order.

Cash never goes negative under either policy, and `bt_check_identities`
verifies it.

## Positions, cost basis and P&L

Each instrument's position carries `qty` (lots, ≥ 0) and `basis` (cash units).

- A buy adds its notional to `basis`. Fees are expensed separately and are not
  capitalised into basis.
- A sell of `s` lots from a holding of `h` lots removes
  `floor(basis · s / h)` from basis. The kernel computes this as
  `q·s + floor(r·s / h)`, where `basis = q·h + r`. When the sell closes the
  whole position (`s = h`), it removes all of the basis. Realised P&L for the
  fill is `proceeds − basis_removed`.
- Market value is `qty × mark × mult`, and `unrealized = mv − basis`.

The following identity holds exactly at every snapshot, and the test suite
asserts it:

```text
equity = cash + Σ mv
equity − cash0 = realized_cum + unrealized − fees_cum
```

## Missing data

- A missing bar is a *gap*, not an error. A missing bar `[T−period, T)`
  leaves the mark stale (phase 1). A missing bar `[T, T+period)` rejects the
  orders due to fill at `T` with `NO_PRICE` (phase 4).
- A position with `mark_ts < T` is valued at its last mark. The `positions`
  snapshot exposes `mark_ts`, so reports can show both the staleness and how
  long it has lasted.
- If no mark exists yet, `mark` is null. A position cannot exist without a
  mark, because a fill implies the bar exists and the close of that bar is
  marked at the next boundary.
- Invalid input **raises** an error and is never repaired. Invalid input
  includes off-grid timestamps, duplicate `(ts, sym)` keys, unknown symbols,
  null or non-positive prices, targets at `ts ≥ end`, and invalid periods.

## Records

All records are append-only and ordered by `seq` (or by `ts, sym`).

| Table | Columns |
|---|---|
| `targets` | `ts sym requested target limit`: every requested target, the applied target after the position limits, and the limit that last changed it |
| `orders` | `order_id ts sym side qty target pos_before` |
| `order_events` | `seq ts order_id event reason`. A `FILLED` event's reason is `SCALED` or null |
| `fills` | `order_id ts sym side qty price notional fee basis_removed realized` |
| `ledger` | `seq ts order_id sym kind cash_delta qty_delta`. `kind` ∈ `TRADE FEE` |
| `positions` | `ts sym qty basis mark mark_ts mv unrealized` |
| `equity` | `ts cash mv equity realized fees unrealized` |

`side` is `BUY` or `SELL`. `qty` in `orders` and `fills` is a positive number
of lots. `qty_delta` in `ledger` is signed. Cash is always
`cash0 + Σ ledger.cash_delta`, and a position is always `Σ ledger.qty_delta`.

## Strategy API

`(bt_run_strategy cfg instruments bars strategy)` takes a strategy
descriptor, the dictionary `{name params run prepare}` that
`(bt_strategy name params run prepare)` builds: `name` is a symbol for the
reports, `params` a dictionary, `run` the decision function and `prepare`
either `0Nl` or a function (features mode, below). The kernel raises if
`strategy` is not such a dictionary or `params` is not a dictionary. It calls
`(run ctx)` at every decision time `T < end`. The strategy returns a table `[sym target]`
with targets in lots (`I64`). An instrument it leaves out holds its position,
so an empty table means hold everything. The kernel raises if the result is
not a table, if a target is not `I64` or is null, if a symbol is unknown, or
if a symbol appears twice.

`ctx` is a dictionary:

| Key | Meaning |
|---|---|
| `k`, `T` | grid index and decision time |
| `start`, `period` | the run grid |
| `params` | the descriptor's `params` |
| `view` | the bars with `ts + period <= T`: every completed bar, and nothing else |
| `equity`, `cash` | the pre-trade snapshot at `T` (cash units) |
| `syms` | instruments in instrument order |
| `qty`, `mark`, `mark_ts`, `mult` | per-instrument vectors in `syms` order; `mark_ts < T` means the mark is stale |
| `max_weight_ppm`, `max_gross_ppm` | the position limits, so a strategy can size within them |

**Features mode.** When the descriptor's `prepare` is a function, the kernel
calls `(prepare bars params)` once, on all the bars in `(ts, sym)` order. It must
return a table `[ts sym f1 f2 …]` with at most one row per bar key, where the
row of bar `ts` depends only on bars up to `ts`. At each decision time `T`,
`ctx` has `feat` instead of `view`: a dictionary of the feature columns in
`syms` order, taken from each instrument's bar that closed at `T` (its row at
`ts = T − period`), and null where there is none. The strategy no longer
filters the history at every step, and it reads features computed once with
whole-column operations.

The view is a causality convention, not a sandbox: a strategy is ordinary
Rayfall and can reach globals. The test suite checks causality directly.
Perturbing every bar from day D onwards must leave all targets, orders, fills
and equity up to D unchanged.

- **Time-series strategies** (`test/fixture3.rfl`): every price from D is
  multiplied by 3. A probe strategy targets a digest of its whole view every
  day, so any leak changes a target.
- **Cross-sectional strategies** (`test/fixture5.rfl`): a ranking ignores a
  factor shared by every instrument, so the i-th symbol is multiplied by
  `i + 2` instead. The same test runs `xsmom` in features mode, which also
  checks that `prepare` reads no later bar.

Both tests have been checked against an injected one-day look-ahead, and fail
on it.

`strategies/common.rfl` provides the portfolio helpers:

- `st_eligible ctx n`: instruments marked at `T` (not stale) with at least
  `n` completed bars.
- `st_rank syms scores`: symbols by descending score, with ties in ascending
  symbol order, so a ranking never depends on row order.
- `st_lots_all ctx w buffer`: lots for a vector of weights.

Example strategies (`backtest/strategies/`):

- `trend.rfl`: long-only, volatility-scaled time-series trend, rebalanced
  weekly.
- `xsmom.rfl`: long-only cross-sectional momentum. Every week it holds the
  three eligible instruments with the highest positive 28-day return, at equal
  weight. The file registers it twice, with the same parameters:
  `strategies.xsmom_view` (`xsmom`, on the view) and `strategies.xsmom`
  (`xsmom_prepare` with `xsmom_f`, in features mode), which `run.sh` uses.
  Both produce identical records.
- `buyhold.rfl`: equal-weight buy-and-hold baseline.

All start on the same warm-up day (91) and keep a 2 % cash buffer. Each file
states its hypothesis, benchmark and expected failure conditions.

## Runs and reports

Data snapshots are not committed. `data/<snapshot>.sha256` pins each one, and
`make data` rebuilds it from its source, failing unless the result matches the
pinned checksums exactly.

`run.sh STRATEGY SNAPSHOT OUT` performs these steps:

1. Verifies the snapshot against its `SHA256SUMS`.
2. Records the framework git revision, marked `-dirty` for uncommitted
   changes, and the SHA-256 of the Rayforce binary.
3. Runs the strategy and `buyhold` under one configuration.

Each run is checked before anything is written; a failed check fails the run.

- The equity identity holds at every snapshot.
- The ledger reconciles against cash and fees.
- Traded notional in the fills equals the trade cash flows in the ledger, so
  turnover and costs reconcile to the fills.
- Every position equals the sum of its ledger quantity changes.
- Cash and positions never go negative, and no fill exceeds its order.
- Every decision kept the position limits.
- Every daily equity change equals the per-instrument price P&L minus that
  day's fees.

The run then writes its outputs:

- `OUT/<name>/*.csv`: every record table, plus `attribution.csv`.
- `OUT/manifest.json`: parameters, configuration, data and code identities,
  and assumptions.
- `OUT/report.md`: metrics side by side, including how many targets a limit
  cut and how many buys were scaled for cash; per-instrument attribution; and
  the reconciliation statement.

Report conventions:

- Metrics cover the window from the first decision day to the end of the run.
- Daily returns are annualised over 365 periods.
- The risk-free rate is 0.
- Gross P&L is net P&L plus fees.
- Turnover is traded notional divided by average equity, per year.

`test/determinism.sh` (`make test-run`) runs the pipeline twice and requires
byte-identical outputs.

## Fixture 1 (hand-calculated)

Configuration: `cash0 = 100000`, `fee_ppm = 1000` (10 bp), `min_notional = 0`, hourly grid
`T0..T4` starting 2026-01-01 00:00, `end = T4`.

| sym | mult | min_qty |
|---|---|---|
| A | 1 | 1 |
| B | 10 | 1 |

Bars (open/close, ticks). B has no bar at `T3`.

| bar open | A | B |
|---|---|---|
| T0 | 100 / 102 | 50 / 51 |
| T1 | 103 / 101 | 51 / 53 |
| T2 | 99 / 104 | 52 / 50 |
| T3 | 105 / 106 | — |

Targets (lots):

| ts | A | B | exercises |
|---|---|---|---|
| T1 | 500 | 95 | B fits on its own but not after A: competing buys on shared cash |
| T2 | 200 | 100 | partial close of A (sell processed first), B multiplier |
| T3 | 400 | 150 | B has no bar → `NO_PRICE` |

Walkthrough:

| T | phase | detail | cash |
|---|---|---|---|
| T0 | snapshot | no marks, no positions; equity 100000 | 100000 |
| T1 | snapshot | marks A 102, B 51; flat; equity 100000 | 100000 |
| T1 | fill o0 BUY A 500 @103 | notional 51500, fee ⌈51.5⌉ = 52 | 48448 |
| T1 | fill o1 BUY B 95 @51 | 95·51·10 = 48450 + fee 49 = 48499 > 48448 → `INSUFFICIENT_CASH` | 48448 |
| T2 | snapshot | marks A 101, B 53; A 500 mv 50500 basis 51500; equity 98948; fees 52 | 48448 |
| T2 | fill o2 SELL A 300 @99 | proceeds 29700, fee ⌈29.7⌉ = 30; basis removed 51500·300/500 = 30900; realised −1200 | 78118 |
| T2 | fill o3 BUY B 100 @52 | 52000 + fee 52 | 26066 |
| T3 | snapshot | marks A 104, B 50; A 200 mv 20800 basis 20600; B 100 mv 50000 basis 52000; equity 96866; realised −1200; fees 134; unrealised −1800 | 26066 |
| T3 | fill o4 BUY A 200 @105 | 21000 + fee 21 | 5045 |
| T3 | fill o5 BUY B 50 | no bar `[T3, T4)` → `NO_PRICE` | 5045 |
| T4 | snapshot | marks A 106, B **stale** 50 (`mark_ts` T3); A 400 mv 42400 basis 41600; B 100 mv 50000; equity 97445; realised −1200; fees 155; unrealised −1200 | 5045 |

Check at T4: `−1200 + (−1200) − 155 = −2555 = 97445 − 100000`.

## Verified Rayfall operations (pinned build)

The following operations were verified on the pinned build:

- `(times [i n] body…)`, with `let` in the body rebinding the function's
  locals, and `while`.
- A global dictionary used through dotted names: `(set bt {})` resets it,
  `(set bt.k v)` adds or replaces a key, and `bt.k` reads it; `alter`,
  `insert` and `select … from:` work through dotted names, inside functions
  too. `(alter 'bt.v set i x)` updates in place unless another value still
  holds the vector.
- `find` and `at` with missing keys, which return `0Nl`; with an index vector,
  the result keeps the vector's type and has nulls where indices are missing.
- `reverse` on tables.
- `div` with floor semantics.
- `try`/`raise`.
- `load`.
- `.csv.read`.
- `TIMESPAN` literals, timestamp differences as spans, `TIMESTAMP ± TIMESPAN`,
  integer scaling of spans, and `as 'I64` for duration quotients.

Upstream issues and pull requests from building milestones 1–5. Only #809 is
still open:

- [rayforce#809](https://github.com/RayforceDB/rayforce/issues/809) (open):
  `I64` `+ - * sum sums` wrap silently on overflow. See *Overflow* above.
- [rayforce#810](https://github.com/RayforceDB/rayforce/issues/810) (fixed):
  `alter` on a `let`-local wrote a global. It now raises.
- [rayforce#811](https://github.com/RayforceDB/rayforce/pull/811),
  [#812](https://github.com/RayforceDB/rayforce/pull/812) (PRs, merged): an
  uncaught `raise` prints its message; multi-branch `if`, on which the
  kernel's order rules rely.
- [rayforce#816](https://github.com/RayforceDB/rayforce/issues/816) (fixed):
  `select … asc:` reuses input that is already in order, as `xasc` does.
- [rayforce#817](https://github.com/RayforceDB/rayforce/pull/817) (docs PR,
  merged): how names resolve in queries, and that `take` cycles.
- [rayforce#818](https://github.com/RayforceDB/rayforce/issues/818) (fixed):
  `reverse` rejected tables. The row-order tests now reverse the tables.
- [rayforce#819](https://github.com/RayforceDB/rayforce/issues/819),
  [#820](https://github.com/RayforceDB/rayforce/issues/820) (fixed): `at` with
  a missing index returned a `LIST`, on which comparisons and `and`/`or`
  misbehaved. Together they once made `st_eligible` accept every instrument
  on a day when one had no bars yet; `test/fixture4.rfl` covers the case. The
  casts that worked around them are gone.
- [rayforce#821](https://github.com/RayforceDB/rayforce/issues/821) (fixed):
  `alter` through a dotted name copied the vector. Fixing it let the run state
  move into the `bt` dictionary.
- [rayforce#822](https://github.com/RayforceDB/rayforce/issues/822) (added):
  the indexed `(times [i n] …)`, which replaced the counted `while` loops.
- [rayforce#823](https://github.com/RayforceDB/rayforce/issues/823) (fixed):
  `fold` and `map` boxed a whole typed vector up front.
- [rayforce#877](https://github.com/RayforceDB/rayforce/issues/877) (added by
  [#917](https://github.com/RayforceDB/rayforce/pull/917)): signed nanosecond
  `TIMESPAN` values. Configuration and strategy contexts use typed periods;
  `test/fixture6.rfl` checks nanosecond grids, long periods and invalid periods
  on both kernels.
