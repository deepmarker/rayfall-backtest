# Data-reader feasibility in the pinned engine

Static source review on 2026-10-25 against
`65de9fe547492b8b068ee9e097e5d2eab14c7580`, the revision pinned by this repository.
These are scoped findings, not a claim about every later upstream revision.
No engine code was changed or built for this investigation. The proposed
[contract](rayfall-data-contract-v1.md) remains unadopted. This follows
[Morsel's latest review](https://github.com/RayforceDB/rayforce/issues/994#issuecomment-6399075780).

## What exists and what is missing

| Capability | Source evidence | Feasibility conclusion |
| --- | --- | --- |
| Heap block sizes | `ray_order_for_size`, `BSIZEOF`, `ray_direct_map_size` and `ray_block_data_bytes` in `mem/heap.*`. Buddy blocks include the value header; direct mappings include a prefix and page rounding. | Reuse allocator-owned sizing. Do not independently add a second header or reimplement rounding in the parser. A pre-allocation admission interface still needs to cover the actual allocation path. |
| Cached/direct allocations | `heap_alloc_direct` can select a larger cached mapping and replace the requested map size with its cached size. | The minimum size estimate is insufficient. Budget admission must see the chosen size before acquisition, or budgeted calls must constrain cache selection to admitted sizes. Checking after allocation violates the proposed boundary. |
| Resize peaks | `ray_realloc_raw` allocates/copies a replacement before freeing the old block; within capacity it reuses the block. | Reader-local wrappers can reserve the replacement while keeping the old charge live. Failed growth leaves the old allocation/charge intact. Do not subtract the old charge first. |
| Allocation tracing | `ray_mem_trace_begin/end` is a process-wide active trace, aggregating all threads, with one scope active at a time. | Useful diagnostic evidence, not an isolated reader-local pre-allocation budget or ownership ledger. |
| Other allocation paths | Symbol storage and arena chunks use `ray_sys_alloc/realloc`; constructors can allocate multiple blocks internally. Arena used bytes differ from reserved chunk capacity. | Counting only top-level `ray_alloc` requests misses work. Budget-aware construction must include nested allocations and allocated arena chunks without double-charging their suballocations. |
| Single-name atomic intern | `sym_intern_nolock` already has inspect/reserve/commit phases, including dotted segments. `ray_sym_bytes_upper` and `ray_arena_reserve` support reservation. | Reuse this design. It is a single-name guarantee, not failure atomicity for every symbol in one document. |
| Batch interning | `ray_sym_intern_batch` and `_no_split` loop over names under one lock; their header explicitly permits partial results on failure. | One lock is not one transaction. Earlier names can remain committed when a later name fails. No whole-read rollback guarantee follows from the batch API. |
| Reserve-side effects | `sym_reserve_capacity` can grow hash/strings/sidecars/arena in stages. Earlier capacity growth can survive a later reservation failure even with no new interned name. | Distinguish name-set atomicity from allocation rollback. Admission must bound capacity growth too; strict cleanup of failed reservation capacity needs a staged plan or an explicit retained-capacity policy. |
| Existing parser | `parse_symbol`/`parse_dict` intern names during parsing; literal parsing can construct values immediately. | Existing parse/eval cannot serve as a no-side-effect validation pass. A data-only parser needs reader-local candidates and intrinsic construction. |

Source links at the inspected revision:
[heap implementation](https://github.com/RayforceDB/rayforce/blob/65de9fe547492b8b068ee9e097e5d2eab14c7580/src/mem/heap.c),
[heap interface](https://github.com/RayforceDB/rayforce/blob/65de9fe547492b8b068ee9e097e5d2eab14c7580/src/mem/heap.h),
[symbol implementation](https://github.com/RayforceDB/rayforce/blob/65de9fe547492b8b068ee9e097e5d2eab14c7580/src/table/sym.c),
[symbol interface](https://github.com/RayforceDB/rayforce/blob/65de9fe547492b8b068ee9e097e5d2eab14c7580/src/table/sym.h),
[arena implementation](https://github.com/RayforceDB/rayforce/blob/65de9fe547492b8b068ee9e097e5d2eab14c7580/src/mem/arena.c),
[system allocator](https://github.com/RayforceDB/rayforce/blob/65de9fe547492b8b068ee9e097e5d2eab14c7580/src/mem/sys.c),
[parser](https://github.com/RayforceDB/rayforce/blob/65de9fe547492b8b068ee9e097e5d2eab14c7580/src/lang/parse.c).

## Small implementation proofs to request upstream

These are proposed focused C-level proofs, not a second parser or allocator
implemented in the workbench. Do not put policy branches into every unrelated
engine operation or hold a global intern lock throughout parsing.

### Reader-local budgeted construction

Use an explicit reader context with an ownership ledger and allocator-backed
admission. For every owned block, record one charged size including its
headers once. Reserve before allocation, release the reservation on allocation
failure, and release the live charge when the owned block is released. Charge
cached capacity and replacement peaks using the same allocator sizing rules.

Start with strings, one typed vector and LIST construction. Demonstrate that
all transitive allocations are covered, including parser buffers and cleanup
on injected failure. Then add DICT/TABLE and symbol staging. Merely wrapping
calls around ordinary constructors is insufficient if those constructors can
allocate unseen temporary blocks internally. Either supply narrow budget-aware
construction paths or make their transitive allocation plan explicit.

Arena accounting needs a deliberate choice: charge owned backing chunks and
headers once, not both the full chunk and every carved slot. Retained chunk
capacity stays charged until ownership ends, even if a bump pointer rewinds.
Use ordinary engine values for returned results; reader ledger teardown must
not free data whose ownership was transferred to the caller.

### Whole-document symbol commit

Stage and deduplicate decoded symbol bytes locally, using provisional indices
kept in private reader structures. Validate the complete value and plan every
remaining allocation before committing anything to the global intern table.
Do not expose temporary indices as usable global symbol IDs.

Prove a whole-batch inspect/reserve/commit operation: under the appropriate
lock, recheck existing names and host admission, reserve all symbol/sidecar/
arena growth with budget accounting, then perform a commit with no remaining
fallible allocation. Reuse the existing single-name phases where possible.
If the plan cannot guarantee that last phase, provide real rollback rather
than composing the current partial batch API.

Allocate the result skeleton and fixup storage before commit. Post-commit
symbol-ID fixups and final publication must be nonallocating/nonfailing; dict
and table construction cannot hide a late failure after global symbols become
visible. Define whether value symbols use no-split interning and ensure any
required dotted-name side effects are included in the plan.

Demonstrate failure behavior at each reservation site. A failed read must not
add names, change existing IDs or retain unbounded speculative capacity.
Repeated successful reads remain subject to host symbol admission; per-read
limits cannot supply a global quota or symbol reclamation mechanism.

### Limit-profile behavior

First document that writer success under a byte cap does not guarantee reader
acceptance under its depth/node/allocation/symbol budgets. Test that a shallow
byte limit can still produce a reader depth or node rejection with no fallback.
A paired acceptance profile can be considered later, once construction costs
are actually predictable and versioned. Do not promise it from matching bytes.

## Evidence needed before implementation is considered feasible

- One charged-size definition shared with the relevant allocator paths,
  including small slab reuse, oversized direct-cache reuse and sys/arena growth.
- Cap-1/cap/cap+1 and resize-peak tests; allocation failure before/after each
  reserve step; independent counters showing no budget overrun.
- Invalid input and allocation-failure tests proving the intern name set and
  existing IDs are unchanged. Repeated failures must not grow speculative
  symbols or uncharged capacity. Exercise concurrent successful interning.
- A late-construction failure test proving symbol commit occurs only after
  every fallible result-building operation, including DICT/TABLE internals.
- Reader ownership cleanup tests and confirmation that unrelated kernel paths
  retain their existing allocation behavior. The existing corpus is not proof
  of these implementation properties.

The useful next upstream deliverables are these two narrow capabilities and
their focused tests. Syntax choices, default numbers and complete reader/writer
implementation can follow. No application-side fallback should mask their
absence.

## Subsequent implementation proofs

Draft upstream [PR #1019](https://github.com/RayforceDB/rayforce/pull/1019)
implements the two boundaries in separate commits on `dev` base `e463902f`:

- [`c2aa2a4b`](https://github.com/vbmithr/rayforce/commit/c2aa2a4b): explicit
  reader-owned allocation context and string/I64-vector/LIST builders. Includes
  exact charged sizing, context-local post-admission failure injection,
  replacement peaks and an admitted path that skips oversized cache matches.
- [`978d78f1`](https://github.com/vbmithr/rayforce/commit/978d78f1): separate
  staged value-symbol publication, private replacement capacity and
  nonallocating commit. Existing partial-batch callers are unchanged.

Focused ASan/UBSan validation: ten new proof tests, three existing direct-cache
cases, four single-name atomic-intern cases, twenty arena cases and eleven
source checks pass. The concurrent publication case also passes ThreadSanitizer
with no reported race. The full suite is left to CI.

The failed-publication tests force capacity growth and check unchanged names,
IDs, outputs, global table descriptor and existing dotted metadata, plus system
allocation counters returning to baseline after cleanup. A real concurrent
ordinary intern caller agrees on IDs. A prebuilt LIST result is fixed up and
retained without allocating after publication.

This is a draft implementation basis, not an adopted format or full reader.
It does not establish nonfailing DICT/TABLE finalization. Partially materialized
lazy symbol tables are explicitly rejected. The record ledger and per-commit
arena chunk need production cost work; host symbol quotas are not imposed on
unrelated intern entry points. The allocation budget measures owned blocks,
not process RSS or all allocator infrastructure. Parser budgets, full type
coverage and the actual text reader/writer remain future work.

The workbench's engine pin and launch path do not depend on this experimental
branch. Recheck the PR's reviewed revision and scope before adopting anything.
