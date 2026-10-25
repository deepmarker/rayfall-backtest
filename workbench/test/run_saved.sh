#!/usr/bin/env bash
set -euo pipefail
workbench=$(cd "$(dirname "$0")/.." && pwd)
backtest=$(realpath "${1:?usage: run_saved.sh BACKTEST_DIRECTORY}")
cli=$workbench/../_build/default/workbench/bin/workbench_bundle.exe
exe=$workbench/../_build/default/workbench/test/live_test.exe
runs=$(mktemp -d)
trap 'rm -rf -- "$runs"' EXIT
"$cli" publish -directory "$runs/run" -service-directory "$workbench/rayfall" \
  -producer "$workbench/test/export-bundle-fixture.rfl" -producer-cwd "$backtest"
"$cli" verify -directory "$runs/run"
bash "$workbench/test/run_live.sh" "$exe" "$backtest" "$runs/run"
printf 'corrupt' >>"$runs/run/tables/0/equity/cash"
if "$cli" verify -directory "$runs/run" >"$runs/corruption.log" 2>&1; then
  echo 'Corrupted native table was accepted' >&2
  exit 1
fi
printf 'PASS native saved-run publication, reopen and corruption checks\n'
