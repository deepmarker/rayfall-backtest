# What a parallel `pmap` needs from Rayforce

Status (2026-11-02): kept as an investigation, not posted upstream and not being
pursued. Parallel backtests would run as separate Rayforce processes. Source
references are to `dev` at `5c646761`; see also
[rayforce#948](https://github.com/RayforceDB/rayforce/issues/948).

## Goal

Run independent lambda calls on worker threads, with each call reading shared
values and returning a value. The driving case is a backtest parameter sweep:
each run is an interpreted loop over vectors of 100–500 elements, too short for
morsel parallelism, so a sweep uses one core. The backtester's kernel now keeps
all run state in locals and writes no global, so it is ready for this.

## History

- **v1 (#125, 2025-12-01) was parallel.** `pmap_lambda` split the input across
  the executor pool. Each executor created its own interpreter and heap
  (`core/pool.c`), received a clone of the environment in `pool_prepare`, and
  ran with atomic refcounts.
- **v2 (`4a3a0c72`, 2026-04-29) replaced the engine.** The new `ray_pmap_fn` calls
  `ray_map_fn`, with the comment "parallel not implemented yet (sequential
  fallback)". `949fd686` later reworded this to "sequential alias", because the
  VM is thread-local and evaluation is single-threaded. No commit in this
  repository removes a working v2 parallel path; v2's own history is in another
  repository.
- v1 had no guard against global writes: `set` wrote the shared
  `runtime_get()->env.variables` from whichever thread ran it.

## What v2 already has

- Per-thread heaps with cross-thread free (`mem/heap.c`), and atomic refcounts
  on workers (`pool.c:496`) and on the main thread during a dispatch.
- Most interpreter caches are `_Thread_local`: the global-lookup hints, resolve
  cache, closure templates, compiler symbols and query state in `env.c`,
  `eval.c`, `compile.c` and `query.c`.
- `ray_pool_dispatch_n`, which runs N tasks.
- `rt->vms` is an array, and `ray_vm_init` takes an id; the IPC hook code even
  says "id -1: not a pool VM". Today `n_vms` is always 1.

## Prerequisites

### Required

1. **A VM on every worker.** Workers only initialise a heap and atomic refcounts
   (`pool.c:495`). `__VM` is bound only by `ray_runtime_create`, and user code
   running with `__VM == NULL` is the failure `ipc.c:332` describes. Populate
   `rt->vms` per worker, for the worker's lifetime or for the dispatch.
2. **Thread-safe lazy compilation.** `ray_compile` runs on first call and writes
   into the lambda object (`compile.c:1404`, including `LAMBDA_NLOCALS`), with no
   synchronisation. Two workers can make the first call of one shared lambda.
   Either compile the reachable lambdas before dispatch, which cannot see names
   resolved at call time, or publish the compiled form once with a CAS or lock.
3. **A rule for global writes: reject them inside `pmap`.** Writers hold
   `env_lock`, but `env_global_lookup` reads without it and `ray_env_set` releases
   the old value, so a worker reading a global can retain a freed value. A
   read-only environment during the dispatch, raising a clear error on `set`, a
   global `alter` or `insert`, `del` and `load`, removes this whole class. The
   `ray_parallel_flag` could gate it.
4. **Errors and control flow per call.** `raise`, `return` and traces live on the
   VM (`raise_val`, `return_val`, `trace`). Define which error `pmap` reports
   (the lowest index, so results stay deterministic), release the other results,
   and make `g_eval_interrupted` and the query cancel flag stop every worker.
5. **Audit of shared mutable state reachable from `eval`.** Candidates seen so
   far: anything that caches on a shared value (attributes, lazily built indexes,
   symbol ranks); the direct-mapping cache and `g_fmap` in `mem/heap.c`; the
   lazy initialisers `g_self_sym` and `g_call_self_sym`; `format`'s settings.
   `table/sym.c` says interning must precede a parallel region, yet interning
   also takes a lock: settle which is true, because a strategy can create symbols.
6. **Worker heap lifetime for long calls.** Results allocated on a worker outlive
   the dispatch, and `ray_heap_reclaim_worker` requires `ray_parallel_flag` clear.
   Today's tasks are short morsels; a backtest allocates for seconds. Check that
   a long-running worker reclaims memory, and that results survive the worker's
   next dispatch and are freed correctly on the main thread.

### Design decisions

7. **Nested parallelism.** Dispatch is single-producer, and a nested dispatch
   would corrupt the ring (`pool.h:175`). `ray_pool_par_dispatch_ok` already keeps
   guarded kernels serial inside a dispatch. Every site must go through such a
   gate, including `pmap` within `pmap` and raw `ray_pool_dispatch` calls
   (`query.c:6572-6628` for one). The rule to document: the outer `pmap` wins, and
   kernels inside a callback run serially. A `pmap` over few items that each do
   large vector work can then be slower than `map`, so it may need a threshold or
   a choice of level.
8. **Scheduling.** Tasks must be claimed one at a time, because runs differ widely
   in length. v1's chunks of `l / num_chunks` would strand work behind one slow run.
9. **Output.** `println` and journal writes from workers: serialise them, or
   document interleaving.
10. **Result typing.** `map` collects homogeneous results into typed vectors
    (#968); `pmap` must collect in input order and give the same result.

### Verification

11. `test/rfl/hof/pmap.rfl` under TSan and ASan, with calls that share a first-call
    lambda, allocate, raise, and read shared tables and globals; and `map` and
    `pmap` compared for identical results.

## Suggested order

Rule 3 and the VM (1) first, since neither requires concurrency to test: a
single-worker `pmap` already exercises the worker VM and the rejection. Then 2
and 4, then the audit (5) under TSan, then 6.

## Why v2 may have dropped it (inference)

Nothing in this repository states the reason. The evidence fits a change of
architecture more than a rejection of the feature: v2 is built around the DAG and
morsel kernels, so its pool runs C functions over data and its workers never
needed a VM. v1's `pmap` did not carry over because its base, one interpreter per
executor, no longer existed. The first comment says "not implemented yet". Only
the later one calls it unsafe, and that describes the VM's thread-locality.
