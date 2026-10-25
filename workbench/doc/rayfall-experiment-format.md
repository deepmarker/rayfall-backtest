# Rayfall experiment files

Decision agreed on 2026-10-25. Rayfall is the native human-editable experiment
format. Typed IPC carries the resolved specification to the runner; published
results preserve that specification and its effective values. JSON can remain
an optional interchange format. This document records the design, not an
implemented launcher feature.

## Why Rayfall

Configuration needs symbols, exact integers, timestamps, timespans, lists and
nested dictionaries. Rayfall already expresses those types and supports
comments. An experiment should look like a native value, without introducing
string conventions for every type absent from another format.

Use one data value as the file's contents, rather than assignments to globals.
For example, this illustrates the proposed core fields:

```lisp
;; experiments/trend-weekly.rfl
{version: 1
 strategy: 'trend
 parameters: {
   lookback: 90
   vol_window: 30
   vol_target: 0.5
   every: 7
   buffer: 0.98}
 config: {
   cash0: 10000000000000
   fee_ppm: 1000
   start: 2023.10.01D00:00:00.000
   period: 1D
   steps: 1096
   max_weight_ppm: 400000
   max_gross_ppm: 1000000
   buy_policy: 'SCALE}}
```

This is not yet accepted by the CLI or GUI. The complete schema must also
specify snapshot identity, baseline policy and the evaluation/warm-up policy.
Output/job identity can be assigned at submission, then recorded explicitly.
The schema version is an application contract; it does not itself guarantee
cross-version compatibility of the underlying Rayfall reader or printer.

## Ownership and execution

| Component | Responsibility |
| --- | --- |
| Strategy module | Algorithm, parameter schema/defaults, validation and history requirements. |
| Experiment file | Strategy selection, overrides, simulation settings, snapshot and comparison policy. |
| Runner | Resolve defaults once, validate, execute, check accounting and publish effective values and provenance. |
| GUI | Discover schemas, edit a per-tab draft and submit the same specification as the CLI. |
| Saved result | Retain submitted and resolved specifications so later default changes cannot silently change a replay. |

`run.rfl` becomes orchestration; its current settings become a named example
preset. Neither the CLI nor GUI edits shared strategy/runner source to change
an experiment. Unknown keys and invalid types are errors. Application defaults
and overrides have documented precedence, with the resolved outcome recorded.

