# Backtester workbench

This component lives in this standalone repository and provides:

- `backtest_shared`: Core-based domain types, schemas and query validation.
- `backtest_reader`: an Async IPC Reader and strict typed request/reply codec.
- `backtest_bundle`: native saved-run metadata, atomic publication and reopening.
- A native Imguiml viewer with an equity chart, shared cursor and paged records.
- A [Rayfall service](rayfall/service.rfl) that
  filters, sorts, pages and samples immutable run snapshots inside Rayforce.

The [native viewer](doc/native-viewer.md) opens verified saved bundles using
a read-only Rayforce service. The launcher runs a selected strategy and baseline through the existing CLI,
then opens the published native bundle. **New backtest** creates a separate
tab; closing it shuts down its own job and service. Structured run-spec editing is still planned. The native
saved-run workflow passes with the engine fix for Rayforce #987; see
[saved runs](doc/saved-runs.md) for implementation, tests and requirements. The CSV Reader draft was set aside in favour of IPC.
Existing CSVs remain interoperability exports, not the interactive transport.

Run from this directory:

```sh
make build
make test
make live-test
make saved-test
make viewer-test
make launcher-test
make gui
make gui RUN=/absolute/path/to/saved-run
make fmt
make fmt-check
```

The commands target this component, not the whole workspace test suite.
`live-test` also requires Rayforce, Bash and Python 3; it starts a temporary
loopback-only server, checks real fixture records, and cleans up the process.
The dependencies include Core, Async, the `rayforce-ipc` submodule and the
`imguiml-ft` graphics submodule. See the [viewer guide](doc/native-viewer.md)
for native graphics dependencies and headless rendering checks.
The formatter uses the Jane Street profile pinned in `.ocamlformat`.

## Trying the service

From this directory, start the hand-calculated example, passing the
backtester source directory explicitly:

```sh
bash test/serve_fixture.sh 7701 ../backtest
```

On the owning Async scheduler, construct a Reader and submit a request:

```ocaml
open Core
open Backtest_shared

let reader =
  Backtest_reader.Reader.create ~host:"127.0.0.1" ~port:7701 ()

let accepted =
  Backtest_reader.Reader.submit reader
    { Protocol.id = 1L; generation = 0L; operation = Describe "fixture1" }
```

Poll bounded responses from a cooperative GUI frame callback on the same
scheduler. Never run a blocking graphics loop that starves Async. If graphics
must own a different thread, marshal Reader calls and prepared results through
a controller queue; the Reader and IPC symbol table are scheduler-owned.

There is one request in flight per connection, bounded outstanding work
(including undrained replies), a request deadline, and lifetime-unique IDs.
Cancellation is best effort: an active request sends Rayforce’s POSIX urgent
cancel byte, then closes the connection; later requests reconnect. Failed byte
delivery still closes the connection. This does not promise that server
computation has stopped on every platform or engine version.
`shutdown` rejects new work, finishes accepted requests with terminal replies,
and releases resources. Drain replies before expecting `is_closed`.

The [service README](rayfall/README.md) describes
snapshot registration, summary semantics and the current publication limits.

## Interfaces

- [Model](shared/model.mli): `Time_ns`, exact units, record and run identity.
- [Protocol](shared/protocol.mli): bounded requests, responses and generations.
- [Providers](shared/providers.mli): Reader and future Runner contracts.
- [Reader](ipc/reader.mli): Async lifecycle and connection configuration.
- [Codec](ipc/codec.mli): typed protocol validation and correlation.
- [Interface contract](doc/gui-interfaces.md).
- [Design](doc/gui-design.md).
- [Saved runs](doc/saved-runs.md): native bundle format, validation and engine requirements.
- [Rayforce integration](doc/rayforce-integration.md): current friction,
  cancellation, parallel runs and the next improvements.

Timestamp/Timespan conversion belongs to the IPC library. The model has no
custom timestamp/span types. The small `Time_range` wrapper enforces nonempty,
half-open ranges; Jane Street Interval represents closed intervals instead.

## Rayfall editor navigation

`.rayfall-lsp.json` records the fixture's backtester working directory and
opts into recursive `.rfl` discovery for this workbench directory. New modules
are included automatically; this requires the LSP directory-entrypoint support. This lets rayfall-lsp follow the
fixture's literal loads into `bt.rfl` and `report.rfl`, and find service
functions whose file is loaded through a startup argument. The configuration
is editor context only: it does not execute code or infer argument values.
After upgrading the server binary, use `M-x eglot-reconnect` once.
The LSP workspace must include this configuration directory; configuration
changes are read on navigation requests without restarting the server.
