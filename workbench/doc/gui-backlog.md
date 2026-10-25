# GUI backlog

Reviewed against the implementation on 2026-10-25. This is the current tracker
for missing GUI features, known usability issues and validation gaps. The
[architecture](gui-design.md) describes the intended design; the
[native viewer guide](native-viewer.md) describes implemented behavior.

Keep this document current when behavior changes. Record a reproduction for
new bugs and link a regression test or other verification when closing them.
P1 is the next delivery priority; P2 follows it; P3 is later work. Dependencies
can require implementing lower-level interfaces before their visible UI.

## Next delivery priorities

| ID | Priority | Kind | Status | Work and completion criteria |
| --- | --- | --- | --- | --- |
| GUI-01 | P1 | Feature | Open | Editable run configuration: expose evaluation dates, initial capital, costs and strategy parameters with validation. Submit a structured run specification and retain the exact effective configuration in the saved result. Avoid rewriting shared Rayfall source files to configure a run. |
| GUI-02 | P1 | Feature | Open | Readable equity chart: add date/value axes, currency scaling when metadata is available, a legend and a strategy/buy-and-hold overlay. Missing units must remain explicit. |
| GUI-03 | P1 | Usability | Open | Results-first summary: lead with engine-provided return, drawdown, costs, turnover and baseline differences where available. Put hashes and detailed provenance behind an expandable section. Label full-run and selected-window measurements explicitly; request missing calculations from Rayforce. |
| GUI-04 | P2 | Feature | Open | Trade inspection: filter by instrument and order, and link an order to fills, fees and resulting positions. Selection should update related panels consistently and expose missing relationships explicitly. |
| GUI-05 | P2 | Feature | Open | Repeat experiments: duplicate a run's configuration into a new tab, edit it and rerun. Add meaningful names and a recent-runs list. Reopening must preserve the original result and its configuration. |
| GUI-06 | P2 | Feature | Open | Cross-run comparison: align selected series, display configuration/provenance differences and identify incompatible units or evaluation intervals. Start with the baseline overlay in GUI-02. |
| GUI-07 | P2 | Usability | Open | Job feedback: display elapsed time and actual phases, make logs collapsible, and show actionable failures with log-copy access. Only display numerical progress when the producer reports a meaningful total; retain working cancellation. |
| GUI-08 | P2 | Usability | Open | Empty-data onboarding: offer local sample generation from the GUI and explain snapshot availability/verification. The current empty-state message sends users to the command line and does not mention sample generation. |
| GUI-09 | P3 | Feature | Open | Persist view preferences: remember useful table widths, selected panels and recent directories. Reopening a view must not silently change the saved experiment. |

## Validation gaps

| ID | Priority | Status | Required evidence |
| --- | --- | --- | --- |
| GUI-V01 | P1 | Unmeasured | Measure opening time, peak memory, pan/zoom latency and record-query latency on a substantial real saved run. Include repeated tab opening/closing and concurrent jobs. Existing fixture smoke tests do not establish these performance properties. |
| GUI-V02 | P2 | Needs manual validation | Recheck resizing, DPI/font rendering, chart gestures, folder dialogs and native close on the user's Wayland tiling setup. Automated Xvfb tests cover important regressions but cannot establish desktop behavior everywhere. |

## Bugs and misleading behavior

| ID | Priority | Status | Finding and completion criteria |
| --- | --- | --- | --- |
| GUI-B01 | P1 | Confirmed by source inspection | `run.rfl` hard-codes “Starting capital 100000 USDT” in the report. Changing `cfg.cash0` changes the simulation without changing this sentence. Generate the displayed capital from effective configuration and cash units; verify with a non-default capital. |

Do not label a suspected regression as confirmed without a reproduction or
clear source evidence. GUI-03 and GUI-08 track concrete presentation problems
visible in the current implementation. See [parameter ownership](backtest-parameters.md)
for the current configuration flow and intended runner design.

Earlier reported issues have fixes and automated coverage: resize layout,
missing font glyphs, opening results into the launcher, chart drag behavior,
tab isolation/cancellation and closing while a directory chooser is active.
Treat a new occurrence as a regression and record its environment and steps;
do not assume the earlier test covers every desktop configuration.

## Implementation boundaries

The launcher currently adapts `run.sh`; the structured `Providers.Runner` and
`run_spec` path is still incomplete. GUI-01 should build on the
[shared interfaces](gui-interfaces.md), rather than grow source-editing or
configuration-inference workarounds. Use the agreed
[Rayfall experiment format](rayfall-experiment-format.md), which tracks the
upstream exact-text/data-reader dependencies. A focused
[contract corpus](../../test/roundtrip/README.md) now reproduces known text
failures; the experiment reader and GUI editor remain open. Effective configuration is already
recorded in native bundles; editing and replaying it remain GUI work.

Keep financial calculations and source-of-truth units in Rayforce. Local
formatting, view navigation and cached exact-point slicing belong in OCaml.
If a required engine capability is missing, document and report that limitation
before introducing a workaround.

Suggested delivery order: GUI-01, GUI-02, GUI-03, then GUI-05/GUI-06. Measure
GUI-V01 alongside this work before expanding the interface substantially.
