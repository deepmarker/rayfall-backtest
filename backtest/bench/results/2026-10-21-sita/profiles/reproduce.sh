#!/usr/bin/env bash
# Build the measured revision with release optimization, symbols and frame pointers.
# Generated sources, binary and perf.data stay under ignored backtest/data/.
set -euo pipefail
cd "$(dirname "$0")/../../../.."
source_repo=${RAYFORCE_SRC:-$HOME/code/rayforce}
build_dir=data/audit-rayforce-fp
out=bench/results/2026-10-21-sita/profiles
mkdir -p "$build_dir" data/audit-profiles
if [[ ! -f $build_dir/Makefile ]]; then
  git -C "$source_repo" archive 64645998 | tar -x -C "$build_dir"
fi
cat > "$build_dir/profile.mk" <<'EOF'
RELEASE_CFLAGS += -g -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer
EOF
make -C "$build_dir" -f Makefile -f profile.mk release -j8 \
  RAY_VERSION=2.10.0 GIT_HASH=64645998 >"$out/build.log" 2>&1
sha256sum "$build_dir/rayforce" >"$out/binary.sha256"
for profile in xsmomf-hourly kernel-hourly xsmom-daily; do
  mode=${profile%-*}
  period=1h per_day=24
  if [[ $profile == *-daily ]]; then period=1d per_day=1; fi
  perf record -F 999 -e cycles:u --call-graph fp \
    -o "data/audit-profiles/$profile.data" -- "$build_dir/rayforce" \
    bench/bench.rfl -- -data "data/synth-$period-100" -mode "$mode" \
    -per_day "$per_day" </dev/null >"$out/$profile.json" 2>"$out/$profile-record.txt"
  perf report --stdio --no-children --call-graph none --show-nr-samples \
    --percent-limit 0.5 -i "data/audit-profiles/$profile.data" >"$out/$profile-self.txt"
  perf report --stdio --children --call-graph graph,1,caller --percent-limit 1 \
    -i "data/audit-profiles/$profile.data" >"$out/$profile-calls.txt"
done
perf annotate --stdio --symbol ray_sym_str -i data/audit-profiles/kernel-hourly.data \
  >"$out/symbol-lock-annotate.txt"
