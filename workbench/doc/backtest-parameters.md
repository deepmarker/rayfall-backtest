# Backtest parameters: current behavior and intended design

Status reviewed on 2026-10-25. The kernel already accepts configuration and a
strategy descriptor as values. The missing piece is an experiment entry point
that accepts those values from the CLI or GUI instead of taking the examples
embedded in source files.

## Where values come from today

| Location | Responsibility | Current values or behavior |
| --- | --- | --- |
| [`run.rfl`](../../backtest/run.rfl), `cfg` | Simulation and portfolio constraints, shared by the main strategy and baseline | Initial cash 100000 USDT; fees 1000 ppm (10 bp); start 2023-10-01; period 1 day; 1096 steps; maximum weight 400000 ppm (40%); maximum gross 1000000 ppm (100%); buy policy `SCALE`. Cash is stored as integers in 1e-8 USDT units. |
| [`strategies/trend.rfl`](../../backtest/strategies/trend.rfl), descriptor `params` | Trend signal and sizing inputs | `lookback=90`, `vol_window=30`, `vol_target=0.5`, `every=7`, `buffer=0.98`. |
| [`strategies/xsmom.rfl`](../../backtest/strategies/xsmom.rfl), descriptor `params` | Cross-sectional momentum inputs | `lookback=28`, `top=3`, `every=7`, `buffer=0.98`. |
| [`strategies/buyhold.rfl`](../../backtest/strategies/buyhold.rfl), descriptor `params` | Baseline sizing input | `buffer=0.98`; buy once at the common warm-up boundary. |
| [`strategies/common.rfl`](../../backtest/strategies/common.rfl), `st_warmup` | First trading step and reported evaluation boundary | Hard-coded to 91, independently of each strategy's lookback. Shared by the examples and baseline. |
| [`run.sh`](../../backtest/run.sh) | Select inputs, verify checksums and record runtime identity | Accepts strategy name, snapshot directory and output directory. It does not expose simulation or strategy parameter overrides. |
| GUI launcher | Choose a strategy module, snapshot and output location | Calls the existing script. It does not yet edit configuration or strategy parameters. |

A strategy descriptor is `{name params run prepare}`. `run.rfl` loads the
selected module and passes its descriptor with `cfg`, instruments and bars to
`bt_run_strategy`. The kernel supplies the descriptor's `params` to the
callback through `ctx.params`, and to optional feature preparation as
`prepare bars params`. Strategy callbacks therefore already consume explicit
parameters; they need not read their defaults back from the source file.

For the daily examples, `lookback`, `vol_window` and `every` are counts of
observations/steps, not timespans. `vol_target=0.5` is an annualized volatility
target under the example's daily conventions. `buffer=0.98` multiplies target
capital by 0.98, leaving sizing headroom for fees and price gaps; it is not a
98% cash reserve. This is distinct from the engine's fee setting and position
limits.

## Current limitations and pitfalls

- Changing the normal CLI/GUI experiment currently requires editing `cfg` or
  the strategy descriptor defaults in source. Programmatic callers can build
  their own dictionaries and descriptors and call `bt_run_strategy` directly.
- Warm-up is separate global policy. Changing a lookback does not adjust the
  91-step boundary; a larger window can require more history. Trend indexes
  history directly, so parameter/history validation matters. The baseline
  starts at the same shared boundary to keep the comparison interval aligned.
- A configurable `period` in the kernel does not make these examples generic
  intraday strategies: their annualization uses 365 and their reporting is
  written for daily data. Other frequencies need explicit supported semantics.
- The report currently prints starting capital as the literal `100000 USDT`.
  Changing `cfg.cash0` would leave that sentence incorrect. See GUI-B01 in the
  [backlog](gui-backlog.md).
- Legacy `manifest.json` stores configuration/parameters as formatted text.
  Native bundles already retain structured effective configuration and
  per-strategy parameters, but the GUI does not yet provide an editor or
  configuration replay flow. Recorded results do not imply editable inputs.
- The descriptor has no parameter schema for editor labels, types, units,
  ranges or cross-field constraints. `bt_check_strategy` checks descriptor
  shape and that `params` is a dictionary; that is not full parameter validation.

## Intended design

Keep three distinct responsibilities:

- **Strategy definition:** executable callbacks, parameter schema and defaults,
  plus history requirements. Defaults are convenient starting values, not
  mutable global experiment settings. The engine validates strategy-specific
  constraints and the history needed by the selected values.
- **Experiment specification:** one immutable value selecting strategy and
  baseline, snapshot, simulation configuration, parameter overrides and output
  identity. Record the resolved warm-up and evaluation interval explicitly.
  Both strategies must be compared over the same declared interval, with
  sufficient history available before its first decision.
- **Runner:** resolve defaults and overrides once, validate everything before
  simulation, execute the strategy and baseline, check accounting, and publish
  the effective specification with the result. Reports derive values and units
  from that effective specification.

The proposed `Model.run_spec` and `Providers.Runner` are the existing starting
point; see [shared interfaces](gui-interfaces.md#runner-contract). They are
contracts, not the current launch implementation. The current `run_spec` also
needs a deliberate policy for baseline parameters, warm-up/evaluation and
strategy schema discovery; its existence does not resolve those choices.

CLI and GUI should submit the same typed specification. A saved experiment
file can preserve it for reruns. The GUI reads parameter metadata, edits a
per-tab draft and submits a copy. Rayforce remains authoritative for semantic
validation and financial calculations. No GUI action should rewrite shared
`run.rfl` or strategy source to configure an experiment.

Suggested precedence is strategy defaults followed by explicit experiment
overrides, rejecting unknown keys and invalid types. Store both the submitted
specification and resolved effective values, including defaults, so later
changes to defaults cannot silently alter a replay. Treat a changed source
revision or snapshot as a new experiment, with visible provenance.

`run.rfl` should ultimately be orchestration rather than the owner of the one
editable experiment. Keep today's values as a named example preset. Implement
this through GUI-01 in the [backlog](gui-backlog.md), then build the parameter
editor on the same runner interface used by the CLI.
