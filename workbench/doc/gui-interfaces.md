# Backtester GUI shared interfaces

Date: 2026-10-24

Status: the [OCaml component](../README.md)
implements shared types, schemas, validation and an Async IPC Reader. The
[Rayfall service](../rayfall/README.md) serves immutable in-memory snapshots,
pages, sampled series and engine-computed summaries. The structured Runner remains a
contract; the GUI launcher currently supervises the existing CLI. The [native viewer](native-viewer.md) implements saved-run inspection. Native saved runs pass end-to-end validation on
Rayforce `65de9fe5`, which fixes [#987](https://github.com/RayforceDB/rayforce/issues/987);
see [saved-runs.md](saved-runs.md) for format and test boundaries.

## Process and transport model

Rayforce runs in a separate process. The current viewer owns a read service
for saved runs. The CLI-backed experiment launcher owns a strategy process group; Rayforce owns simulation, accounting and metric
calculation. Completed output files remain the durable, offline-readable
result. Interactive queries now use the Async IPC Reader; the durable native
publication/reopen path remains to be implemented.

Both a file reader and an IPC reader implement `Providers.Reader`, exposing
identical describe, summary, row-page and series operations. The UI sees no
SQL, Rayfall source or transport details. Backend construction and connection
credentials belong to each concrete adapter, outside these shared types.

The OCaml request protocol is not a new Rayforce wire format. An IPC adapter
must encode approved operations using the existing engine API. Validate field
names against known schemas and pass values as data, rather than building
arbitrary executable text from UI input. Read immutable run data in a
worker-owned namespace; do not query a global `bt` while another experiment
resets it.

Rayforce's synchronous request/reply connection does not itself supply these
logical request IDs. An adapter serializes requests per connection and
associates replies with the submitted request; independent workers may
complete requests out of order. Blocking IPC and file reads stay off the
UI thread. Neither transport requires embedding the engine runtime.

## Identity and exact values

`Model.scope` identifies a run and one strategy within it, including the
baseline where present. A run ID is assigned by the catalog/supervisor; a
folder basename is not a globally unique identity. Current manifests have no
run ID, so the first reader needs an explicit catalog mapping.

Order IDs and sequence counters are scoped to that run and strategy. A
`record_id` additionally includes the record table and its zero-based source
data row. Headers do not count as rows. Filtering, sorting and paging never
renumber record identities, and completed artifacts remain immutable.

The model uses Core’s `Time_ns.t` and `Time_ns.Span.t` directly, with exact
nanosecond precision. The IPC library’s `Timestamp`/`Timespan` modules convert nanoseconds at the
storage/IPC boundary: Rayforce timestamps start at **2000-01-01**, whereas
Core uses the Unix epoch. Conversion rejects the engine’s `INT64_MIN` null
sentinel and values outside Core’s signed 63-bit range before arithmetic.
Core therefore supports a narrower time/span range than Rayforce; providers
must report out-of-range data rather than truncate or wrap it.
Nullable cells use `Null`, and nullable chart values use `None`.

Time ranges are nonempty and half-open: `[start_inclusive, end_exclusive)`.
A cursor is an exact time, not a bar number; decision and execution records
retain their own timestamps. UI selection uses one scope and optional
interval, cursor, instrument, order and record. The controller must clear
incompatible selections when switching scopes.

Cash, fees, quantities and prices stay integers. Field metadata distinguishes
cash units, lots, price ticks, ppm and counters. Human-readable cash, tick
and lot scales are exact decimal strings supplied by metadata; absence means
display raw labeled units, not an assumed currency. Floating-point values
are reserved for appropriate exported statistics and drawing coordinates.

## Current schemas and legacy output

`Model.current_schema` follows the eight exported CSV headers from `bt.rfl`
and `report.rfl`. In particular, targets are quantities in lots, not ppm,
and attribution exports `sym,ts,dmv,cash_in,fee,pnl`. The record fixture is
[exported from fixture 1](../test/fixtures/fixture1/README.md), and the
OCaml test checks every header against its descriptor.

The current `manifest.json` stores configuration and strategy parameters as
Rayfall-formatted strings, has no schema version or explicit completion
marker, and does not carry all display units. A reader exposes
`Legacy_unversioned`, retains those strings verbatim, and leaves structured
specification and missing metadata absent. It must not evaluate those strings
to guess configuration values. Snapshot/instrument metadata may supply units
when explicitly available and matched to the run's snapshot identity.

`Legacy_unverified` is distinct from `Validated_complete`. Existing output
directories are created before the run succeeds, so file presence alone is
not completion evidence. The native bundle prototype implements a versioned
completion boundary and requires an engine with the #987 fix. Unknown export versions
return `Unsupported_version`.

`Summary` requests return engine-exported metrics, the evaluation interval,
warm-up steps, return period, annualisation factor, risk-free rate and
assumptions. Legacy CSV runs still lack a structured summary, so their readers
return `Unavailable` rather than parse Markdown or duplicate calculations.
The native prototype stores structured summaries in binary metadata, and the
in-memory service already supplies engine-computed summaries over IPC.

## Reader requests and replies

Each `Protocol.request` carries a unique provider-lifetime `id` and a
selection `generation`. The controller increments generation when selection
changes, records outstanding IDs, and accepts responses only for an expected
ID and current generation. `is_current` checks the generation part; it is not
a replacement for tracking IDs. Stale replies are discarded even if a prior
cancel request could not interrupt active work.

`submit` is a nonblocking enqueue. It rejects invalid requests, duplicate
IDs or a full queue without accepting work. Every accepted request produces
exactly one response with its original ID and generation, including errors.
Replies may arrive out of order. The backend retains no mutable ownership of
published arrays; consumers treat response buffers as read-only.

Row pages specify one table, optional time/instrument/order filters, sort
columns, an offset and a limit. Offset is nonnegative; page size is 1–10,000.
Filters combine with AND. Instrument filtering requires a `sym` column, and
order filtering requires `order_id`; unsupported filters are errors, not
silent no-ops or implicit joins. Linked order-event navigation therefore uses
its order ID rather than an unavailable instrument field.

Default row order is exported source order. An explicit sort uses the stated
column priority, with source row as the final stable tie-breaker. Apply
filters, then sorting, then paging. `total_rows`, if computed, counts filtered
rows before paging. Unknown totals remain absent rather than zero. Cells
must match the returned schema, and row IDs must match the requested scope
and table.

Series requests name an integer-valued field and exact interval. Tables with
a `sym` field require a single instrument, avoiding accidental interleaving
of unrelated instruments. Viewport width is 1–16,384 pixels and the explicit
point budget is 1–65,536. These are initial protocol bounds, not UI defaults.

A series is either exact or an explicitly labeled extrema envelope with its
source count and bucket count. Keep actual timestamps, source IDs and order;
first/min/max/last samples must not become invented mean values. Preserve
null discontinuities so drawing cannot bridge missing data. Never exceed the
point budget: if preserving the required extrema/gaps cannot fit, report
`Unavailable` and ask the controller to narrow the range or request a larger
budget. Accounting totals do not come from sampled chart data.

## Cancellation, backpressure and shutdown

The UI calls bounded, nonblocking `poll` methods with a positive event budget.
A reader's cancellation is best effort: completed work can still arrive,
while work cancelled before completion responds `Cancelled`. Moving to a new
selection never waits for old work to stop.

`shutdown` stops accepting work and requests cleanup. `is_closed` becomes
true only after resources are closed and accepted responses have been drained.
A cancelled or closed connection must not leave accepted requests hanging.
Queue capacities are adapter configuration; rejection is `Busy`, not an
unbounded buildup of work.

## Runner contract

`Model.run_spec` is a proposed versioned, structured input, currently version
1. It contains run/job identity, strategy, typed parameters, snapshot identity,
configuration and a new output directory. Symbols, strings, timestamps and
spans remain distinct parameter values. The existing `run.sh` does not accept
this structure yet. Its Rayfall adapter and codecs are separate work.

The supervisor enqueues `start`, rejects duplicate IDs and existing output
paths, and lets the runner perform authoritative semantic validation. It
records the effective configuration and runtime identity; the GUI must not
rewrite `run.rfl` or invent accounting rules. Existing buy-and-hold baseline
behavior remains runner-owned.

A job emits ordered `Started`, log and optional progress updates, followed by
one terminal `Completed`, `Failed` or `Cancelled` event. Startup/validation
failure may go directly to `Failed`. Unknown progress totals remain absent;
progress is not a made-up percentage. A cancellation request is not terminal
until the child has exited and been reaped. A successful process exit alone
is insufficient: `Completed` requires checked, published complete artifacts.
A failed run retains its logs and is not registered as completed.

Logs may be bounded and summarized, but terminal events cannot be dropped.
The runner's shutdown closes active jobs and becomes closed only after all
children are reaped and terminal events drained.

## Parallel implementation boundaries

- Storage implements `Providers.Reader` over current CSVs and manifests,
  reporting missing legacy metadata explicitly.
- Graphics uses the model, fixture records and page/series replies without
  choosing a transport or performing accounting.
- Runner/export work implements the structured specification, summary and
  completion format, with `Providers.Runner` as the UI boundary.
- The IPC adapter implements the same reader against an isolated Rayforce
  process; it does not require changes to widget interfaces.

The current tests cover exact time, nulls, range boundaries, bounded query
validation, stale generations, schema ownership and every exported header.
They do not certify an unimplemented adapter's concurrency or cancellation
behavior. Each concrete adapter will need its own lifecycle and publication
checks against these contracts.

## Implemented IPC backend

The workbench lives under `workbench`, using the existing
`rayforce-ipc` submodule and Async connection. See its README for commands.
The shared library depends on Core; the Reader additionally depends on Async
and the IPC library. All Reader calls belong to one Async scheduler. GUI
frames must cooperate with it, or marshal calls/results through a controller.
The adapter uses Async networking; the IPC library’s urgent-byte primitive
runs through its managed nonblocking descriptor API. The Rayfall
service lives alongside the client under `rayfall/`; its fixture bootstrap
and launcher live under `test/`. The launcher takes the backtester checkout
explicitly and resolves the workbench sources independently of caller CWD.

Typed API v1 dictionaries carry request IDs and generations. Each connection
handles one request at a time. The outstanding-work limit includes queued
requests and undrained replies. Active cancellation/deadlines request engine
cancellation using its POSIX TCP urgent byte, then close the connection;
subsequent requests reconnect. This is best effort rather than an execution
acknowledgement, and failed urgent-byte delivery still closes the connection. `is_closed` waits for abandoned connect attempts and socket
cleanup as well as drained responses. ID history remains until Reader disposal.

Physical source IDs are indexed once at publication. Query filtering, stable
sorting, pagination and extrema/null-gap sampling run in Rayforce, so the
client receives bounded results instead of scanning CSVs or transferring whole
tables. Sampling uses consecutive-record buckets; it returns `Unavailable`
when preserving extrema and gaps would exceed the budget.

The live fixture publishes engine-computed summaries directly, using native
TIMESPAN periods and TIMESTAMP values. It reports `Legacy_unverified` because
registration does not implement durable publication. The existing run script
and CSV exports are unchanged, and legacy directories still have no structured
summary. The native saved-run prototype adds effective configuration, per-strategy
parameters, snapshot identity and optional display units to `run_info`. Native
reopen describes these as `Version 1`/`Validated_complete` only through the
published bundle path. The end-to-end exporter passes with the #987 engine fix.
Graphical inspection and the general runner are follow-up work.
