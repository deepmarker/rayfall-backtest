# Workbench IPC service

`service.rfl` provides typed API version 1 for the
[OCaml workbench Reader](../README.md).
The Rayforce wire protocol is unchanged. Each request is a dictionary of
values, not a string containing Rayfall source. The sync hook dispatches
fixed operations and the async hook ignores messages.

## Start an example

Run from the workbench directory, passing the backtester checkout explicitly:

```sh
bash test/serve_fixture.sh 7701 ../backtest
```

This executes the existing hand-calculated accounting fixture, captures its
eight tables and engine-computed summary, and publishes run `fixture1`,
strategy `fixture`. It does not reconstruct a run from CSV or Markdown.

The launcher resolves its own workbench sources independently of the caller's
working directory. It enters the selected backtester directory because the
existing backtester fixture loads its own relative source/data files. It
passes the service's absolute path to the bootstrap as a startup argument.

The GUI launcher now calls the existing `run.sh` with optional workbench
export arguments. `run.rfl` captures each completed strategy and baseline
before resetting kernel state, then writes native staging output. The OCaml
publisher validates and seals it; CSVs and the existing report remain under
`exports/` inside the bundle. Ordinary CLI invocations keep their existing
output contract.

For custom producers, load `bt.rfl` and `report.rfl` from an explicitly selected
backtester checkout and this directory's `service.rfl` by its resolved path
in a dedicated process. The service itself performs no relative file loads.
After each strategy finishes and passes accounting checks,
retain `(wb_capture)` and `(wb_summary warmup_steps)`. Then call:

```lisp
(wb_publish run_id metadata datasets summaries)
```

`datasets` maps strategy symbol keys to dictionaries containing the eight
record tables in `wb_names` order. `summaries` maps the same strategy keys to
engine summaries; a missing summary returns `Unavailable`. Metadata contains
`framework_revision`, `snapshot_sha256`, `rayforce_binary_sha256`,
`rayforce_version`, `config_text`, and `parameter_text` (strategy-to-text dict).
Keep legacy configuration/parameter text as text; never evaluate it to infer
settings. The example is an executable registration reference.

Publication is once per process. Original source-row IDs are attached once,
before filtering/sorting, and underlying source tables remain unchanged.
Snapshots retain table references, so subsequent engine mutation must respect
Rayforce's copy-on-write ownership. Keep simulation and this read service in
separate processes; do not expose a mutable global `bt` as the query dataset.

The service uses local `let` rebinding. Ordinary `set` writes globals on the
installed release. [#950](https://github.com/RayforceDB/rayforce/issues/950)
and [#954](https://github.com/RayforceDB/rayforce/pull/954) concern quoted
`alter`/`insert` mutation targets and remain separate language-policy work;
the service does not depend on that proposal or redefine ordinary `set`.

## Queries

Requests/replies carry `version`, `id` and `generation`. The Reader validates
reply correlation and reconstructs typed model values. Unknown operations,
fields, scopes, versions and invalid bounds are rejected. No client-provided
expression is parsed or evaluated. This replaces the dedicated process's IPC
hooks; it is not an extension to an existing application hook.

- `describe` returns recorded provenance, strategy IDs and legacy text.
- `summary` returns engine metrics, warmup, period, annualisation and window.
- `rows` filters by half-open interval, instrument and/or order; sorts by at
  most 64 keys; and returns at most 10,000 rows plus the filtered total.
- `series` sorts by time with physical row ID as the final tie breaker,
  selects one integer field, and returns at most 65,536 original points.

Row sorts use stable per-key engine sorts, least significant key first, so
physical source order breaks equal-key ties. Pages clamp `take` to remaining
rows: Rayfall otherwise repeats values when taking beyond the source length.

Chart reduction partitions consecutive source rows into at most pixel-width
buckets. It retains bucket endpoints and extrema and both sides of each null
gap, in original time order. If those cannot fit the budget, the service
returns `Unavailable`; it never fabricates averages or bridges a null gap.
Buckets are based on record count, not equally spaced wall-clock durations.

Metrics are returned directly from `bt_metrics`, including its existing
floating-point statistics. Undefined NaN metrics become explicit nulls.
Source record money, quantities and prices remain int64; timestamps and
periods use native TIMESTAMP and TIMESPAN IPC values. The summary's exclusive
end is one nanosecond after the last recorded valuation, so it is included.
The current metrics routine assumes 365 periods/year; this is disclosed in
the summary rather than silently inferred by the client.

## Publication boundary

The in-memory service remains usable and reports `Legacy_unverified`. The
native bundle implementation adds `bundle.rfl` and `open-bundle.rfl`. End-to-end
export, publication and reopening pass with Rayforce `65de9fe5`, which fixes
[#987](https://github.com/RayforceDB/rayforce/issues/987). The separate validation
process still rejects incomplete artifacts. See [saved runs](../doc/saved-runs.md) for the format, CLI and
current test boundaries. The ordinary backtester `run.sh` remains unchanged.
