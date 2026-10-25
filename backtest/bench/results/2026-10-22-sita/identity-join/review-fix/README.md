# PR #943 review correction

Commit `6217b31d` addresses both Morsel review findings. Slice-valued left
columns gather independently because slice COW does not detach the parent.
Ordinary columns in the same identity-mapped join still share. A separate
large radix fixture checks equal cardinality, actual reordered keys and
matched left/right payloads.

The slice test reproduces the original source-mutation defect. A deliberate
removal of the identity guard fails the radix payload-association assertion.
These are expected-failure controls, not failures of the corrected source.

Corrected source: 113/113 join tests under ASan/UBSan with four secondary
workers, plus 3/3 identity tests with workers disabled. Backtester fixtures,
reference equivalence and 50-seed independent oracle pass again. The old
full-suite run was interrupted before rebuilding; no full-suite pass is
claimed. CI covers the pushed head.

Fresh matched experiment after the correction: same base binary and local
release settings, current projected report, hourly 100-instrument xsmomf.
One discarded warm-up each and three measurements each, shuffled seed 22,
without concurrent local tests/builds. Median checks: 1146.46 to 1047.97 ms
(8.6% less). Whole process: 4.137 to 4.022 s (2.8% less). Peak RSS: 1608.2 to
1590.1 MiB (18.1 MiB less). Check ranges 1134.08–1163.55 and 1043.04–1051.07
ms; process ranges 4.074–4.326 and 4.011–4.052 s. Shared host, small sample;
not a universal speedup guarantee. Raw samples, logs and hashes are included.

`rayforce.patch` is the complete two-commit PR diff against the base.
