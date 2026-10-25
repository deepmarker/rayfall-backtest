# Rayfall backtester

A deterministic, bar-based backtester written in Rayfall. Strategies are
Rayfall functions that return target positions. The kernel holds them to
position limits, fills them at the next bar's open from one shared cash
balance, and keeps exact fixed-point accounts. Every run is checked against its
accounting identities before a report is written.

```sh
make data      # download and verify the two daily snapshots
make test      # fixtures; RAYFORCE=/path/to/rayforce to pick the binary
make test-oracle # 50 seeded checks against independent Python accounting
make test-run  # two full runs of each example must be byte-identical
./run.sh trend data/binance-spot-1d-2023-10_2026-09 out/trend
./run.sh xsmom data/binance-spot12-1d-2023-10_2026-09 out/xsmom
```

It needs Rayforce `dev` at `64645998` or later (`rayforce-git`
2.10.0.r206 or later); [doc/contracts.md](doc/contracts.md) records the
pinned build. Bar periods use `TIMESPAN` values (`1D` for daily bars,
`0D01:00:00` for hourly bars).

Documentation:

- [doc/manual.md](doc/manual.md): how to use it: concepts, writing a
  strategy, reading results, testing, pitfalls.
- [doc/contracts.md](doc/contracts.md): what the engine guarantees: units,
  rounding, event ordering, rejection rules, record schemas.
- [doc/plan.md](doc/plan.md): goals, milestones, progress and upstream
  tracking.
- [Workbench design](../workbench/doc/gui-design.md): proposed OCaml inspection GUI,
  architecture, delivery milestones and parallel workstreams.
- [Workbench interfaces](../workbench/doc/gui-interfaces.md): shared OCaml model and
  provider contracts and Async IPC reader; see the
  [workbench](../workbench/README.md) for scoped tests.
- [doc/audit-2026-10-21.md](doc/audit-2026-10-21.md): correctness checks,
  current benchmarks, frame-pointer profiles and NautilusTrader data loading.

## Editor navigation

[Rayfall LSP](https://github.com/vbmithr/rayfall-lsp) uses the local
`.rayfall-lsp.json` to include `run.rfl` and its literal dependencies when
navigating strategy buffers. Loads resolve from this directory, matching
`run.sh`. This makes shared kernel definitions such as `bt_strategy`
visible without executing the runner. Dynamic strategy selection and
call-time globals remain candidate definitions.
