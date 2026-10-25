# Upstream request: let joins consult an index

Filed as <https://github.com/RayforceDB/rayforce/issues/595> on 2026-09-19.
Measured on `rayforce` 2.6.2 (the build carrying `bc350ddc`).

---

## Summary

The index routing table in `docs/docs/queries/indexes.md` lists five
consumption sites: `filter`, `where key IN … group by key`, `ORDER BY`,
`distinct`, and `find`/`in`. Joins are not among them. `join`, `left-join`,
`inner-join` and `anti-join` build a fresh hash over their whole input on
every call, whatever indexes or attributes the key columns carry.

For a workload that joins a small key set against a large table repeatedly,
that is the dominant cost, and no existing accelerator can reduce it.

## Measurement

A 30 s `perf --call-graph fp` of a market-data service (766 instruments,
~27k rows/s, a 351k-row table joined per batch):

```
34.72%  hash_row_keys
13.28%  ray_vec_is_null
 9.07%  gather_fn
       + ~18% libc memcpy, all under the join worker tasks
```

73% of samples were in the query worker pool, dispatched from
`ray_anti_join_fn` and `exec_join_flat`. At the table sizes above, one
`(left-join [venue instrument] levels keys)` costs ~13 ms whether `keys`
names one book or ten — the cost is the left side, every time.

For scale: the same service's actual state maintenance, `(upsert 'levels 4
rows)` with ~900 rows, is 260 us. The joins around it are two orders of
magnitude more expensive than the update they exist to support.

## What we are asking for

**A join consumption site in the routing table.** When a join key column
carries `.idx.hash` (or `part` backing), probe it instead of building a new
hash over the whole side. The fallback contract would be the same as every
other site: identical results, scan path when ineligible.

Two details that matter for this shape of workload:

1. **Compound keys.** Our joins key on `[venue instrument]`, and the four
   `.idx.*` kinds occupy one per-column slot today. A join site is only
   useful here if a multi-column key can be probed — either a compound index,
   or probing the more selective column and checking the rest.
2. **Symbol columns.** `.idx.hash` is wired to `filter` EQ/IN for
   integer-family columns only, while `find`/`in` accept `SYM` needles. Join
   keys in market data are overwhelmingly symbols, so a join site restricted
   to integer families would not reach this workload.

## An alternative that needs no new index

`upsert` already maintains a key map for keyed tables (`21dba3f1`,
`917d667f`, `5b997dd1`). A table written with `(upsert 'levels 4 rows)` has a
live map over its first four key columns. Letting a join on a **prefix** of
those keys probe that existing map would cover our case without introducing
a new index kind or a new build cost — the map is already there and already
maintained.
