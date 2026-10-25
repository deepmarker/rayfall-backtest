# Rayfall backtester and workbench

A deterministic bar-based backtester in Rayfall, with a native OCaml desktop
workbench. Strategies, accounting, validation and metrics run in Rayforce.
The workbench launches isolated backtests, opens native saved runs and links
an equity chart to record tables through typed Async IPC.

Each backtest has its own tab. Tabs retain their zoom, cursor and table state;
closing a tab cancels its job and stops its service. Completed results remain
on disk. This project is independent of the DeepMarker application.

## Get the source

```sh
git clone --recurse-submodules https://github.com/deepmarker/rayfall-backtest.git
cd rayfall-backtest
```

Dependencies amended for this project are pinned public git submodules under
`vendor/`. The ISC license covers this repository; submodules retain their own
licenses. Data downloads, saved runs and local build products are ignored.

## Run from the command line

Install Rayforce containing commit `65de9fe5` or later. CI pins its full
revision in [ci/rayforce-revision](ci/rayforce-revision). To build that revision
locally, install Git, Clang and Make, then run `make engine` and add it to
your path with `export PATH="$PWD/.engine:$PATH"`.

```sh
make -C backtest data
cd backtest
./run.sh trend data/binance-spot-1d-2023-10_2026-09 out/trend
```

The CLI needs Rayforce, Bash, Git, Python 3, `sha256sum` and standard Unix tools.
It does not need OCaml, OpenGL or a desktop. `make data` downloads public
snapshots and verifies their pinned checksums.

## Run the desktop workbench

Create an OCaml 5.5.1 switch and activate it:

```sh
opam switch create . ocaml-base-compiler.5.5.1
eval "$(opam env)"
make deps-gui
make gui
```

Choose a strategy and a downloaded snapshot, then click **Run strategy**.
The folder icon opens a saved run. Drag the chart to pan, wheel to zoom and
click to select a time in the records. New backtests open in independent tabs.

On Debian/Ubuntu, install these native development/runtime packages:

```sh
sudo apt-get install build-essential cmake pkg-config perl libglfw3-dev libglew-dev libgl1-mesa-dev libfreetype-dev zenity fontconfig fonts-dejavu-core
```

On Arch, use `base-devel cmake pkgconf perl glfw glew freetype2 zenity fontconfig`.
The current GUI platform loader targets Linux (Wayland or X11). The OCaml
libraries use Core, Async, Yojson and Digestif; the graphics generator also
needs Goblint-CIL and Ctypes. `make deps-gui` resolves those from the checked-in
opam manifests, including the submodule manifests.

For headless workbench development, use `make deps` and `make build test`;
these targets do not build ImGui or require its native graphics libraries.

## Tests and CI

```sh
make test                 # OCaml model, codec, storage, controller arithmetic
make kernel-test          # offline Rayfall fixtures and Python accounting oracle
make live-test saved-test # real IPC, native publication and reopen checks
make gui-test             # real GUI under Xvfb, synthetic mouse and GPU checks
make launcher-test        # real trend/baseline launch; requires downloaded data
make test-full            # all Rayfall fixtures and full-run determinism
make fmt-check
```

Graphical tests need `xvfb`, `xauth` and a working OpenGL driver; Mesa software
rendering is sufficient. CI separates headless validation from GUI validation
and builds a pinned Rayforce revision. Normal CI uses small committed fixtures
and does not download market history. Full snapshot/benchmark runs remain
explicit targets. Optional Coinlake ingestion additionally needs Databento's
Python client and credentials configured through the environment.

## Documentation

- [Backtester manual](backtest/doc/manual.md) and [accounting contracts](backtest/doc/contracts.md).
- [Native workbench](workbench/doc/native-viewer.md) and [saved-run format](workbench/doc/saved-runs.md).
- [Shared interfaces](workbench/doc/gui-interfaces.md) and [architecture](workbench/doc/gui-design.md).
- [Kernel benchmarks](backtest/doc/benchmarks.md) and [historical audit](backtest/doc/audit-2026-10-21.md).

Extracted from `deepmarker/dm` at `91e6a4029`, including the subsequent native
workbench work. Historical benchmark measurements retain their original
machine/revision context; paths in those records describe the old checkout.
