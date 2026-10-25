# Rayforce integration and next improvements

Date: 2026-10-24

The workbench uses a separate Rayforce process and typed requests over Async
IPC. Rayforce owns simulation, accounting, metrics and record queries. OCaml
owns presentation, selection and process supervision. The small Rayfall read
service is an application API, rather than a replacement database engine.

## Current friction

| Area | Current approach | Direction |
|---|---|---|
| Run state | Backtester state lives in global `bt`; runs need isolated processes. | Refactor to efficiently mutable local run state once the language support is available. |
| Parallel runs | A process pool can run independent experiments. | Real parallel lambda evaluation could share read-only inputs between worker VMs. |
| Cancellation | Async Reader now requests POSIX urgent-data cancellation before discarding its connection. | Keep best-effort semantics; extend profiling and deployment coverage. |
| IPC lifecycle | One request per connection; application dictionaries carry IDs and generations. | Keep this adapter unless native multiplexed RPC becomes available. |
| Record queries | Prototype scans filters and sorts for each request. | Profile and exploit native queries, storage, sortedness and reusable orderings. |
| Publication | Native export, atomic publication and reopening pass with the #987 engine fix. | Build the saved-run viewer and general run supervisor. |

Global state and sequential lambda evaluation are engine-related constraints.
The publication protocol, GUI lifecycle and run metadata are application work.
None requires moving financial calculations into OCaml.

## Local state and independent runs

[#950](https://github.com/RayforceDB/rayforce/issues/950) and
[PR #954](https://github.com/RayforceDB/rayforce/pull/954) concern efficient
mutation of local/parameter targets through quoted `alter` and `insert`.
That enables a future backtester refactor; merging it does not itself make
our global-state engine reentrant, establish worker safety, or implement
parallel evaluation. Ordinary global `set` and local `let` rebinding remain
distinct operations.

Independent strategies or parameter combinations are natural parallel jobs.
The time steps within one stateful backtest generally depend on preceding
steps. Parallelism should be across runs first, not blindly across time.

As inspected on this date, `pmap` delegates to `map`, and
[#948](https://github.com/RayforceDB/rayforce/issues/948) tracks the mismatch.
Native vector/query kernels can run in parallel independently of that issue.
A process pool remains a practical baseline: bound both process count and
cores per process to avoid oversubscription. Native saved market-data tables
may help input reuse; measure actual resident memory and loading costs before
claiming zero-copy sharing.

## Cancellation — implemented

Rayforce already supports POSIX out-of-band cancellation in
[`src/core/ipc.c`](https://github.com/RayforceDB/rayforce/blob/dev/src/core/ipc.c).
A TCP urgent byte raises SIGURG and requests interruption at engine query
checkpoints. It is scoped to the active connection. A normal cancel message
would sit unread while the evaluator is busy.

Implemented in workbench commit `0790d5260` and IPC commit `53c9e2f`.
The Async `cancel_and_close` operation is used for cancellation and timeouts.
Connections,
handshakes, ordinary traffic, deadlines and teardown remain on Async. The
single urgent-byte send uses `Fd.syscall ~nonblocking:true` on the existing
Async socket, with the OS send primitive underneath. It creates no blocking
client or additional socket.

Cancellation is best effort: successful byte delivery is not an execution
acknowledgement, an engine without support may continue working, and the
mechanism is POSIX-specific. The connection is discarded even after a
successful send, because native response frames have no request IDs and a
late response or urgent byte must never affect a subsequent request on the
same connection. A later workbench request reconnects. Cancellation teardown
discards unsent buffered output instead of waiting for a stalled peer to drain it.

The live tests establish that a query is actually running, cancel it, then show
that the server answers another connection promptly. Merely observing local
socket closure does not prove that engine work stopped. Tests also cover idle
connection isolation, buffered-output teardown, urgent bytes on workbench
cancellation and timeout, queued cancellation, stalled peers and shutdown.

## Query efficiency next

Measure realistic records, row counts, filters and repeated zoom/pan requests
before changing the engine. The current implementation is deliberately small
and still constructs full filter masks and repeats sorts. Candidate improvements:

- Use existing query planning and supported native indexes for common filters.
- Reuse immutable table orderings or selection indices where profiling supports it.
- Use bounded ordered queries/top-k paths where supported instead of full sorts.
- Preserve stable source IDs through all transformations.
- Keep chart reduction near the data, preserving extrema and null gaps.

Only request new Rayforce primitives after identifying a missing capability
in those existing facilities. Query cancellation and bounded UI results remain
necessary even after query execution becomes faster.

## Publication and GUI

The [native bundle implementation](saved-runs.md) provides metadata,
checksums, atomic publication and reopening. Full Rayfall export passes with
Rayforce `65de9fe5`, which fixes
[#987](https://github.com/RayforceDB/rayforce/issues/987). The original
null-aware validation remains intact; incomplete exports are still refused.
Filesystem tests explicitly stub native validation, while `make saved-test`
checks the real engine, fresh-process reopening, exact IPC values and
corruption detection.

The versioned bundle contains native tables, structured effective
configuration, exact units, engine summaries and provenance. Publication
occurs only after validation, with an atomic completion boundary. Saved runs
reopen without replaying a strategy or parsing a Markdown report.

Then implement the minimal viewer: summary, equity curve, linked time cursor
and record inspection. Add the general run supervisor and comparisons on that
foundation. A simulation worker and result-serving process need not be the same
process: long evaluations should not make inspection of completed runs wait.
