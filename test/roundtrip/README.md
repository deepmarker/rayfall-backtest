# Rayforce text round-trip corpus

This is the first diagnostic corpus for the contract proposed in
[Rayforce #994](https://github.com/RayforceDB/rayforce/issues/994). It is
independent of backtest data and needs only Python 3.11+ and Rayforce.
It tests the existing **legacy** container printer plus `parse`/`eval`;
it does not implement a configuration reader or establish data-only safety.
Only repository-authored expressions are evaluated. Do not feed external
configuration files into this harness.

## Run

```sh
make compat-test
python3 -I test/roundtrip/probe.py --rayforce /path/to/rayforce
python3 -I test/roundtrip/probe.py --strict
```

The runner creates a unique directory below
`$XDG_CACHE_HOME/rayfall-backtest/roundtrip` (default `~/.cache`) and removes
scripts on completion. Set `--scratch-root` to choose a disk-backed directory;
child processes inherit it as `TMPDIR`. Reports are only written when
`--json /path/to/report.json` is supplied. Keep generated reports outside
tracked source. Reports include executable SHA-256, stdout/stderr and status
per case. Timeout and process crashes are errors, never expected failures.

`make compat-test` is an explicit diagnostic target, not yet part of CI.
The experiment text API and contract are still upstream proposals.

## Contract under discussion

The [proposed v1 tables](../../workbench/doc/rayfall-data-contract-v1.md)
spell out type/identity, reader boundaries and resource-limit accounting,
following Morsel's latest feedback. Numerical limits and API details remain
proposals for upstream agreement.

For a supported data value, the future exact writer/data reader pair must
preserve type, container shape and contents. Exact integers, timestamps and
spans cannot pass through floating-point approximations. Display precision
must not control saved parameter precision. Schema versioning and supported
types must be explicit. Unknown/function/owning-handle values must fail loudly
unless a real representation has been specified.

Keep three properties separate:

- **Logical identity:** types, shape and values, with an agreed null/NaN policy.
- **Representation fidelity:** any stronger requirements, such as preserving
  signed zero or IEEE payload bits, need their own checks and agreed scope.
- **Data-only reading:** no arbitrary evaluation, mutable-global constructor
  lookup or implicit fallback to evaluating code. Enforce input, nesting and
  allocation budgets before expensive parsing/construction.

The current probe covers the first property for a small set of values. It
cannot test a reader that does not exist. It deliberately does not treat
`format`, `ser` bytes or the existing `fmt_eq` comparator as its equality
oracle. It uses direct type/count/key/element checks. It is not a second parser,
evaluator or a universal deep-comparison implementation.

## Fixture and result rules

`cases.json` contains trusted value constructors, direct predicates and links
to known issues. Each predicate must accept its original value before the
round trip runs; otherwise the fixture is an error. Ten cases additionally
supply deliberately different values that the predicate must reject. A failing
source expression cannot be reported as a reproduced printer bug.

The legacy adapter prints `(list original)` to reach the container printer,
reads it back and takes the first element. This wrapper affects which bugs
are observable: a lone symbol can survive via a homogeneous symbol vector;
the mixed-list symbol case exercises the failure in #989. It is not a test of
the future exact writer's top-level atom handling.

| Status | Meaning |
| --- | --- |
| PASS | A control survives the legacy round trip. |
| XFAIL | A fixture linked to an upstream issue mismatches or errors during the round trip. Inspect diagnostics before attributing its mechanism to that issue. |
| XPASS | A known-failure fixture now passes; inspect and update the baseline. |
| FAIL | A control mismatches or errors during the round trip. |
| ERROR | Fixture setup, oracle negative control, subprocess, timeout or protocol failure. |

Default exit status is zero only when results are PASS/XFAIL. `--strict`
also fails on XFAIL. XPASS is an actionable baseline change, not a product
regression. An XFAIL does not prove the failure mechanism is unchanged; retain
full diagnostics when investigating a new binary. This is not a conformance
badge and known failures are not waived for production experiment import.

## Initial evidence

On 2026-10-25 both the installed Rayforce and a separate engine built from
the pinned revision `65de9fe547492b8b068ee9e097e5d2eab14c7580` produced
**13 PASS, 16 XFAIL**, with no XPASS/FAIL/ERROR. The strict invocation correctly
returned failure, and deliberately broken source/oracle fixtures were verified
to produce ERROR even when tagged with a known issue.
The passing cases include exact integers above 2^53, timestamps with
nanoseconds, spans, a basic config dictionary/table, a null-bearing integer
vector, 4096 vector elements and 64 generic list items. Known failures cover
escaped strings (#988), symbol spellings (#989), numeric types/precision and
GUIDs (#990), container shapes (#991), and 4097 vector elements / 65 list items
(#992). This is focused reproduction, not an exhaustive certification.

## Next contributions upstream

Request agreement on the contract in #994 before turning the corpus into
requirements for new builtins. In particular, settle float/null identity,
allowed constructors, explicit limits and cross-version guarantees. Morsel's
[existing response](https://github.com/RayforceDB/rayforce/issues/994#issuecomment-6386523945)
already supports separating exact representation from display and avoiding
mutable-global lookup.

Once a reader/writer API is specified, add an adapter that calls it directly;
retain the legacy adapter as diagnostic history. Add top-level atoms,
arbitrary dictionary keys, nested/empty tables, signed-zero/NaN checks under
the agreed policy, long escaped-string boundaries and a non-executing rejection
corpus for calls, names, trailing forms and resource-limit attacks. Missing
reader capabilities should be reported, not replaced by application eval.
Convert reduced failures to upstream regression tests with independent
expected types/contents. Keep printer fixes separate from changes to legacy
display/equality behavior. Extend into generated cases and shrinking only
after deterministic fixtures and contract decisions are stable.

The full feature/dependency tracker is
[Rayfall experiment files](../../workbench/doc/rayfall-experiment-format.md).
