# Record fixture

These eight CSVs are exported by the existing kernel and report code after
`test/fixture1.rfl` passes its hand-calculated accounting checks. They provide
small real records for reader development and GUI mock data. They include
rejected orders, fills, null limit/reason symbols and missing marks.

Regenerate from `backtest`:

```sh
rayforce -c 1 -f ../workbench/test/export_fixture.rfl
```

The source inputs and expected accounting are in `test/fixture1/` and
`test/fixture1.rfl`. Cash here is expressed in abstract test cash units;
no currency or decimal display scale should be inferred. Prices are ticks
and quantities are lots. Timestamp strings use the engine's calendar/epoch
conventions, not the viewer machine's local timezone.

This directory intentionally has no completion marker, manifest or
`summary.json`. It is a record fixture, not a validated published-run
artifact. An output reader must not label a directory complete merely
because these files exist.
