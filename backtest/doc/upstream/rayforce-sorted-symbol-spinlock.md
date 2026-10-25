# Upstream issue: parallel sortedness checks contend on the global symbol lock

Filed as [rayforce#933](https://github.com/RayforceDB/rayforce/issues/933) on 2026-10-21.

## Summary

Checking that an already ordered `(TIMESTAMP, SYM)` table is sorted repeatedly resolves symbol strings under the global symbol-table spinlock. Parallel workers contend on that lock: on the dataset below the sortedness check is about 15 times slower with `RAYFORCE_CORES=16` than with `1`.

Reproduced on current `dev` `646459984df6c151279bcdce1fb88a90df74b953` (`rayforce-git` 2.10.0.r206), Linux x86-64, Ryzen AI 7 350, 16 logical CPUs.

## Standalone reproducer

Save as `sorted-check.rfl`. No data files or other software are needed:

```clojure
;; Standalone reproducer: no data files or backtester required.
;; rayforce sorted-check-standalone.rfl -- -numeric 0   ; symbols
;; rayforce sorted-check-standalone.rfl -- -numeric 1   ; lexical integer ranks
(set args (at (.sys.args) 'user))
(set n 2630400)
(set ids (til n))
(set syms (asc (as 'SYM (map (fn [i] (format "s%" i)) (til 100)))))
(set ts (as 'TIMESTAMP (div ids 100)))
(set key (if (== (at args 'numeric) "1") (% ids 100) (take syms n)))
(set b (table [ts sym] (list ts key)))
(set elapsed (timeit (set sorted (xasc b [ts sym]))))
(println (format "rows=% sort_ms=%" (count sorted) elapsed))

```

```sh
RAYFORCE_CORES=1 rayforce sorted-check.rfl -- -numeric 0
RAYFORCE_CORES=16 rayforce sorted-check.rfl -- -numeric 0
RAYFORCE_CORES=1 rayforce sorted-check.rfl -- -numeric 1
RAYFORCE_CORES=16 rayforce sorted-check.rfl -- -numeric 1
```

All four tables are already sorted. The numeric control replaces the lexically ordered symbol key with its corresponding integer rank. Only `xasc` is timed; table construction is excluded.

One fresh process per cell with this standalone script:

| Second key | cores=1 | cores=16 |
|---|---:|---:|
| SYM | 115.6 ms | 1406.8 ms |
| lexical integer rank | 17.1 ms | 13.7 ms |

The original bar-shaped dataset (same 2,630,400 rows, 100 symbols per timestamp, actual hourly timestamps) gives medians of three fresh processes:

| Second key | cores=1 | cores=16 |
|---|---:|---:|
| SYM | 80.8 ms | 1229.6 ms |
| lexical integer rank | 17.1 ms | 13.7 ms |

Expected: the already-sorted fast path should not serialize its workers on a global lock per comparison. Sorting semantics and lexical symbol order must stay unchanged.

## Frame-pointer profile

For reliable stacks, I built a clean archive of the same revision with the normal optimized release flags plus:

```text
-g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer
```

Recorded a bar-based workload using:

```sh
perf record -F 999 -e cycles:u --call-graph fp -o profile.data -- ./rayforce workload.rfl
perf report --stdio --no-children --call-graph none -i profile.data
perf annotate --stdio --symbol ray_sym_str -i profile.data
```

On the kernel-only workload (100 instruments, 26,304 hourly steps), 21,555 samples, no samples lost:

```text
84.16%  ray_sym_str
 1.65%  csv_parse_fn
 1.46%  ray_free_last_ref
```

Caller chain:

```text
sorted_check_fn
  ray_sym_domain_str
    ray_sym_str
      sym_lock (inlined)
```

The source/assembly annotation places most `ray_sym_str` samples in the atomic-exchange spin loop (`xchg` / `test` / `pause`). With feature preparation and post-run validation included, `ray_sym_str` is still 61.54% of sampled self cycles (31,605 samples, none lost). These percentages aggregate CPU cycles across threads; they are not wall-time speedup predictions.

## Code path and possible direction

In `src/ops/sort.c`, the generic `sorted_check_fn` compares adjacent symbols using `ray_sym_domain_str` when their IDs differ. For the `(timestamp, symbol)` shape, almost every row within a timestamp group needs that comparison. Runtime-domain resolution falls through to `ray_sym_str` in `src/table/sym.c`, which acquires the global lock for each lookup. The specialized `(SYM, i64-family)` loop handles the reverse key order, not this one.

Could the sortedness scan prepare domain-aware string views or lexical ranks once per symbol key before dispatch, then compare without one global lock round-trip per lookup? Null ordering, symbol domains, lazy materialization and lifetime/concurrent-interning rules would need to be preserved. The existing read-only `ray_sym_strings_borrow` facility has a no-concurrent-interning contract; removing locking from general `ray_sym_str` calls would not be safe.

## Related issues

- #561, fixed by #562: the same per-cell symbol-resolution cost in serialization, addressed by resolving/caching distinct symbols. This report concerns the sort check instead.
- #816, fixed by #847: reusing already ordered input in `select ... asc:/desc:`. That improvement is present in the measured revision; this report concerns contention inside the shared sortedness check itself.

I found no existing issue specifically reporting this sorting lock contention. No runtime patch or local workaround is included.
