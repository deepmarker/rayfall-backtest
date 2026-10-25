# Backtester GUI: OCaml inspection workbench

Date: 2026-10-24

Status: shared interfaces, an Async IPC Reader and a typed Rayfall read
service are implemented in the OCaml workspace, along with a
[native saved-run viewer](native-viewer.md) for summary, equity and linked
records. The launcher supervises the existing CLI and publishes a native bundle;
the full structured Runner interface is not implemented yet. Native saved-run publication and reopening pass
with the engine fix for [#987](https://github.com/RayforceDB/rayforce/issues/987); details are in
[saved-runs.md](saved-runs.md). See
[gui-interfaces.md](gui-interfaces.md) for the concrete types and contracts. The current interfaces are described in [manual.md](../../backtest/doc/manual.md), and
accounting and record semantics remain defined by [contracts.md](../../backtest/doc/contracts.md).

## Objective

Build an OCaml desktop shell for inspecting, comparing and eventually
launching Rayfall backtests. Start with completed runs rather than a visual
strategy editor or an embedded simulation engine.

The first useful deliverable is opening an existing run and investigating
one drawdown through to its contributing positions and trades. This gives
immediate value while testing the graphics and data-loading choices.

Rayforce remains responsible for simulation, accounting, validation and
metrics. OCaml owns presentation, run orchestration and navigation between
records. Keep strategy development in the existing editor workflow.

## Graphics library

[imguiml-ft](https://github.com/let-def/imguiml-ft) is used by the initial saved-run viewer. Its README describes Dear ImGui docking, FreeType font
support, and GLFW/OpenGL3 backends. Its generated bindings expose a fairly
low-level API through Ctypes; provide a small OCaml widget layer rather than
spreading pointer and buffer management through application code.

Treat charting as an early prototype, not an assumed complete capability.
The advertised library surface is ImGui and its backends, rather than a
complete financial plotting toolkit. Verify zoom, hover, linked selection,
large time series and table scrolling before committing to a larger UI.

The current changelog marks the new version unreleased. Pin a known revision
and check its build on the intended platforms. The package declares Dune
3.15 or newer and native graphics/font dependencies. If this project needs
binding changes, keep the amended dependency as a git submodule pointing at
a published fork, following the existing dependency convention.

References:

- [README and build requirements](https://github.com/let-def/imguiml-ft/blob/main/README.md).
- [Binding and context example](https://github.com/let-def/imguiml-ft/blob/main/test/test_imguiml.ml).
- [Package dependencies](https://github.com/let-def/imguiml-ft/blob/main/imguiml-ft.opam).
- [Changelog](https://github.com/let-def/imguiml-ft/blob/main/CHANGELOG.md).

## Where the GUI is useful

| View | Questions it answers |
|---|---|
| Equity, drawdown, cash and exposure | When did performance deteriorate, and what changed? |
| Linked execution timeline | Which target produced this order, event, fill and ledger entry? |
| Instrument inspector | What were the holdings, marks, fees and P&L at the selected time? |
| Rejections and constraints | Which requests were rejected, scaled for cash or cut by position limits? |
| Attribution | Which instruments contributed to the selected interval's P&L and fees? |
| Run comparison | What changed between parameter sets, strategies or engine versions? |

Use one shared time cursor and time range across panels. Selecting a drawdown
updates positions, attribution, targets, orders and fills together. Selecting
an order follows its `order_id` through events, fills and ledger records.
Preserve each record's actual timestamp and ordering; the target decision
and the subsequent execution need not occur on the same bar.

Make stale marks visible using `mark_ts` versus the snapshot timestamp. Show
recorded rejection, scaling and limit reasons directly.

Execution records can explain recorded engine decisions. They do not contain
every intermediate strategy feature or signal. Explaining why a strategy
requested a particular target requires an optional diagnostic export or a
separately designed deterministic replay. Do not present inferred strategy
reasoning as recorded evidence.

## Architecture

Keep the GUI core independent of the larger application, using small Dune
libraries with the following responsibilities:

| Module | Responsibility |
|---|---|
| `run_model` | Typed run metadata, schemas, units, timestamps, quantities and record identifiers. |
| `run_store` | Load completed runs, index records, and provide filtered pages and chart series. |
| `run_jobs` | Start Rayforce processes, collect logs, and track completion and cancellation. |
| `workbench` | Selected runs, instrument, time range, order and comparison settings. |
| `ui` | ImGui widgets, layout and charts over prepared data. |

Run each experiment in a separate Rayforce process with its own output
directory. This fits the kernel's current global `bt` state, isolates
experiments, and separates GUI failures from simulation failures. Embedding
the Rayforce C runtime is not required for the first version.

Keep window, ImGui and OpenGL calls on the UI thread. Data loading, indexing
and process supervision run in background workers. Deliver completed results
and status messages to the UI; never block rendering on a file read or a
simulation. Associate asynchronous requests with their run and selection so
an old response cannot replace a newer selection.

## Initial data interface

Use the typed Async IPC Reader to inspect immutable run snapshots. Existing
`manifest.json`, `report.md` and per-strategy CSV files remain compatibility
exports. Native saved-run bundles provide the intended durable reopen path;
the implementation requires an engine with the Rayforce #987 fix.

Store structured engine-computed summaries, units and measurement conventions
in versioned native metadata, preserving integer and temporal precision. Do not parse Markdown tables or
implement accounting and performance metrics a second time in OCaml. Chart
transformations may use exported series, but the reported financial results
remain the engine's responsibility.

Keep source amounts and quantities as exact integers. Formatting applies the
snapshot's scales. Convert values to floating point only for drawing. Keep
nanosecond timestamps as integers too; subtract a suitable time origin before
conversion to plotting coordinates to avoid losing precision unnecessarily.

The current launcher creates output directories before the run completes.
Directory existence is therefore not proof of a successful completed run.
Introduce an explicit completion marker or publish a staging directory by
atomic rename after validation and export. Failed and cancelled runs retain
logs and a clear status and are not registered as completed results.

## Launching and comparing experiments

The launcher currently accepts a strategy, snapshot and output directory;
configuration is still largely written in `run.rfl`. Before adding a useful
parameter editor, define a structured, versioned run specification shared by
CLI and GUI. It should identify the strategy, typed parameters, snapshot,
initial cash, costs, time grid, period and position/cash policies.

Validate the specification in the runner. The GUI should not rewrite strategy
source or `run.rfl` to change parameters. Record the effective specification,
code revision, snapshot identity and runtime identity with each run. Every
experiment gets a new output directory.

Start comparison with the existing buy-and-hold baseline, then allow arbitrary
completed runs. Display differences in snapshot, costs, warm-up, measured
interval, units, strategy parameters and code/runtime identities. Align chart
ranges explicitly; metrics measured on different intervals must remain
identified as such. Use the engine's documented annualisation conventions.

## Performance

Virtualize tables and render only visible rows. Cache formatted cells and
prepared series rather than allocating Ctypes objects and parsing data on
every frame. Reuse interop buffers where practical.

Load large records on demand. Equity is a natural initial chart source;
positions can contain millions of rows and should not all become UI objects.
Keep filters, sorting and bounded series preparation in the Rayforce service,
with reusable native indexes/orderings where profiling justifies them. The
viewer receives prepared pages and samples rather than scanning CSV files or
materializing entire position tables as OCaml UI objects.

Downsample chart data to the viewport while retaining local extrema, so a
narrow drawdown or exposure spike is not hidden. Keep exact records available
for inspection and export independently of the display sample.

## Delivery milestones

| Milestone | Deliverable and acceptance condition |
|---|---|
| Graphics prototype | A docked layout, virtualized large table, and equity chart with zoom, hover and shared selection; demonstrate responsive input with representative data. |
| Completed-run viewer | Open a real run and its baseline, select a drawdown, and follow contributing positions and trades through existing record identifiers. |
| Experiment launcher | Submit a validated run specification, display progress/logs, cancel a job, and register only successfully completed outputs. |
| Experiment comparison | Filter completed experiments by parameters and compare aligned series with visible differences in provenance and measurement intervals. |

The first prototype can use fixtures and synthetic series. The completed-run
viewer must then work with actual backtester outputs before the launcher or
experiment-management surface grows.

## Parallel work and dependencies

Most foundational work can proceed in parallel after agreeing on a small
shared contract: run identity, schema versions, units, record identifiers,
selection types, and the asynchronous page/series interfaces. Define those
interfaces and a small representative fixture first; implementation details
can evolve behind them.

| Workstream | Can start independently | Depends on | Integration result |
|---|---|---|---|
| Graphics and widgets | Docking, chart interaction, table virtualization using fixture data. | Shared selection and series/page types. | Panels consume real `run_store` results without changing widget contracts. |
| Run model and storage | Native bundle validation/reopening and typed IPC filtering. | Existing output schemas and shared types. | A real run supplies pages, series and record links to the viewer. |
| Runner and exports | Structured run specification, summary export and completion protocol. | Current CLI/kernel contracts; agreement on exported versions and units. | CLI and GUI launch the same validated experiment. |
| Inspection and comparison | Navigation logic and comparison rules using fixtures. | Shared types; graphics and storage implementations for real integration. | Shared time/order selection updates all panels consistently. |
| Job supervision | Process lifecycle, logs and cancellation using a test command. | Runner interface for real experiments. | Launcher registers successful runs and distinguishes failure/cancellation. |

A useful split is graphics, storage, and runner/export work in parallel.
Inspection and job supervision can develop against fixtures or test commands,
but their final integration has the dependencies shown above. If staffing is
limited, prioritize graphics and storage; the first useful viewer does not
require the launcher.

Keep accounting and metric definitions in the engine; parallel work should
not create competing implementations of those rules. Separate modules and
small interface changes reduce shared-file conflicts. Integrate frequently
with the same fixture, then a real run, rather than waiting for independently
finished subsystems.

## First implementation step

Agree on the shared model and one completed-run fixture, then build the
window/table/chart prototype and the output reader in parallel. Demonstrate
this workflow before expanding scope:

1. Open an existing run and its baseline.
2. Select a drawdown interval on the equity chart.
3. Inspect the contributing instruments and their positions.
4. Follow an order through its recorded events, fills and ledger entries.
5. Read exact values and return to the corresponding time on the chart.
