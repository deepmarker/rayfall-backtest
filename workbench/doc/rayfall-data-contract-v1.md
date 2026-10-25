# Rayfall data format: proposed v1 contract

Draft for agreement on [Rayforce #994](https://github.com/RayforceDB/rayforce/issues/994),
following [Morsel's baseline](https://github.com/RayforceDB/rayforce/issues/994#issuecomment-6398774965)
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
| `F32`, `F64` atoms/vectors | Same stored width and exact finite value. Preserve signed zero (proposed). Preserve signed infinity and the existing engine null model. NaN payload bits are outside the guarantee; do not add an ordinary-NaN/null distinction. | Check width; compare finite values exactly; use explicit sign-sensitive zero, infinity and null predicates. Do not use ordinary equality alone for signed zero. |
| Strings and symbols | Same kind and text bytes, including empty strings/symbols, embedded NUL, escapes and arbitrary supported symbol text. Symbol intern IDs are not identity. | Check type, byte length and bytes, independent of printed form. Include reserved words and delimiters. |
| GUID atoms/vectors | Same type, 128-bit contents and existing null positions. | Compare type and raw GUID bytes/null status through independent APIs. |
| Temporal atoms/vectors (`DATE`, `TIME`, `TIMESTAMP`, `TIMESPAN`) | Same type, stored integer value and null positions; no timezone conversion or loss of resolution. | Check type and exact integer payload, including nanosecond edges. |
| Generic null | Preserve the engine's generic null value; do not silently substitute a typed null or a symbol named `null`. | Check null kind separately from typed-null cases. |
| `LIST` | Same container kind, ordered element count and recursive identity. Homogeneous lists stay lists; empty lists stay lists. | Check kind/count and each child's type and value. |
| `DICT` | Same key/value kinds, ordered key/value sequence, key types, empty shape and recursive contents. No silent sorting, key coercion or deduplication. | Check key/value types, counts, order and recursive contents; include non-symbol keys. |
| `TABLE` | Same ordered column names, row count, each column's type/kind and contents, including empty typed columns. Do not change a table into a dictionary. | Check table kind, names/order, row count, column types and contents. Explicitly settle zero-column/empty schema cases. |

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
| Constructors | A fixed, documented grammar for supported data constructors and literal type tags. Meanings are intrinsic to the reader and never looked up in globals. Exact syntax/constructor inventory is still to be agreed. |
| Names and effects | Reject variable references, dynamic type/constructor selection, assignments, lambdas, arbitrary calls and evaluation fallback. Rebinding a global named `list`, `dict`, `table` or `as` must not change reader behavior. |
| Malformed input | Reject with an error identifying the category and source position where available; never truncate or return a partial value as success. |
| Failed construction | Release partially built data and temporary storage. Do not publish partial values; limit speculative symbol interning so repeated rejected inputs cannot grow global state without bound. |
| Writer | Validate representability, preserve all supported values under the agreed identity rules, escape text completely and report output-budget exhaustion without reporting a truncated artifact as successful. |
| Cross-version reads | No promise until upstream publishes a supported writer/reader-version policy and fixtures. Application experiment schema versioning is independent. |

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
| Data elements/nodes | 1,000,000 | Charge every scalar occurrence, typed vector element and container, including dict keys/values and table names/columns. Also bound intermediate AST nodes before allocation if an AST is used. |
| Symbol bytes | 1 MiB total per read | Sum decoded bytes of every symbol occurrence before interning, not just distinct names. Keep limits across the whole read, not separately per dictionary or vector. |
| Construction allocation | 64 MiB peak | Charge the total simultaneously live reader-owned allocations: input copies, parser/AST/token buffers, decoded text, values, temporary vectors and candidate symbol additions. Use overflow-checked arithmetic and reserve budget before allocating or growing. |
| Writer output bytes | 8 MiB | Cap emitted encoded bytes, including escaping and type syntax. Align defaults with reader input capacity; fail explicitly if a value cannot fit. |

Each cap is inclusive: reaching it is allowed if other caps are satisfied;
exceeding it fails before the prohibited allocation/work. Count decoded bytes
where specified and encoded bytes otherwise. Depth is a structural/recursion
bound, not a claim that all inputs of depth 128 fit the other budgets.
Speculative work must not evade budgets by freeing buffers just before
constructing new ones: input/node caps bound cumulative input-driven work,
while allocation is explicitly a peak-live cap. Reject oversized integer
length calculations instead of wrapping them.

Precise node charging for textual constructor wrappers, symbol rollback or
bounded interning, and allocator overhead accounting need implementation-side
agreement. The reader must document those definitions before tests assert
numerical boundary behavior. No unbounded pre-scan or unrestricted evaluation
is permitted to precede these checks.

## Agreement and test map

| Area | Existing corpus | Next evidence after agreement |
| --- | --- | --- |
| Basic values, temporal precision, config dictionary/table | Passing controls in the [legacy corpus](../../test/roundtrip/README.md). | Direct top-level writer/reader calls; full supported-type coverage. |
| String/symbol spelling, numeric precision, shapes, size edges | Reduced failures associated with #988–#992. | Move into focused upstream regressions for the new API without changing display expectations. |
| Float edge policy | Not covered by the current corpus. | Explicit positive/negative zero, infinities and existing null cases at both widths; independent checks. |
| Data-only grammar | No API to test yet. | Reject names/calls/trailing forms without executing them; verify constructor-global rebinding has no effect. |
| Limits/cleanup | Legacy size edges are diagnostic only. | Cap-1/cap/cap+1 per budget, competing caps, escaped-string expansion, nested constructors, allocation failures and repeated rejected reads. |
| Version policy | None adopted. | Upstream-supported cross-version fixtures, separate from experiment-schema migration tests. |

Next agreement requests: adopt or amend the type/identity rows, settle signed
zero and empty-table cases, define the constructor inventory, and select limit
accounting/defaults plus a compatibility policy. Only then turn the draft
into a claimed v1 conformance suite. The current diagnostic corpus and
experiment import remain separate from this proposed API.
