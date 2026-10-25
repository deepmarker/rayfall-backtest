# Native saved-run viewer

The desktop workbench launches strategies and opens immutable native saved runs
in independent backtest tabs. Rayforce still
owns filtering, sampling, summary metrics and financial calculations; OCaml
renders its typed results through Imguiml, GLFW and OpenGL3.

## Launch

From `workbench`:

```sh
make gui
# Or open a previous run:
make gui RUN=/absolute/path/to/saved-run
```

Without `RUN`, the **Run strategy** pane discovers strategy modules and local
verified snapshot directories. Choose a strategy and snapshot, then click
**Run strategy**. The existing `run.sh` verifies snapshot checksums and runs
both the chosen strategy and its buy-and-hold baseline with the defaults in
`run.rfl` and `strategies/<name>.rfl`. Results open automatically after the
native bundle passes validation and atomic publication. **New backtest**
creates another tab with its own launcher. Each tab retains its strategy,
snapshot choice, zoom, selected record time and record table when switching
between tabs. Saved runs opened with the folder icon also get their own tab
(an unused launcher tab is reused). Tabs can be reordered.

Closing a tab cancels its active strategy job and reaps its dedicated Rayforce
read service asynchronously; other tabs remain usable. Completed saved bundles
are retained on disk. Closing the native window shuts down all tabs. The output folder defaults to
`backtest/out/workbench`; each run gets a unique child directory.
The launcher does not yet edit strategy parameters or the run configuration.

To inspect existing output, click the folder icon under **Saved run**. It
opens a native GTK directory chooser and immediately opens the selected run,
switching a reused launcher tab to its results view after verification.
There is no editable saved-run path or separate Open button. Cancelling leaves
the current view unchanged. The output-folder field also has a chooser.
Dialogs run asynchronously and are closed when the GUI exits.
Rejected paths and exceptions clear
the opening state so another directory can be selected. The directory must
be a completed native bundle, not a CSV export directory. See
[saved runs](saved-runs.md) to publish one. Each open verifies the bundle's
checksums and seal before launching its read service. The viewer owns and
reaps that loopback-only Rayforce process; closing a run or window also closes
the IPC Reader. It does not attach to a strategy process or evaluate editor
buffers.

The UI is one workspace bound to the native client size. It has no independent
floating ImGui windows. The launcher puts labels above full-width fields,
wraps prose and scrolls when vertically constrained. This layout is recomputed
each frame, including configure events from a tiling Wayland compositor.

Wide inspection windows show summary, chart and records side by side. Below
1050 logical pixels of available width, or 450 pixels of available height,
inspection switches to **Summary**, **Equity** and **Records** tabs. Each tab
uses a scrollable child region, so it remains usable in short tiles. Toolbars
use separate rows in narrow panes. Switching tabs does not change selection.

Text uses the system sans TrueType font resolved by Fontconfig, with native
ImGui rasterization and monitor DPI scaling. If Fontconfig is unavailable,
the bundled vector font is used. `-font /path/to/font.ttf` overrides it when
invoking the executable directly. Each frame explicitly acquires the OpenGL context and releases it before
returning to Async; shutdown also reacquires it before deleting GPU resources.
GUI smoke tests read the atlas back from OpenGL and compare every byte, in
addition to testing layout and data.

The inspection panes are:

- **Run and summary** selects a strategy and shows recorded provenance and
  engine-exported metrics. Financial values use source units; missing scale
  metadata remains visible rather than being inferred.
- **Equity** draws exact source points or the server's extrema envelope. Nulls
  break the line. Hover shows the exact timestamp, integer value and source
  row. A click moves the shared record cursor. Dragging pans the time window, with
  the graph following the mouse. The plot keeps the normal arrow pointer.
  A drag does not select records or fetch their
  rows. Small mouse jitter is treated as a click. Panning is bounded by the
  saved run, so zoom in before panning from the full-history view.
  The wheel zooms around the
  pointer; toolbar buttons zoom and reset the range. **Earlier** / **Later** pan by half
  the visible time span and are disabled at their respective boundaries.
- **Records** switches among exported tables and follows the cursor over one
  engine return period. **Show all times** removes that time filter. Pages
  contain at most 1000 rows, and ImGui's clipper renders only visible rows.
  Click a source-row ID to move the cursor to its `ts` field. Other timestamp
  fields, such as `mark_ts`, do not change selection. The blue vertical line in the
  chart is the selected record time; it initially sits at the first timestamp.

