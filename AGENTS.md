# OCaml agent guidance

## Code style

- `ocamlformat` is authoritative. Every tracked OCaml and Dune file must pass
  `make fmt-check` at all times; do not hand-format code or undo formatter
  output.
- Run `make fmt` immediately after each batch of OCaml or Dune edits, before
  reviewing or making follow-up edits. Run `make fmt-check` before handing the
  work back. This keeps later diffs and agent context formatter-stable.
- `src/.ocamlformat` pins the first-party profile. The workspace fallback
  disables formatting for imported code that has no own policy; more specific
  `.ocamlformat` files opt libraries in with their compatibility settings.

- Minimize indentation and nesting. Prefer code whose main control flow stays
  close to the left margin.
- Do not put substantial logic in inline anonymous functions. When a lambda
  grows beyond a small, immediately obvious expression, extract it into a
  named function.
- In particular, avoid large `~f:(fun ... -> ...)` callbacks in `List`, `Set`,
  `Map`, `Hashtbl`, `Deferred`, and similar combinators. Define the callback
  above and pass it with partial application where useful.
- Split nested callbacks into small named helpers for parsing, state changes,
  logging, and error handling. The helpers should reduce indentation at the
  call site rather than merely move one deeply nested block elsewhere.
- Small lambdas remain appropriate for trivial projections, constructors, and
  one-line predicates.

These rules apply to new OCaml code and to nearby code being materially
changed. Do not mechanically rewrite unrelated code solely for style.
