# Why PeachQ avoids Rayforce #933

Source inspected on 2026-10-21: PeachQ tag `v0.88`, commit `39a91243`,
matching the installed `0.88-1` package's source release; Rayforce commit
`646459984df6c151279bcdce1fb88a90df74b953`, matching the benchmark binary's
package revision. The installed PeachQ package builds the v0.88 release
with `RAY_MARCH=x86-64-v3`. This is source tracing supported by the existing
Rayforce profiles and benchmark controls, rather than a new PeachQ profile.

## PeachQ's path

1. [`xasc`](https://github.com/peachq-org/peachq/blob/v0.88/src/qlang/q.q#L63)
   constructs a table of key columns, calls `iasc`, and gathers the original
   table using the resulting permutation.
2. [`grade_table`](https://github.com/peachq-org/peachq/blob/v0.88/src/qlang/ops/q_sort.c#L253)
   adds the original row index as a stability tiebreaker and calls
   `ray_sort_indices`, which enters `sort_indices_ex` directly.
3. Before parallel key encoding,
   [`build_enum_rank`](https://github.com/peachq-org/peachq/blob/v0.88/src/ops/sort.c#L1902)
   resolves symbol IDs to string pointers and lengths once, sorts those IDs
   lexically using the cached strings, and builds `rank[intern_id]`.
   Precisely, it processes all IDs from zero through the maximum used ID;
   this is not necessarily just the 100 distinct benchmark symbols.
4. The row loops then read integer ranks from that lookup table. The
   timestamp, symbol rank and row-index keys fit in a packed 64-bit key for
   this workload. The sortedness check at `sort.c:2784` compares these
   encoded integers. Already-sorted input skips the radix passes.

PeachQ still has the global symbol lock: `src/table/domain.c:46` delegates
to `ray_sym_str`, which locks at `src/table/sym.c:751`. The important
difference is that the rank preparation resolves strings serially once per
ID, rather than having multiple workers resolve the same symbols repeatedly
while scanning rows. PeachQ's worker setting is real: `q_sys.c:968` creates
the worker pool; this result is not explained by ignoring `-s`.

## Rayforce's earlier check

Rayforce already contains the same general symbol-rank preparation for its
radix path. However,
[`sort_table_by_keys`](https://github.com/RayforceDB/rayforce/blob/646459984df6c151279bcdce1fb88a90df74b953/src/ops/sort.c#L4531)
runs a separate sortedness precheck before calling `sort_indices_ex`.
Its `sorted_check_fn` resolves two strings whenever adjacent symbol IDs
differ and the preceding keys compare equal.

In this benchmark, the timestamp is equal within each group of 100 rows,
and the symbol changes at every adjacent row in that group. About 99% of
adjacent pairs therefore incur two locked symbol lookups. Increasing the
worker count increases contention on that one lock. The specialized
`(symbol, timestamp)` loop does not apply to these `(timestamp, symbol)`
keys. For already-sorted input the precheck returns early, so execution
never reaches the rank-caching radix path.

At four secondary workers the measured symbol timings are 287.313 ms for
Rayforce and 27.718 ms for PeachQ. Replacing symbols with lexical integer
ranks gives 13.885 ms and 27.321 ms respectively. This supports fixing the
precheck's repeated resolution; it does not establish a general PeachQ
performance advantage or disclose KX q's implementation.

## Suggested fix

Reuse lexical symbol ranks in Rayforce's sortedness precheck, or cache
resolved symbol pointers and lengths before dispatching its workers. Rank
comparisons would also avoid repeated string comparisons. Preserve lexical
ordering rather than comparing raw intern IDs, and retain the existing
null and direction semantics. Validate sorted and unsorted inputs, both key
orders, nonlexical intern order, nulls, and the worker-scaling benchmark.
The existing fast integer-control result suggests retaining the cheap
precheck for integer keys.
