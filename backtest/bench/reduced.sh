#!/usr/bin/env bash
# The milestone 5 grid as published in doc/benchmarks.md, about 15 minutes.
# Reference kernel against vectorised kernel on synthetic daily and hourly
# snapshots of 12, 100 and 500 instruments. Strategies on the view are only
# measured on daily bars: on hourly bars, building the view alone takes
# minutes per run (37 s at 12 instruments), far past the target. hyperfine
# repeats only runs under HF_LIMIT_S (10) seconds.
#
#   bench/reduced.sh OUT
#
# DATA_DIR places the synthetic snapshots (default data; they take ~1 GB).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1
export DATA_DIR=${DATA_DIR:-data} HF_LIMIT_S=${HF_LIMIT_S:-10}
KERNEL=ref/bt_ref.rfl MODES="kernel hold xsmom trend" bench/run.sh "$out/ref-1d" 300 "12 100 500" 1d
KERNEL=ref/bt_ref.rfl MODES="kernel" bench/run.sh "$out/ref-1h" 300 "12 100 500" 1h
KERNEL=bt.rfl MODES="kernel hold xsmom xsmomf trend" bench/run.sh "$out/vec-1d" 300 "12 100 500" 1d
KERNEL=bt.rfl MODES="kernel xsmomf" bench/run.sh "$out/vec-1h" 300 "12 100 500" 1h
