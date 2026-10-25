# Identity left-join gather prototype

Based on Rayforce `d7153e72af7b766f17d38483a594f5976b824a57`.
The patch retains left columns only for flat LEFT joins whose completed
left index mapping is exactly `[0, ..., left_rows - 1]`. This avoids their
allocation, gather and metadata propagation. Shared columns keep their
null bitmap, string pool and symbol domain; updates still use copy-on-write.
Duplicate expansion, reordered radix output and FULL joins keep gathering.
No sort code is changed.

## Matched backtester measurement

Both binaries were built locally with `make release -j8` and identical
settings, first from the unmodified base, then changing only `join.c`.
The backtester uses the already projected `report.rfl` in both variants.
Hourly 100-instrument data: `data/synth-1h-100`, xsmomf, 24 bars/day.
One discarded warm-up per variant, then three fresh processes each,
shuffled with seed 22; no concurrent compilation or tests in this sample.
The earlier exploratory sample overlapped validation and is excluded.

| Median | Base | Candidate | Change |
|---|---:|---:|---:|
| Post-run checks | 1139.00 ms | 1033.27 ms | 9.3% less |
| Entire process | 4.007 s | 3.917 s | 2.3% less |
| Peak RSS | 1607.8 MiB | 1588.6 MiB | 19.3 MiB less |

Check ranges: base 1120.70–1146.35 ms; candidate 1013.85–1056.53 ms.
Process ranges: base 3.997–4.017 s; candidate 3.898–3.921 s.
This is a small experiment on a shared host, not a universal speedup claim.
Raw results and binary/source hashes are retained here. The measurement
driver has historical absolute paths; recreate its binaries from the base
and patch before reusing it.

## Validation

- 111/111 join-related tests under ASan/UBSan with four secondary workers.
- New Rayfall regression: null values, symbols, nested lists, source/result
  update isolation, unmatched rows, duplicate expansion and FULL joins.
- Extended C ownership regression: pointer sharing, copy-on-write, source
  release, null bitmap, string-pool lifetime and a large order-preserving
  join. ASan/UBSan, two secondary workers.
- Backtester fixtures 1–6, reference equivalence and independent accounting
  oracle: 50 seeds, three instruments, 16 steps, REJECT.
- `git diff --check` clean.

The first large ownership fixture incorrectly assumed radix output retains
left row order. The optimization declined that mapping correctly. The
fixture now uses a small build side to test a large order-preserving join;
the existing join suite covers radix result correctness.
LeakSanitizer required running outside the sandbox's thread-inspection
restriction; the successful runs keep LeakSanitizer enabled.

## Reviewable code

`rayforce.patch` includes engine code, C and Rayfall regressions, join
documentation and a standalone benchmark. Apply with `git apply` to the base
above. The working copy is `/tmp/rayforce-identity-join`. Published as
[PR #943](https://github.com/RayforceDB/rayforce/pull/943), commit `aff43d99`.
The candidate is not installed.

## Review correction

[Slice fallback and radix regression](review-fix/README.md) records the
current PR correction (`6217b31d`) and fresh measurements. The original
measurements above describe the first prototype.
