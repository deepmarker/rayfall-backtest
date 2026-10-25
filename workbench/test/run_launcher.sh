#!/usr/bin/env bash
set -euo pipefail
workbench=$(cd "$(dirname "$0")/.." && pwd)
backtest=$(realpath "${1:?usage: run_launcher.sh BACKTEST_DIRECTORY}")
build=$workbench/../_build/default/workbench
snapshot=$(realpath "${SNAPSHOT:-$backtest/data/sample-1d}")
runs=$(mktemp -d)
trap 'rm -rf -- "$runs"' EXIT
"$build/test/launcher_live_test.exe" "$backtest" "$workbench/rayfall" "$runs/backend" "$snapshot"
env -u WAYLAND_DISPLAY XDG_SESSION_TYPE=x11 xvfb-run -a \
  "$build/gui/workbench_gui.exe" -service-directory "$workbench/rayfall" \
  -backtest-directory "$backtest" -smoke-layout \
  -screenshot "$runs/launcher.ppm"
env -u WAYLAND_DISPLAY XDG_SESSION_TYPE=x11 xvfb-run -a \
  "$build/gui/workbench_gui.exe" -service-directory "$workbench/rayfall" \
  -backtest-directory "$backtest" -output-parent "$runs/gui" -smoke-launch \
  -screenshot "${SCREENSHOT:-$runs/viewer.ppm}"
bash "$backtest/run.sh" trend "$snapshot" "$runs/cli"
test -s "$runs/cli/report.md"
test -s "$runs/cli/trend/equity.csv"
timeout 10s env -u WAYLAND_DISPLAY XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 xvfb-run -a \
  "$build/gui/workbench_gui.exe" -service-directory "$workbench/rayfall" \
  -backtest-directory "$backtest" -smoke-close
printf 'PASS launcher, active cancellation, GUI auto-inspection and ordinary CLI\n'
