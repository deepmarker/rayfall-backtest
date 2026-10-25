# Rayfall backtester: user manual

Updated: 2026-10-23

Status: milestones 1–5 of [the plan](plan.md): the accounting kernel, a
time-series strategy, portfolio validation with a cross-sectional strategy,
position limits and shared cash, and the benchmark milestone: a vectorised
kernel and a features mode for strategies.

This manual explains how to use the backtester. [contracts.md](contracts.md)
is the reference for what the engine guarantees: units, rounding, event
ordering, rejection rules and record schemas. Where the two overlap, the
contracts win.

## What it is

A deterministic, bar-based backtester written in Rayfall, the language of
[Rayforce](https://github.com/RayforceDB/rayforce). A strategy is a Rayfall
function. At every decision time it sees the completed bars and the account,
and returns target positions. The kernel turns targets into market orders,
fills them at the next bar's open, and records everything.

What it models:

- spot instruments, long only, one venue, one accounting currency;
- a fixed time grid, for example one decision per day;
- market orders filled at the open of the next bar, sells before buys;
- one cash balance shared by every instrument, with a choice of how buys
  share it when it runs short;
- position limits per instrument and in total, enforced by the engine;
- a proportional fee, minimum quantity and minimum notional;
- exact fixed-point accounting: every balance is an `I64`.

What it does not model: shorting, leverage, perpetuals, limit orders,
slippage beyond the fee, intrabar prices, and liquidity limits. A next-open
fill at the bar's open price is an assumption, and every report says so.

## Quick start

Everything runs from `backtest/`.

```sh
make data      # download the two daily snapshots and verify them
make test      # fixtures 1-6, equivalence and independent accounting oracle
make test-run  # two full runs each of trend and xsmom must be byte-identical
./run.sh trend data/binance-spot-1d-2023-10_2026-09 out/trend
./run.sh xsmom data/binance-spot12-1d-2023-10_2026-09 out/xsmom
```

The last two commands write `out/trend/report.md` and `out/xsmom/report.md`.

Requirements:

- **Rayforce** `dev` at `64645998` or later (`rayforce-git` 2.10.0.r206 or
  later). The `rayforce` on `PATH` is used; to pick another binary, pass
  `make test RAYFORCE=/path/to/rayforce` (or `RAYFORCE=… ./run.sh …`).
  [contracts.md](contracts.md) records the pinned build.
- **Python 3** (standard library only) and network access, for `make data`.

`make data` downloads the Binance public monthly kline archive for
2023-10 to 2026-09, checks every zip against its published SHA-256, and builds
two snapshots:

| Snapshot | Instruments | Used by |
|---|---|---|
| `binance-spot-1d-2023-10_2026-09` | BTC, ETH, SOL | `trend` |
| `binance-spot12-1d-2023-10_2026-09` | ADA, AVAX, BCH, BNB, BTC, DOGE, DOT, ETH, LINK, LTC, SOL, XRP | `xsmom` |

All pairs are against USDT. A snapshot is installed only if it matches its
pinned checksums in `data/<snapshot>.sha256` byte for byte. Downloads are
cached in `data/.cache/`, so a rebuild is offline. The snapshots themselves
are not committed.

The twelve instruments are large-cap pairs that traded throughout the window,
chosen in 2026 with hindsight. This list has survivorship bias: assets that
fell out of favour or were delisted are absent. TRX is missing for a technical
reason: its 2023 prices are finer than today's tick, which the fixed-point
units cannot represent (see *Adding data*).

## Concepts

### Units

Nothing in an account is a float. Three integer units are used:

| Quantity | Unit | Snapshot example |
|---|---|---|
| cash, fees, notional | *cash units* | 1e-8 USDT |
| price | *ticks* | 0.01 USDT |
| quantity | *lots* | 1e-5 BTC, 1e-4 ETH, 1e-3 SOL |

Each instrument has `mult`, the number of cash units per lot per tick, so
`notional = qty × price × mult` is exact. For BTCUSDT `mult` is 10: one lot
(1e-5 BTC) at one tick (0.01 USDT) is 1e-7 USDT, which is 10 cash units.

A strategy works in lots. To convert a weight of equity into lots, divide by
the value of one lot: `mark × mult`. The `st_lots` helper does this.

Prices in `bars.csv` are ticks, so BTC's close of 27992.57 USDT is stored as
`2799257`. Starting capital in `run.rfl` is `10000000000000` cash units, which
is 100000 USDT.

### The timeline

The run is a grid of decision times `T_k = start + k × period`. A bar's `ts`
is its *open* time. Its close becomes available at `ts + period`.

At each `T` the kernel:

1. **marks** each instrument at the close of the bar that just ended;
2. **snapshots** positions and equity, before any trading;
3. **asks the strategy** for targets, and submits one market order per
   instrument whose target differs from its position;
4. **fills** those orders at the open of the bar that starts at `T`.

So a decision at `T` sees closes up to `T` and trades at the open of the next
bar. No order survives past its own `T`: an order that cannot fill is
rejected, and the strategy is asked again at the next `T`.

### Orders and rejections

At submission, an order is rejected if its target is negative, it is smaller
than `min_qty`, its notional at the decision-time mark is below
`min_notional`, or the instrument has no mark yet. At fill time, it is
rejected if the next bar is missing or the account cannot pay for it.
`order_events.csv` gives the reason for every rejection; the full table is in
[contracts.md](contracts.md).

### Limits and shared cash

Two limits in `cfg` bound what a strategy can ask for. Both are in parts per
million of pre-trade equity, with values taken at the decision-time mark:

- **`max_weight_ppm`**: a requested target worth more than this share of
  equity is cut to the largest number of lots within it.
- **`max_gross_ppm`**: the requested targets must fit in what this share of
  equity leaves beside the positions held without a request. Otherwise they
  are all scaled down by the same factor.

`targets.csv` records each request with its applied target and the limit that
cut it. Limits never trade a position by themselves: a holding that rises past
`max_weight` stays until the strategy next requests a target for it.

All instruments share one cash balance. Sells fill first and release cash.
When the buys at a decision then cost more than the cash left, `buy_policy`
decides:

- **`SCALE`** cuts every buy to the same fraction of its quantity, so that
  together they fit. The fills are marked `SCALED`.
- **`REJECT`** fills buys in symbol order and rejects each one that does not
  fit.

`run.rfl` uses a 40 % per-instrument limit, a 100 % gross limit and `SCALE`.
With daily crypto bars, the next open is close to the last close, so the
buffer usually absorbs the gap and scaling is rare.

## Desktop launcher

From the repository root, run
`make gui`. Choose a strategy and a local
snapshot, then click **Run strategy**. The launcher uses the same `run.sh`,
configuration, strategy parameters, baseline and accounting checks as the CLI.
It publishes a native bundle and opens its equity, summary and records after
validation. It also offers cancellation and bounded run logs. It currently
uses the defaults in `run.rfl`; parameter/configuration editing is future work.
See the [viewer guide](../../workbench/doc/native-viewer.md)
for dependencies, saved-run reopening and tests.

## Writing a strategy

A strategy is a function from `ctx` to a table `[sym target]`, with targets
in lots (`I64`). A symbol that the table leaves out keeps its position, so an
empty table means "hold everything".

`ctx` is a dictionary:

| Key | Meaning |
|---|---|
| `k`, `T` | grid index and decision time |
| `start`, `period` | the run grid |
| `view` | every bar with `ts + period <= T`: all completed bars, nothing else |
| `equity`, `cash` | the account before trading at `T`, in cash units |
| `syms` | instruments, in ascending `sym` order |
| `qty`, `mark`, `mark_ts`, `mult` | per-instrument vectors in `syms` order; `mark_ts < T` means the mark is stale |
| `max_weight_ppm`, `max_gross_ppm` | the position limits, for sizing within them |

The `view` is sorted by `(ts, sym)`, whatever the order of the input files.
The kernel raises if the result is not a table, if `target` is not `I64` or
holds a null, or if a symbol is unknown or appears twice.

### Helpers

`strategies/common.rfl` holds the helpers the examples share:

| Helper | Does |
|---|---|
| `st_warmup` | 91: the first trading day of both examples, so they are compared over the same window |
| `(st_day ctx)` | the grid index `k` |
| `(st_closes ctx s)` | completed closes of symbol `s`, oldest first |
| `(st_lots ctx i w buffer)` | lots for weight `w` of equity in instrument `i`, keeping `buffer` back, rounded down |
| `(st_targets syms lots)` | the `[sym target]` table |
| `st_hold` | the empty table: hold everything |
| `(st_eligible ctx n)` | `B8` per instrument: marked at `T` (not stale) with at least `n` completed bars |
| `(st_rank syms scores)` | `syms` by descending score; ties in ascending symbol order |
| `(st_lots_all ctx w buffer)` | `st_lots` for a vector of weights, one per instrument; 0 without a mark |

`buffer` (0.98 in the examples) keeps some cash back. The strategy sizes at
the last close, but the order fills at the next open and also pays the fee.
Without a buffer, a full-equity buy after a price gap up is rejected with
`INSUFFICIENT_CASH`.

### A first strategy

The bundled strategies are `buyhold`, `trend`, and `xsmom`. The `sma`
strategy below is a tutorial to create yourself; `strategies/sma.rfl` is
not included in the checkout.

The file below holds BTC with all of its equity while the close is above its
50-day average, and stays in cash otherwise.

```clojure
;; BTC above its 50-day average: hold it with all equity, else stay in cash.
(load "strategies/common.rfl")

(set sma (fn [ctx]
  (let p (at ctx 'params))
  (if (< (st_day ctx) st_warmup) st_hold
      (do
        (let syms (at ctx 'syms))
        (let i (find syms 'BTCUSDT))
        (let c (st_closes ctx 'BTCUSDT))
        (let above (> (last c) (avg (take c (neg (at p 'window))))))
        (let held (> (at (at ctx 'qty) i) 0))
        (if (== above held) st_hold
            (st_targets (enlist 'BTCUSDT)
                        (enlist (if above (st_lots ctx i 1.0 (at p 'buffer)) 0))))))))

(set strategies.sma (bt_strategy 'sma {window: 50 buffer: 0.98} sma 0Nl))
```

After saving the code above as `strategies/sma.rfl`, run it with
`./run.sh sma data/binance-spot-1d-2023-10_2026-09 out/sma`.

Points worth copying:

- **The closing `set` is the file's interface.** It registers a descriptor,
  `(bt_strategy name params run prepare)`, under `strategies.<name>`.
  `run.rfl` loads `strategies/<name>.rfl` and runs `strategies.<name>`. The
  kernel hands `params` to the strategy as `(at ctx 'params)`, and `run.rfl`
  writes them into the run manifest. `prepare` is `0Nl` here: see *Features
  mode*.
- **Trade only when the decision changes.** Equity moves every day, so
  "target = all equity in BTC" gives a slightly different number of lots each
  day, and the strategy would pay a fee daily for a rebalance nobody wants.
  This one returns `st_hold` unless the signal flips. `trend.rfl` rebalances
  every 7 days instead.
- **Wait for enough history.** Before `st_warmup` there are fewer than 91
  bars per instrument. `take` does not stop at a short vector: it repeats it,
  so a 50-day window over 20 closes silently reuses old ones (see the
  pitfalls).

The examples to read next are `strategies/buyhold.rfl` (equal weight, buys on
the warm-up day, then holds) and `strategies/trend.rfl` (volatility-scaled
trend across all three instruments, weekly).

### A portfolio strategy

`strategies/xsmom.rfl` shows the cross-sectional pattern. Every 7 days it:

1. keeps the instruments that `st_eligible` accepts with 29 bars, so a
   28-day return exists and no price is stale;
2. scores each one by its 28-day return;
3. ranks the positive scores with `st_rank`, which breaks ties by symbol;
4. gives the top three a weight of 1/3 each, and everything else 0;
5. turns the weights into lots with `st_lots_all`, with a 2 % buffer.

It returns a target for every instrument, including the zeros, so a name that
drops out of the top three is sold. Capital that has no positive-momentum name
to go to stays in cash.

### Features mode

A strategy on the `view` filters the whole history at every decision and
recomputes its features each time. Both costs grow with the length of the
history, so with hourly bars or hundreds of instruments they dominate a run.
Features mode splits the strategy in two:

- `(prepare bars params)` runs once, on every bar in `(ts, sym)` order, and
  returns a table `[ts sym f1 f2 …]`: one row per bar, holding whatever the
  decisions need, computed with whole-column operations.
- `(run ctx)` runs at each decision as before, but `ctx` has `feat` instead
  of `view`: the feature values, in `syms` order, of each instrument's bar
  that just closed, null where there is none.

A descriptor whose `prepare` is a function runs in features mode, under
`run.sh` and `bt_run_strategy` alike:

```clojure
(set strategies.xsmom (bt_strategy 'xsmom {lookback: 28 top: 3 every: 7 buffer: 0.98} xsmom_f xsmom_prepare))
```

A feature row may only use its own bar and earlier ones. Nothing enforces it,
just as nothing stops a view strategy reading globals, so add the strategy to
the causality test, which runs either kind: `(causal "name" strategies.name)`.

`strategies/xsmom.rfl` registers both forms, with the same parameters:
`strategies.xsmom` in features mode, which `run.sh` uses, and
`strategies.xsmom_view` on the view. `xsmom_prepare` computes each bar's
28-day return by position within its symbol; `xsmom_f` only ranks. Their
records are identical, and a run in features mode is about 12 times faster
(see *Benchmarks*).

### Running a strategy without run.sh

For exploration, load the kernel and the bundled `trend` strategy in a
script or the REPL and call it directly from the backtester directory:

```clojure
(load "bt.rfl")
(load "report.rfl")
(load "strategies/trend.rfl")
(set d "data/binance-spot-1d-2023-10_2026-09/")
(set ins (read-csv [SYM I64 I64 I64 STR STR] (concat d "instruments.csv")))
(set bars (read-csv [TIMESTAMP SYM I64 I64 I64 I64 I64] (concat d "bars.csv")))
(set cfg {cash0: 10000000000000 fee_ppm: 1000
          start: 2023.10.01D00:00:00.000 period: 1D steps: 1096
          max_weight_ppm: 400000 max_gross_ppm: 1000000 buy_policy: 'SCALE})
(bt_run_strategy cfg ins bars strategies.trend)
(bt_check_identities)
(bt_metrics st_warmup)
```

The run leaves its records in the global dictionary `bt`: `bt.targets`,
`bt.orders`, `bt.order_events`, `bt.fills`, `bt.ledger`, `bt.positions` and
`bt.equity`. They are ordinary tables: query them with `select`, as in
`(select {from: bt.fills where: (== sym 'BTCUSDT)})`.

`period` is a duration throughout the kernel and in the strategy context.
Use a `TIMESPAN` literal or convert an integer nanosecond count explicitly
with `(as 'TIMESPAN ns)`; integer, null, zero and negative periods are rejected.
Record time columns remain `TIMESTAMP`.

`cfg` keys:

| Key | Meaning |
|---|---|
| `cash0` | starting cash, in cash units |
| `fee_ppm` | fee in parts per million of notional (1000 = 10 bp), rounded up per fill |
| `start` | first decision time, on the bar grid |
| `period` | positive `TIMESPAN` grid step (`1D` = 1 day, `0D01:00:00` = 1 hour) |
| `steps` | number of periods; the run ends at `start + steps × period` |
| `max_weight_ppm` | per-instrument limit on a requested target, in ppm of equity (`1000000` = 100 %) |
| `max_gross_ppm` | gross limit, in ppm of equity |
| `buy_policy` | `'SCALE` or `'REJECT` |

Every key is required. A `{…}` literal does not evaluate its values, so a
`cfg` built from variables needs `(dict [keys…] (list values…))`.

`run.rfl` fixes `cfg` for every snapshot. There is no command-line flag for
it: a different window, fee or limit is an edit to `run.rfl`, and the manifest
records it.

`bt_run cfg instruments bars targets` is the other entry point. It takes the
targets as a `[ts sym target]` table instead of a function, which is how the
fixtures pin down the accounting.

### State and globals

A strategy is ordinary Rayfall. It can keep state in globals between calls
and can read any global, including the full `bt.bars` table. Nothing stops
it from looking ahead. The `view` is the convention, and the causality test
(below) is how a strategy proves it follows it.

If a strategy keeps state, reset it when `(at ctx 'k)` is 0. `run.rfl` runs
the strategy and the baseline in the same process, and the fixtures run
several strategies in one process.

The `bt` dictionary and the `bt_` and `st_` prefixes belong to the kernel
and the helpers. One run at a time per process: the kernel keeps the whole
run (configuration, inputs, positions, records) in `bt`, under one level of
keys, and each run starts by replacing it.

## Reading the results

`./run.sh STRATEGY SNAPSHOT OUT` refuses to overwrite an existing `OUT`,
verifies the snapshot's checksums, then runs the strategy and `buyhold` under
the same configuration. Before writing anything it checks, for each run:

- `equity − cash0 = realized + unrealized − fees` at every snapshot;
- the ledger reconciles to cash, fill fees to ledger fees, traded notional to
  ledger trade flows, and positions to ledger quantities;
- cash and positions never go negative, and no fill exceeds its order;
- every decision kept the position limits;
- every daily equity change is the sum of the per-instrument price P&L minus
  that day's fees.

A failed check fails the run. Then it writes:

| Path | Contents |
|---|---|
| `OUT/report.md` | metrics side by side, per-instrument attribution, reconciliation statement |
| `OUT/manifest.json` | parameters, `cfg`, assumptions, and identities: framework git revision (`-dirty` if `backtest` has uncommitted or untracked files), snapshot checksum, Rayforce binary SHA-256 |
| `OUT/<name>/*.csv` | every record table, plus `attribution.csv` |

The report for `trend` on the bundled snapshot starts like this:

```text
| Metric | trend | buyhold |
|---|---|---|
| Total return | 65.39% | 42.88% |
| CAGR | 20.05% | 13.84% |
| Annualised volatility | 31.01% | 57.19% |
| Sharpe (rf 0) | 0.74 | 0.51 |
| Max drawdown | -36.74% | -61.88% |
| Net P&L (USDT) | 65393.7 | 42879.7 |
| Gross P&L before fees (USDT) | 67887.4 | 42977.7 |
| Fees (USDT) | 2493.69 | 98 |
| Annual turnover (x equity) | 5.42 | 0.24 |
| Fills | 249 | 3 |
| Average exposure | 42.23% | 98.57% |
| Targets cut by a limit | 0 | 0 |
| Buys scaled for cash | 0 | 0 |
```

Conventions:

- Metrics cover the first decision day (`st_warmup`) to the end of the run.
- Returns are daily and annualised over 365 periods; the risk-free rate is 0.
- Gross P&L is net P&L plus fees.
- Turnover is traded notional over average equity, per year.
- Exposure is market value over equity, averaged over days.

Where to look when something is off:

| Question | File |
|---|---|
| Why didn't it trade? | `order_events.csv`: `REJECTED` rows carry the reason |
| What did the strategy ask for? | `targets.csv`: `requested` as returned, `target` after the limits, `limit` that cut it |
| Was a buy cut for cash? | `order_events.csv`: `FILLED` rows with reason `SCALED`; `fills.csv` has the quantity actually filled |
| Where did the money come from? | `attribution.csv`: per instrument and day, `pnl` = market-value change + cash flow, and `fee` |
| Was a price stale? | `positions.csv`: `mark_ts < ts` means the mark is carried forward |

All amounts in the CSVs are in cash units; prices are in ticks.

A good backtest result is not evidence of an edge, and a bad one is not proof
that there is none. These are single periods with no out-of-sample split; [the plan](plan.md) describes
the evaluation rules (held-out data, a record of every configuration tried,
cost stress) that apply before reading anything into a number.

## Testing

| Command | Checks |
|---|---|
| `make test` | `test/fixture1.rfl`: a hand-calculated run (walked through in [contracts.md](contracts.md)) and the identities |
| | `test/fixture2.rfl`: submission rejections, input validation, row-order independence |
| | `test/fixture3.rfl`: causality, strategy-result validation, mark rules, attribution |
| | `test/fixture4.rfl`: position limits, `SCALE` and `REJECT` buys, eligibility and ranking, the limit check, all hand-calculated |
| | `test/fixture5.rfl`: `xsmom` on the twelve-instrument snapshot, on the view and in features mode: causality, row-order independence, every run check |
| | `test/fixture6.rfl`: typed periods, exact nanosecond grids, long durations and timestamp records in both kernels |
| | `test/equivalence.rfl`: the vectorised kernel against the scalar reference kernel on fixtures and real snapshots, and `xsmom` in features mode against the view form; all records identical |
| | `test/oracle.py`: independent Python accounting oracle, 50 seeded scenarios with three instruments and 16 steps under the `REJECT` buy policy |
| `make test-oracle` | Run the independent accounting oracle alone; position limits and `SCALE` have separate hand-calculated fixtures |
| `make test-run` | `test/determinism.sh`: two full `run.sh` runs, byte-identical |

A test script raises on the first failure and prints `PASS fixtureN` at the
end. `test/assert.rfl` holds the assertions: `check`, `check_col`,
`check_tbl` and `check_raises`.

### Checking your strategy for look-ahead

`test/causal.rfl` runs a strategy on the data and on a copy altered from day
497 on. Everything up to day 497 (targets, orders, fills, equity) must be
identical, and the results after it must differ. `fixture3.rfl` multiplies
every price by 3, which suits a time-series strategy. A ranking is blind to a
factor that every instrument shares, so `fixture5.rfl` multiplies each symbol
by a different factor. To check a new strategy, load its file in the fixture
that matches it and add one line:

```clojure
(causal "trend" strategies.trend)
```

Day 497 must be a day on which the strategy would trade. Otherwise a leak
that only affects trading days goes unnoticed: the `probe` strategy in the
same file exists because a weekly strategy was blind to a one-day look-ahead
on a non-rebalance day.

## Rayfall pitfalls

Rayfall follows kdb+/q closely. Most of the pitfalls below are language
semantics rather than bugs; others are runtime limitations with fixes
tracked upstream. These are not specific to the backtester.
[rayforce#817](https://github.com/RayforceDB/rayforce/pull/817) documents query
name resolution and `take` cycling.

### Current upstream status

Checked on 2026-10-23 against upstream `dev` and the linked PRs. A merged
fix requires a build containing that merge; the minimum build in *Quick
start* does not imply that it contains every later performance improvement.
The open PRs below are optional experimental builds, not requirements for
running the current backtester.

| Area | Current state | Consequence for the backtester |
|---|---|---|
| Durations | Nanosecond `TIMESPAN` values merged in [#917](https://github.com/RayforceDB/rayforce/pull/917) | Already adopted: use spans such as `1D` for periods, and `TIMESTAMP` for bar times. An integer conversion is still used for grid indices. |
| Parallel sortedness checks on symbol keys | Lexical-rank comparison merged in [#937](https://github.com/RayforceDB/rayforce/pull/937) | Addresses the symbol-lock contention found in the [October 21 profile](audit-2026-10-21.md#frame-pointer-profiles). Those measurements describe the older build. |
| Joins that preserve left rows unchanged | Left-column reuse merged in [#943](https://github.com/RayforceDB/rayforce/pull/943) | Avoids copying left columns for identity output mappings; joins that change the row mapping still need to gather data. |
| Quoted mutation of locals and parameters | [#950](https://github.com/RayforceDB/rayforce/issues/950), implemented in open PR [#954](https://github.com/RayforceDB/rayforce/pull/954) | Upstream still rejects local `alter`; the PR lets `alter` and `insert` update the resolved local binding, with copy-on-write for shared values. The backtester still uses global `bt` state. |
| Cost of writing global bindings | [#951](https://github.com/RayforceDB/rayforce/issues/951), implemented in open PR [#955](https://github.com/RayforceDB/rayforce/pull/955) | Upstream still scans the global binding array on writes. The PR indexes writes by symbol; it is independent of local mutation and does not remove dictionary traversal. |
| Integer overflow | [#809](https://github.com/RayforceDB/rayforce/issues/809) remains open | Keep the fixed-point bounds in [contracts.md](contracts.md); arithmetic is not a checked-overflow guard. |

The merged performance fixes do not remove the framework's own scaling
costs: building a view at every step, recording every instrument's position,
and checking identities through large joins. Use features mode to avoid
repeated view construction. See [benchmarks.md](benchmarks.md) for the
measured workloads and revisions; microbenchmark improvements do not by
themselves establish an end-to-end speedup.

### Language and mutation pitfalls

- **A local beats a column of the same name inside a query.** In a lambda,
  `(let c 100)` followed by `(select {from: v x: (+ c 1)})` uses 100, not the
  `c` column, in every clause. Names resolve to an earlier alias, then a
  local, then a column, then a global. This is the opposite of qSQL, where
  the column wins. Don't name locals `ts`, `sym`, `o`, `h`, `l`, `c` or `v` in
  code that queries bars.
- **A quoted symbol inside a query is a column if one has that name.**
  `(== sym 'c)` compares with the `c` column, not the symbol `c`. Write the
  constant as `(quote c)` or pass it in through a variable. q's
  functional-select escape, `enlist`, does not work here: `(enlist 'c)`
  enlists the column.
- **`map` returns a list, not a typed vector.** Unlike q, Rayfall never turns
  a list of same-type atoms into a vector by itself. Wrap the result in
  `(as 'I64 …)` (`st_targets` does).
- **`take` cycles, as q's `#` does.** `(take [1 2 3] -5)` is `[2 3 1 2 3]`,
  not an error or a shorter result. Check the length before taking a window.
  `select … take:` stops at the table's length instead.
- **`[A B]` is a symbol vector.** Square brackets are a literal and do not
  evaluate names. A vector of variables or timestamps needs `(enlist …)`.
- **The empty symbol is a lone `'`.** It is SYM's null (`(nil? ')` is
  true) and works wherever a symbol does: `(take ' n)`, `[' SCALED]`,
  `{a: '}`, and it prints as `'` everywhere, so a printed vector reads back
  as the same value. The symbol `null` is an ordinary symbol, not the null.
- **`{…}` does not evaluate its values either.** `{a: x}` stores the symbol
  `x`. Build a dictionary from variables with `(dict [a b] (list x y))`.
- **A live alias makes `alter` copy.** `(alter 'bt.v set i x)` updates in
  place, but only while nothing else holds the vector: after `(let w bt.v)`,
  each `alter` copies it. Index into it (`(at bt.v i)`) instead of keeping a
  local copy across updates.
- **Loop with `(times [i n] …)`.** The body sees the index `i`, from 0 to
  n − 1, and `let` inside it rebinds the enclosing function's locals, so an
  accumulator works as in a `while` loop. Keep `while` for loops that stop
  on a condition.
- **`I64` arithmetic wraps silently on overflow**, as q's does
  ([rayforce#809](https://github.com/RayforceDB/rayforce/issues/809) asks
  whether Rayfall keeps that). `qty × price × mult` is the largest product in
  the kernel; contracts.md gives the bound.
- **On upstream `dev`, `alter` cannot target a local or parameter.** It
  raises `alter: local bindings are not supported`. The earlier bug that
  read a local and wrote a global was closed by rejecting the operation
  ([#810](https://github.com/RayforceDB/rayforce/issues/810)); that did not
  add local mutation. Until [#954](https://github.com/RayforceDB/rayforce/pull/954)
  is merged and included in your build, keep named mutable vectors in a
  global or under a key of a global dictionary, as `bt.rfl` does. Repeated
  functional growth of a local with `concat` creates replacement values;
  moving state into locals alone does not make it an in-place append.
  On the PR build, local mutation follows lexical lookup and real aliases
  still force a copy; the change does not make every `alter` operation
  allocation-free.

## Adding data

A snapshot is a directory with `bars.csv`, `instruments.csv`,
`snapshot.json` and `SHA256SUMS`. Its pinned checksums live in
`data/<snapshot>.sha256`, and a `make` rule rebuilds it from its source.

- `bars.csv`: `ts,sym,o,h,l,c,v`. `ts` is the bar open; prices are in ticks;
  volume is in 1e-8 base-asset units.
- `instruments.csv`: `sym,mult,min_qty,min_notional,tick,lot`. The kernel
  reads the first four; `tick` and `lot` document the units.

`tools/fetch_binance_klines.py` builds a snapshot for any Binance spot symbol
with a tick and lot entry in its `META` table, over a range of months. The
entries are the exchange filters as fetched from `GET /api/v3/exchangeInfo`.
Every historical price must be a whole number of today's tick, and
`lot × tick` must be a whole number of cash units, or the build fails. TRXUSDT
fails both: its 2023 prices use a finer tick, and that tick times its lot is a
fraction of the cash unit.

A new snapshot needs a pinned `.sha256` file and an entry in the Makefile's
`SNAPSHOTS` list. The kernel rejects off-grid timestamps, duplicate
`(ts, sym)` keys, unknown symbols and non-positive prices rather than
repairing them.

## Benchmarks

`bench/run.sh OUT [TIMEOUT_S] [SIZES] [PERIODS]` builds synthetic snapshots
with `tools/synth_bars.py`, which seeds a random walk per instrument (cost
only, no market structure), and measures each configuration:

- **`bench/bench.rfl`, once:** the time of each phase (loading, the run, the
  one-off `prepare`, the strategy calls, the checks) and the peak RSS.
- **`hyperfine` 2, if that run took under a minute:** one warm-up, then five
  timed runs of the whole process, for the mean, spread and instruction count.

The modes separate the costs: `kernel` (accounting only), `hold` (adds
building the view), `xsmom`, `trend` (view strategies) and `xsmomf`
(features mode). `KERNEL=ref/bt_ref.rfl` measures the reference kernel,
`DATA_DIR` moves the synthetic data, and `MODES` picks the modes. Results go
to `OUT/results.jsonl` and `OUT/env.txt`; the published runs and their
conclusions are in [benchmarks.md](benchmarks.md).

## Formatting

`.rfl` files are indented by rayfall-mode, the Emacs mode in
[tree-sitter-rayfall](https://github.com/vbmithr/tree-sitter-rayfall), so the
files and the editor always agree. `make fmt` re-indents every `.rfl` file
here, and `make fmt-check` fails if one would change. Both need Emacs 29 or
newer with the Rayfall grammar installed; `RAYFALL_MODE` points at the mode's
directory (default `~/code/rayforce/tree-sitter-rayfall`).

The style is classic Lisp indentation:

- a call's arguments line up under its first argument, or under the
  function name when the first argument starts a new line;
- vector elements and dictionary pairs line up under the first one;
- the body of `fn`, `do`, `while`, `times`, `set` and `let` is indented 2,
  counted from the outermost such form that opens on the same line, so
  `(set f (fn [x]` keeps its body at column 2;
- `if` is an ordinary call: its branches line up under the condition;
- closing brackets stack at the end of the last line.

## Layout

| Path | Contents |
|---|---|
| `bt.rfl` | the kernel: loading, validation, the event loop, records |
| `ref/bt_ref.rfl` | the scalar reference kernel, kept as the oracle for `bt.rfl` |
| `bench/` | `bench.rfl` (one measurement) and `run.sh` (the grid) |
| `report.rfl` | identities, attribution, metrics, CSV output |
| `run.rfl`, `run.sh` | the run entry point |
| `strategies/` | `common.rfl` helpers and the example strategies |
| `test/` | fixtures, assertions, the causality helper, determinism check |
| `tools/` | snapshot builders: Binance archive and synthetic |
| `data/` | pinned snapshot checksums; snapshots are built here |
| `doc/` | this manual, [contracts.md](contracts.md), [plan.md](plan.md), [benchmarks.md](benchmarks.md) |
