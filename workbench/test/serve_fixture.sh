#!/usr/bin/env bash
# Start the workbench example with an explicitly selected backtester checkout.
set -euo pipefail
port=${1:?usage: serve_fixture.sh PORT BACKTEST_DIRECTORY}
backtest=$(realpath "${2:?usage: serve_fixture.sh PORT BACKTEST_DIRECTORY}")
workbench=$(cd "$(dirname "$0")/.." && pwd)
rayforce=${RAYFORCE:-rayforce}
cd "$backtest"
exec "$rayforce" -c 1 -p "127.0.0.1:$port" \
  -f "$workbench/test/fixture-service.rfl" -- -service "$workbench/rayfall/service.rfl"
