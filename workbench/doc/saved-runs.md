# Native saved runs, format v1

Status: initial implementation verified end to end with Rayforce
`2.11.5.r134.g65de9fe5` (2026-10-24). The original validation loop is retained;
the engine fix for [#987](https://github.com/RayforceDB/rayforce/issues/987)
removed the export blocker without an application workaround.

`make saved-test` exports the hand-calculated fixture, validates and publishes
all eight native record tables, reopens the bundle in a fresh Rayforce service,
checks records and exact metadata over IPC, and verifies corruption rejection.
The standalone reproduction remains in `test/rayforce-nested-loop-or.rfl` as
a regression reference. Older affected engine builds cannot complete export;
the separate native validation refuses their incomplete output.

## Ownership and layout

Rayforce writes each record table through `.db.splayed.set` and reloads it
through `.db.splayed.get` to check schemas, nulls, values and row counts.
Metadata is saved with `ser`; no financial values are converted to JSON or
recomputed in OCaml. Reopening does not load strategy or backtester source.

The OCaml `backtest_bundle` library owns staging, checksums, syncing and the
publication boundary. The application supervisor already owns the run's
output path, so these are application responsibilities rather than substitutes
for missing engine storage features.

```text
RUN/
  metadata.rfn
  checksums.json
  COMPLETED
  tables/
    0/
      targets/...
      orders/...
      order_events/...
      fills/...
      ledger/...
      positions/...
      equity/...
      attribution/...
    1/...
```

Numeric directories correspond to the ordered strategy vector in metadata;
strategy names never become filesystem paths. Native shared symbol files and
lock files are retained and included in the checksum inventory. Original row
order is preserved. The service recreates `wb_row` indices before any query,
so record identities remain stable after reopening.

`metadata.rfn` is one native serialized frame containing:

- Format version, run ID, strategy IDs and per-table row counts.
- Recorded framework, engine and snapshot identities.
- Structured effective configuration, including native timestamp and timespan.
- Structured parameters for each strategy and the recorded snapshot location.
- Optional currency/decimal scale and per-instrument multiplier/tick/lot scales.
- Engine-computed summaries, their evaluation windows and assumptions.
- Existing configuration/parameter text for reference, never for evaluation.

Format v1 accepts the shared parameter model: null, bool, int64, finite float,
string, symbol, timestamp, timespan, lists and dictionaries. Unsupported values
are rejected rather than coerced. Unknown format versions fail explicitly.
Native engine storage/wire compatibility remains required; this is not a
promise of compatibility across every engine release or CPU byte order.

Missing display scales remain absent, with raw labeled units displayed by a
future viewer. A complete artifact does not imply that missing currency or
instrument display metadata has been invented. Fixture provenance is explicitly
synthetic; production producers must record their real effective identities.

## Publication

`Bundle.publish` creates a private sibling staging directory and supplies its
absolute path to a producer callback. The producer must finish and stop writing
before returning. A fresh Rayforce process independently opens the staged
native tables and validates their schemas/counts. OCaml validates the metadata,
configuration, parameters and summaries through the same codec used by IPC.

Only then does the publisher write SHA-256 checksums and the completion seal,
fsync all regular files and directories, and atomically move the directory to
its final name. The parent directory is synced after the move. The destination
must not exist and is never replaced, including a competing empty directory.
Ordinary controlled failure removes staging output. Abrupt process death may
leave a hidden staging directory, but cannot publish an incomplete final run.
A failure syncing the parent after rename can leave an already published run;
that error must be surfaced, not resolved by overwriting the destination.

Exclusive rename is a small platform binding because Core/Async expose ordinary
rename without a no-replace flag. Linux uses `renameat2(RENAME_NOREPLACE)`;
macOS has a corresponding `renamex_np(RENAME_EXCL)` branch, not tested here.
Other platforms or unsupported filesystems fail rather than fall back to an
overwriting rename. The call runs in an Async worker and releases the OCaml
runtime lock while in the OS. This is a Core API gap, not a Rayforce limitation.

## Export and reopen interfaces

Load `rayfall/bundle.rfl` after `rayfall/service.rfl`, publish retained run
snapshots with `wb_publish`, then call `wb_save_staged directory options`.
Options contain `effective_config`, `parameters`, `snapshot`, `cash_scale`
and `instruments`. The last two may explicitly be null. See the executable
producer example `test/export-bundle-fixture.rfl`.

The CLI is built by `make build`:

```sh
bundle=../_build/default/workbench/bin/workbench_bundle.exe

# Requires a Rayforce build with the #987 fix.
"$bundle" publish -directory /absolute/output/new-run \
  -service-directory "$PWD/rayfall" \
  -producer "$PWD/test/export-bundle-fixture.rfl" \
  -producer-cwd "$PWD/../backtest"

"$bundle" verify -directory /absolute/output/new-run
bash rayfall/serve-bundle.sh 7701 /absolute/output/new-run
```

The output parent must exist. `-producer-arg ARG` may be repeated to pass extra
startup argument tokens without constructing executable source. The producer
receives absolute staging/service paths even when run from another directory.

`serve-bundle.sh` checks the completion seal, exact file inventory and hashes
before replacing itself with Rayforce. The native loader checks version,
schemas, Core time range and row counts again, then exposes the existing API.
A reopened run reports `Version 1` and `Validated_complete`. A directory with
missing markers, changed files, unknown versions or invalid metadata is refused.
The completion seal establishes validated publication, not authenticity against
someone who can replace both the artifacts and checksum index.

## Validation and engine requirements

`make test` covers the storage-independent metadata and filesystem behavior:
exact int64/temporal metadata, unknown versions, interrupted writers, concurrent
publishers, no replacement of existing destinations, corruption detection and
staging cleanup. Those tests use a stub native validator, named in their output.
They make no claim about power-loss testing.

`make saved-test` additionally exercises the real engine and a fresh IPC
service, including all eight tables, original row IDs, a 2^53+1 integer,
one-nanosecond timestamps/spans, and rejection of a modified native column.
Standalone probes also preserved empty native SYM tables. This test requires
an engine with the #987 fix; the full workflow passed on the build above.
No fallback CSV parser, value repair, alternate iteration or OCaml financial
calculation has been added to bypass an engine failure.