The existing `Model.run_spec` and `Providers.Runner` are the starting contracts,
not an implemented input path. Baseline parameters, schema discovery and
warm-up/evaluation still need explicit decisions. See
[parameter ownership](backtest-parameters.md) and
[the runner contract](gui-interfaces.md#runner-contract).

## Data files and generated experiments

The first file format should accept literals and an explicitly supported set
of pure data constructors. Reading it must not perform arbitrary evaluation,
name lookup, assignment, file writes or process execution. Constructor meaning
must not depend on mutable global bindings. Bound input size, nesting and
construction work, including validation before parsing allocates resources.
Reuse Rayforce's parser and data APIs; do not introduce another Rayfall parser
in OCaml to work around missing engine support.

An ordinary Rayfall program may later generate experiments, for example a
parameter sweep, and submit the resulting dictionaries through the same
runner. That is explicit program execution, a separate path from reading an
experiment data file. No implicit evaluation fallback belongs in the data
reader.

GUI edits save a new experiment value. The GUI does not rewrite arbitrary
user programs. Preserving source comments/layout is a separate editor feature;
an exact value printer guarantees values, not original formatting.

## Upstream dependencies

Checked live issue bodies and all comments on 2026-10-25. Issues #988–#994
were opened by `vbmithr`; all remain **open**. There are no comments on
#988–#993. These are reported upstream problems and proposals; this check did
not rerun their reproductions or establish that fixes exist in a later binary.

| Issue | Requested capability or reported problem | Relevance and delivery gate |
| --- | --- | --- |
| [#994](https://github.com/RayforceDB/rayforce/issues/994) | Exact typed text export and a data-only reader; names such as `repr` and `read-value` are proposals. | Main dependency for native experiment loading/saving. Do not substitute display formatting plus general evaluation. |
| [#988](https://github.com/RayforceDB/rayforce/issues/988) | Compact output does not escape strings. | Paths and text can change value or break parsing; evaluation can turn data into code. Requires escaping and long-string boundary tests. |
| [#989](https://github.com/RayforceDB/rayforce/issues/989) | Printed symbols can become variable names or other values. | Strategy names, policies and arbitrary symbol values must retain their type and contents. |
| [#990](https://github.com/RayforceDB/rayforce/issues/990) | Numeric type/precision loss, signed zero and GUID spelling. | Saving must preserve parameter values and supported numeric types independently of display precision. Decide float/null fidelity explicitly. |
| [#991](https://github.com/RayforceDB/rayforce/issues/991) | Container shape, empty-vector types and dictionary-key types are lost. | Nested settings and empty typed collections must survive a round trip. Functions/owning handles are outside experiment data. |
| [#992](https://github.com/RayforceDB/rayforce/issues/992) | Vector-literal and call-arity limits prevent reading larger printed values. | Relevant to larger parameter collections and generated experiments; small example configs do not exercise these boundaries. Document deliberate resource limits rather than silently truncate. |
| [#993](https://github.com/RayforceDB/rayforce/issues/993) | No whole-value, type-strict identity builtin. | Supports round-trip tests; ordinary elementwise `==` is insufficient. Logical identity and IEEE-bit preservation are distinct contracts. |

Morsel's [response on #994](https://github.com/RayforceDB/rayforce/issues/994#issuecomment-6386523945)
agrees on separating exact representation from display interpolation and the
existing test comparator. It independently confirms basic quote/backslash
failures on the published Linux v3.0.1 artifact. It also asks for a closed data
constructor set with no mutable-global name resolution, resource limits before
parsing/construction, exclusion of functions and owning handles, and independent
type/shape/byte checks. It explicitly makes **no implementation or versioning
commitment**. Supported types and cross-version compatibility remain upstream
design questions.

Related [#1005](https://github.com/RayforceDB/rayforce/issues/1005), opened by
`belowzeroff`, is also open with no comments as checked on the same date. It
reports provenance-dependent symbol flag bytes in `ser` output, including on
`65de9fe5`, our pinned engine. Binary serialization bytes are therefore not a
canonical semantic equality/hash oracle. Hashing an actual artifact for
integrity remains valid; comparing such hashes does not establish logical
value identity across independently constructed values.

## Adoption and verification

Until the upstream reader/writer contract is available and verified, retain
the current typed IPC/native bundle path. Do not advertise general Rayfall
experiment import/export as complete or use `(eval (parse text))` as its
implementation. Report upstream gaps instead of adding an application-specific
parser or ad hoc escaping/printing layer.

Acceptance requires independent type/value checks after reading saved output:
strings with quotes/backslashes and long escaped strings; ordinary and unusual
symbols; exact integer widths and float precision; timestamps/timespans;
nulls, empty typed collections and nested dictionaries. Test rejected calls,
name references, trailing expressions, malformed input and resource boundaries.
For supported floating values, distinguish semantic equality from any stronger
bit-preservation promise; do not use display output as the sole oracle.

After upstream delivery, update the engine pin and tracking table with the
verified revision and focused tests. Then implement the runner input and
parameter schema, connect CLI and GUI, and add saving/duplication. Track this
work under GUI-01 in the [GUI backlog](gui-backlog.md). This document is a
manually maintained snapshot, not an automatic issue monitor.

## Initial contract corpus

The [round-trip corpus](../../test/roundtrip/README.md) is the first executable
step. It probes trusted values through the current legacy text path and uses
independent type/shape/content predicates with negative controls. It does not
provide a data-only reader. Its README records the contract questions, current
coverage, known failures and the conditions for adapting it to upstream APIs.

## Proposed v1 agreement tables

Morsel's [latest reply](https://github.com/RayforceDB/rayforce/issues/994#issuecomment-6398774965)
on 2026-10-25 proposes preserving ordinary data types/widths/shapes/text bytes,
exact finite floats with the existing null model, a fixed constructor grammar
and comprehensive resource budgets. It requests a small v1 agreement table and
explicitly remains design advice, not an adopted API. Morsel read the corpus
but did not run it.

The [proposed v1 type/identity/limit tables](rayfall-data-contract-v1.md)
make those decisions reviewable. Numerical budgets and signed-zero behavior
are marked as proposals; neither they nor cross-version compatibility are
claimed as upstream guarantees.