Cursor and uncached range requests are coalesced over 25 ms. When a complete
exact series is already cached for the requested interval, zoom/pan immediately
selects those source points locally, without IPC or new financial calculations.
Unchanged ranges and unchanged cursor selections do not trigger a refresh.
Charts and record pages remain visible while replacement replies arrive;
the displayed record time and table identify the retained page. Row selection
is suspended during replacement so retained rows cannot be mistaken for the
new selection. Changing the cursor in **Show all times** mode does not refetch
its unaffected page. Replaced
requests are cancelled and replies are matched to the current request ID.
Series are bounded to 4000 points. Formatted rows and chart geometry are
cached; rendering does not perform IPC or recompute accounting. Timestamp
and cash differences are computed before conversion to plotting floats,
while tooltips and records retain exact source values.

## Thread and resource ownership

`viewer/session.ml` owns bundle verification, the child service and Async IPC.
`viewer/launcher.ml` supervises `run.sh`, bounded logs and native publication.
`viewer/controller.ml` owns selection and query revisions independently of
graphics. `gui/` owns GLFW, OpenGL, ImGui and cached plot geometry.

The Async scheduler serializes graphics frames with controller updates. A
cooperative 16 ms frame timer allows Async file/process/socket work to run
between frames. GLFW swap interval is zero so a synchronous vsync wait does
not block IPC progress. Network and child-process APIs use Async.

Use the window manager’s close action to exit. The
native window is destroyed before asynchronous process cleanup, so a pending
operation cannot leave an unresponsive window visible.

On normal close, signals or OCaml exceptions, the viewer cancels the Reader,
terminates the service and waits for it, escalating to kill after two seconds.
Native crashes and forced process termination cannot execute this cleanup.

Strategy cancellation signals the owned process group and escalates after two
seconds if necessary. The producer is reaped before staging cleanup. During
publication, cancellation is checked before atomic rename; a native
validation already in progress may finish first. Successful atomic publication
wins a cancellation arriving after the final check. Closing the GUI also
cancels and awaits an active launch. Logs retain the last 100 bounded lines;
phase labels describe actual process/publication state, not estimated progress.

## Build requirements

The amended graphics dependency is pinned as
`vendor/imguiml-ft`, a submodule of
[vbmithr/imguiml-ft](https://github.com/vbmithr/imguiml-ft). Its input widgets
need mutable C buffers, and unformatted text needs an optional end pointer;
the fork corrects those generated signatures and tests both.

Initialize submodules, then install its build dependencies in the workspace
switch:

```sh
git submodule update --init --recursive
opam install --deps-only ./vendor/imguiml-ft/imguiml-ft.opam
```

The Linux directory chooser requires `zenity` (GTK); on Arch, install it with
`pacman -S zenity`.

Native dependencies include CMake, a C++ compiler, GLFW, GLEW, OpenGL and
FreeType. On Arch, install `glfw glew freetype2 cmake`; `xorg-server-xvfb` is
needed for the headless rendering test. The current platform loader targets
Linux shared-library names. Other operating systems need a platform loader
and link settings before this executable can run there.

## Focused validation

```sh
make test
make viewer-test
make launcher-test
```

`viewer-test` publishes a fresh hand-calculated fixture bundle, checks cursor
filtering, zoom requests, stale replies, strategy refresh and service cleanup,
then renders the real GUI under Xvfb. The GUI smoke opens a second tab and
checks independent selection state, closes it and verifies its service is
reaped while the first remains active, and checks cancellation on tab close. It needs loopback socket access and a
working software or hardware OpenGL implementation. Preserve a PPM screenshot
with `SCREENSHOT=/tmp/workbench.ppm make viewer-test`.

`launcher-test` generates the deterministic `sample-1d` snapshot locally.
Set `SNAPSHOT=/absolute/path` to test another snapshot. It runs real `trend` and `buyhold`,
checks native metadata/reopening and active cancellation, exercises GUI
launch-to-inspection, checks native close while a folder chooser is active,
and verifies the ordinary CLI still writes its report
and CSVs. Its output is temporary. A launcher-layout smoke also checks that strategy and
snapshot discovery succeeds and that input/combo rectangles stay inside
available width while resizing through 360×420, 540×500 and 420×600 pixels. Both graphics tests explicitly select X11
under Xvfb, even when launched from a Wayland desktop. The GUI smoke repeatedly resizes
the native window to exercise compact controls and tabbed inspection. They also inject real
ImGui mouse press/move/release events and check that dragging pans the chart
without moving the record cursor.

The screenshot option belongs to the smoke-test mode. It reads the actual GL
framebuffer before swapping; it does not simulate the widgets. The graphics
binding also has focused headless tests:

```sh
dune runtest --root .. vendor/imguiml-ft/test
```

## Remaining work

See the [GUI backlog](gui-backlog.md) for prioritized missing features,
usability issues, validation gaps and completion criteria. The
[architecture](gui-design.md) and [shared interfaces](gui-interfaces.md)
provide the design context.
