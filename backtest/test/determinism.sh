#!/usr/bin/env bash
# Two complete runs of the same strategy on the same snapshot must produce
# byte-identical outputs: every record table, the report and the manifest.
#
#   test/determinism.sh [strategy] [snapshot]
set -euo pipefail
cd "$(dirname "$0")/.."
strategy=${1:-trend}
data=${2:-data/binance-spot-1d-2023-10_2026-09}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
./run.sh "$strategy" "$data" "$tmp/a" >/dev/null
./run.sh "$strategy" "$data" "$tmp/b" >/dev/null
diff -r "$tmp/a" "$tmp/b"
echo "PASS determinism ($strategy: $(find "$tmp/a" -type f | wc -l) files identical)"
