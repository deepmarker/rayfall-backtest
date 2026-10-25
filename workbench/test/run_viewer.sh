#!/usr/bin/env bash
set -euo pipefail
workbench=$(cd "$(dirname "$0")/.." && pwd)
backtest=$(realpath "${1:?usage: run_viewer.sh BACKTEST_DIRECTORY}")
build=$workbench/../_build/default/workbench
runs=$(mktemp -d)
trap 'rm -rf -- "$runs"' EXIT
"$build/bin/workbench_bundle.exe" publish -directory "$runs/run" \
  -service-directory "$workbench/rayfall" \
  -producer "$workbench/test/export-bundle-fixture.rfl" -producer-cwd "$backtest"
"$build/test/viewer_live_test.exe" "$runs/run" "$workbench/rayfall"
env -u WAYLAND_DISPLAY XDG_SESSION_TYPE=x11 xvfb-run -a "$build/gui/workbench_gui.exe" -run "$runs/run" \
  -service-directory "$workbench/rayfall" -backtest-directory "$backtest" -smoke-test \
  -screenshot "${SCREENSHOT:-$runs/viewer.ppm}"
