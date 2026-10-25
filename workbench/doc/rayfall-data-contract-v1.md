# Rayfall data format: proposed v1 contract

Draft for agreement on [Rayforce #994](https://github.com/RayforceDB/rayforce/issues/994),
following [Morsel's baseline](https://github.com/RayforceDB/rayforce/issues/994#issuecomment-6398774965)
and [review amendments](https://github.com/RayforceDB/rayforce/issues/994#issuecomment-6398920257)
of 2026-10-25. This is a proposal, not an adopted upstream API or an implemented
reader. Builtin names, concrete spellings and compatibility guarantees remain
upstream decisions. Do not change legacy `format` or `fmt_eq` semantics to
satisfy this contract.

## Types and identity

Both top-level values and nested values follow the same rules. Successful
write/read preserves the properties below, independently of display precision.

| Data family | Proposed identity requirement | Independent acceptance check |
| --- | --- | --- |
| Boolean and integer atoms/vectors (`B8`, `U8`, `I16`, `I32`, `I64`) | Same type/width, atom versus vector kind, length and every value; existing typed-null behavior. No conversion through floating point. | Check type, length, null positions and each non-null integer, including values above 2^53. |
| `F32`, `F64` atoms/vectors | Same stored width and exact finite value. Preserve signed zero (proposed). Keep the existing engine null model. Reject out-of-domain nonfinite input, including raw infinity values; imported bits do not establish supported language values. NaN payload bits are outside the guarantee; do not add an ordinary-NaN/null distinction. | Check width and exact finite values; inspect the zero sign bit independently at both widths, not through equality or reciprocal arithmetic. Check existing typed nulls; test infinity rejection. |
| Strings and symbols | Same kind and text bytes, including empty strings/symbols, embedded NUL, escapes and arbitrary supported symbol text. Symbol intern IDs are not identity. | Check type, byte length and bytes, independent of printed form. Include reserved words and delimiters. |
| GUID atoms/vectors | Same type, 128-bit contents and existing null positions. | Compare type and raw GUID bytes/null status through independent APIs. |
| Temporal atoms/vectors (`DATE`, `TIME`, `TIMESTAMP`, `TIMESPAN`) | Same type, stored integer value and null positions; no timezone conversion or loss of resolution. | Check type and exact integer payload, including nanosecond edges. |
| Generic null | Preserve the engine's generic null value; do not silently substitute a typed null or a symbol named `null`. | Check null kind separately from typed-null cases. |
| `LIST` | Same container kind, ordered element count and recursive identity. Homogeneous lists stay lists; empty lists stay lists. | Check kind/count and each child's type and value. |
| `DICT` | Same key/value kinds, ordered key/value sequence, key types, empty shape and recursive contents. No silent sorting, key coercion or deduplication. | Check key/value types, counts, order and recursive contents; include non-symbol keys. |
| `TABLE` | Same ordered column names, row count, each column's type/kind and contents. Preserve the full schema of zero-row tables, including LIST-valued columns without inference. A zero-column table has zero rows; reject a positive-row claim. | Check table kind, names/order, row count and explicit column types/kinds. Distinct fixtures for zero-row named schemas and zero-column/zero-row tables. |

Value identity excludes reference counts, intern IDs, allocator addresses,
attribute/cache flags and physical storage provenance. This is not a promise
of canonical text or canonical `ser` bytes. Formatting layout and comments are
not preserved by the value writer. Existing engine type validity and null
rules still apply; v1 does not invent new values for sentinel bit patterns.

Functions, builtins, closures, owning handles and storage wrappers are excluded.
The writer must fail explicitly for them, including when nested, rather than
emit placeholders. Callers may explicitly materialize supported plain data
before exporting it; the format does not serialize process/resource ownership.

Signed-zero preservation is a proposed stronger rule requiring agreement and
explicit tests. Existing tests' logical equality must not be mistaken for a
bitwise contract. NaN payload preservation is deliberately not proposed.

## Reader and writer boundary

| Surface | Proposed rule |
| --- | --- |
| Input | Exactly one complete data value; allow surrounding whitespace/comments, reject a second value or trailing non-comment tokens. |
| Constructors | The intrinsic operations below and literal type tags, independent of globals. Concrete surface syntax remains to be agreed; ordinary evaluator calls are not an implementation of these operations. |
| Names and effects | Reject variable references, dynamic type/constructor selection, assignments, lambdas, arbitrary calls and evaluation fallback. Rebinding a global named `list`, `dict`, `table` or `as` must not change reader behavior. |
| Malformed input | Reject with an error identifying the category and source position where available; never truncate or return a partial value as success. |
| Failed construction | Release partially built data and temporary storage. Do not publish partial values or retain speculative interns after rejected reads. Stage symbols and commit only on successful complete construction, with the atomicity requirements below. |
| Writer | Validate representability, preserve all supported values under the agreed identity rules, escape text completely and report output-budget exhaustion without reporting a truncated artifact as successful. |
| Cross-version reads | No promise until upstream publishes a supported writer/reader-version policy and fixtures. Application experiment schema versioning is independent. |

## Intrinsic operation inventory

These are abstract operations, **not proposed builtin names or ordinary
Rayfall function calls**. Arity counts operands in this description. A
sequence operand has its own checked length, not the VM's function-call arity.
The parser may offer literal sugar that maps to exactly these operations.
Every type tag, schema descriptor and payload is literal data, not an evaluated
expression or variable reference.

| Operation | Arity and argument forms | Validation and result |
| --- | --- | --- |
| GenericNull | 0 | Construct the generic null value, distinct from all typed nulls. |
| TypedNull | 1: supported scalar type tag | Construct only that type's existing null representation; reject types without a supported typed-null form. |
| Scalar | 2: type tag, literal payload | Boolean/integer/float/text/GUID/temporal scalar. Check range/domain before narrowing or construction. Text payloads carry decoded bytes. Do not infer a new type, round a finite stored-width value or normalize invalid infinity input into success. |
| Vector | 2: element type tag, sequence of literal payloads or typed-null entries | Construct exactly the declared typed vector, including length zero. Every entry must belong to the declared type/domain; no implicit heterogeneous vector or list inference. |
| List | 1: sequence of data values | Construct a generic LIST, including empty and homogeneous lists. Preserve each element's kind. |
| Dict | 2: data key collection, data value collection | Require collections and equal lengths, preserving their supported kinds/order and empty types. Validate keys under the engine's dictionary rules; reject invalid input rather than sorting/coercing/deduplicating it. |
| Table | 3: ordered schema, sequence of columns, declared row count | Each schema field has a symbol name and explicit column kind: typed vector with element type, or LIST. Validate names under engine table rules, schema/column count, each column kind/type, and equal lengths matching row count. Preserve zero-row LIST columns without inference. Empty schema requires empty columns and row count zero. |

No operation exposes general `as`, arbitrary application, symbol resolution,
callbacks, query evaluation, file access or mutation. Rebinding an evaluator
function with the same spelling has no effect. Strings that resemble source
remain string data. The exact literal spelling for arbitrary bytes, unusual
symbols, typed empty shapes and schema fields is an upstream grammar decision;
the operation inventory does not imply today's syntax can express all of it.

## Symbol staging and commit

Before success, keep decoded symbol candidates in reader-owned staging storage,
charged to both symbol-byte and allocation budgets. Validate the complete
single value, all domains and all budgets before committing new interns. If
commit requires new storage, reserve it under the budget and obtain a runtime
admission decision before changing visible intern state. Commit must be atomic
or rollback-capable; parse, construction and commit failures must leave no
new speculative interns behind. The engine needs to specify the mechanism;
an application cannot obtain this property by calling ordinary `eval`.

Successful reads may legitimately add symbols. A per-read limit cannot bound
that accumulation across repeated successful requests. Process/session symbol
admission and lifetime policy must therefore be explicit at the embedding
boundary; v1 does not claim that its per-read budget is a global intern quota.
If a host requires that stronger bound, it must refuse commits that exceed its
runtime quota, not rely on post-hoc cleanup after a successful read.

## Resource limits

The accounting rules below are proposed requirements. The numerical values
are **discussion defaults**, not adopted limits, performance-derived thresholds
or a reason to reject larger in-memory engine values. Callers may need explicit
higher limits for general table export. The API for supplying limits remains
open; any effective limits must be inspectable/documented and finite.

| Budget | Proposed starting default | Counting and enforcement |
| --- | --- | --- |
| Input bytes | 8 MiB | Encoded input including whitespace/comments; reject over-budget input before tokenization or whole-file allocation. Streaming callers must enforce the cap while reading. |
| Nesting depth | 128 | Root value depth is 1; nested data containers increment depth. Charge constructor/grammar recursion too so equivalent syntax cannot evade the stack budget. |
| Data elements/nodes | 1,000,000 | Count data occurrences, not unique addresses: one per scalar/null, typed vector element and container. Dicts charge their key/value collections recursively; tables charge their name collection and columns recursively. Do not double-charge a scalar occurrence for its vector slot. Literal type tags/schema descriptors are grammar nodes, not extra data scalars. |
| Grammar/parser nodes | 1,000,000 | Independently count every syntax node, constructor wrapper, type tag and schema descriptor created or visited, including speculative/retried work. Charge a batch before allocating it. A streaming parser must enforce the equivalent token/production budget, not skip this bound because it has no AST. |
| Symbol bytes | 1 MiB total per read | Sum decoded bytes of every symbol occurrence before interning, not just distinct names. Keep limits across the whole read, not separately per dictionary or vector. |
| Construction allocation | 64 MiB peak charged live bytes | Charge allocator-rounded capacities and per-allocation headers for reader-owned input copies, parser/token/AST buffers, decoded text, values, temporaries, staged symbols and read-attributable intern-table growth. Requested payload bytes alone are insufficient. Reserve before allocating/growing and use overflow-checked arithmetic. |
| Writer output bytes | 8 MiB | Cap emitted encoded bytes, including escaping and type syntax. Align defaults with reader input capacity; fail explicitly if a value cannot fit. |

Each cap is inclusive: reaching it is allowed if other caps are satisfied;
exceeding it fails before the prohibited allocation/work. Count decoded bytes
where specified and encoded bytes otherwise. Depth is a structural/recursion
bound, not a claim that all inputs of depth 128 fit the other budgets.
Speculative work must not evade budgets by freeing buffers just before
constructing new ones: input/node caps bound cumulative input-driven work,
while allocation is explicitly a peak-live cap. Reject oversized integer
length calculations instead of wrapping them.

Allocation accounting distinguishes requested payload bytes from charged
bytes. The charged size is the allocator's size-class/alignment-rounded block
capacity plus its known header cost, even when a block comes from a cached
slab. Fixed bookkeeping for each block and reader instance is also charged.
For resize-by-copy, charge old and replacement blocks concurrently until the
old one is released. For shared intern-table growth, charge new capacity and
temporary rehash storage attributable to this read; already-live global
storage is outside the per-read allocation tally and subject to host quotas.

This is **not a process-RSS cap**: pre-existing heaps, shared libraries, slab
backing pages, thread stacks and unrelated concurrent work are outside it.
Grammar/data counts and depth bound parser work/recursion separately. An
implementation must expose budget-aware allocation/charge sizes rather than
silently substitute requested byte counts for this definition. Exact allocator
header charging and syntax-node lowering still require upstream agreement.
No unbounded pre-scan or unrestricted evaluation may precede these checks.

## Agreement and test map

| Area | Existing corpus | Next evidence after agreement |
| --- | --- | --- |
| Basic values, temporal precision, config dictionary/table | Passing controls in the [legacy corpus](../../test/roundtrip/README.md). | Direct top-level writer/reader calls; full supported-type coverage. |
| String/symbol spelling, numeric precision, shapes, size edges | Reduced failures associated with #988–#992. | Move into focused upstream regressions for the new API without changing display expectations. |
| Float edge policy | Not covered by the current corpus. | Sign-bit checks for positive/negative zero at both widths; existing null cases; explicit rejection of out-of-domain infinity input. No reciprocal-arithmetic oracle. |
| Empty schemas | Empty typed-vector probes exist; other empty kinds/schemas remain untested. | Separate empty typed vectors, empty LIST, empty DICT key/value kinds, zero-row typed/LIST columns, zero-column/zero-row table, and rejection of positive-row zero-column claims. |
| Data-only grammar | No API to test yet. | Reject names/calls/trailing forms without executing them; verify constructor-global rebinding has no effect. |
| Limits/cleanup | Legacy size edges are diagnostic only. | Cap-1/cap/cap+1 per budget, competing caps, escaped-string expansion, nested constructors, allocator-rounded resize peaks, allocation/commit failures, repeated rejected reads without intern growth, and successful reads up to host symbol-admission limits. |
| Version policy | None adopted. | Upstream-supported cross-version fixtures, separate from experiment-schema migration tests. |

Next agreement requests: adopt or amend the revised identity/empty-schema
rules and intrinsic operation forms, then agree on grammar-node charging,
allocator accounting, symbol-commit support, numerical defaults and a
compatibility policy. Only then turn the draft into a claimed v1 conformance
suite. The current diagnostic corpus and
experiment import remain separate from this proposed API.
