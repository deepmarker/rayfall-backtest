#!/usr/bin/env bash
# Benchmark grid for milestone 5: synthetic daily and hourly snapshots of
# 12, 100 and 500 instruments over 1096 days, each run in four modes (see
# bench.rfl). One process per measurement, so each has its own peak RSS and a
# timeout cannot take the others down.
#
#   bench/run.sh OUT [TIMEOUT_S] [SIZES] [PERIODS]
#
# OUT gets env.txt (machine, revisions) and results.jsonl (one line per run:
# the bench.rfl JSON plus rss_kb, wall_s and status ok|timeout|error).
# The instrumented run gives the phase timings and the peak RSS. If it took
# under HF_LIMIT_S (60), hyperfine then times the whole process with one
# warm-up and HF_RUNS (5) runs, adding hf_mean_s, hf_stddev_s, hf_min_s,
# hf_max_s, hf_runs and, where perf counters are readable, hf_instructions;
# longer configurations are measured once. Needs hyperfine 2 (JSON schema 2).
# KERNEL selects the kernel file (default bt.rfl), DATA_DIR where the
# synthetic snapshots are built (default data). MODES overrides the modes (default: kernel hold xsmom xsmomf trend).
# RAYFORCE selects the binary, FRAMEWORK_REV records the code revision when
# the tree is not a git checkout. Synthetic data is built under data/ if
# absent.
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

out=$1 timeout_s=${2:-1800} sizes=${3:-"12 100 500"} periods=${4:-"1d 1h"}
rayforce=${RAYFORCE:-rayforce}
kernel=${KERNEL:-bt.rfl} data_root=${DATA_DIR:-data}
hf_limit_s=${HF_LIMIT_S:-60} hf_runs=${HF_RUNS:-5}
mkdir -p "$out"
probe=$(mktemp --suffix=.rfl)
echo '(println (.sys.build))' > "$probe"
{
  echo "host: $(uname -n)"
  echo "cpu: $(LC_ALL=C lscpu | sed -n 's/^Model name: *//p'), $(nproc) threads"
  echo "mem: $(free -g | awk '/^Mem:/ {print $2}') GiB"
  echo "os_kernel: $(uname -r)"
  echo "rayforce: $("$rayforce" "$probe" </dev/null)"
  echo "rayforce_sha256: $(sha256sum "$(command -v "$rayforce")" | cut -d' ' -f1)"
  # FRAMEWORK_REV when the code was copied out of its checkout
  echo "framework_rev: ${FRAMEWORK_REV:-$(git rev-parse HEAD 2>/dev/null || echo unknown)$(git diff --quiet HEAD -- . 2>/dev/null || echo -dirty)}"
  echo "date: $(date -u +%FT%TZ)"
  echo "kernel: $kernel"
  echo "rayforce_threads: auto ($(nproc))"
  echo "load_before: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "timeout_s: $timeout_s"
  echo "hyperfine: $(hyperfine --version 2>/dev/null || echo absent), $hf_runs runs under ${hf_limit_s}s"
} > "$out/env.txt"
rm -f "$probe"

for period in $periods; do
  per_day=$([[ $period == 1h ]] && echo 24 || echo 1)
  for n in $sizes; do
    data=$data_root/synth-$period-$n
    [[ -f $data/SHA256SUMS ]] || python3 -I tools/synth_bars.py --out "$data" \
      --instruments "$n" --period "$period" --from 2023-10-01 --days 1096
    for mode in ${MODES:-kernel hold xsmom xsmomf trend}; do
      log=$out/$period-$n-$mode.log
      start=$(date +%s%N)
      set +e
      /usr/bin/time -f '%M' -o "$log.rss" timeout "$timeout_s" \
        "$rayforce" bench/bench.rfl -- -data "$data" -mode "$mode" -per_day "$per_day" -kernel "$kernel" \
        </dev/null >"$log" 2>&1
      rc=$?
      set -e
      wall=$(awk -v ns=$(( $(date +%s%N) - start )) 'BEGIN { printf "%.3f", ns / 1e9 }')
      rss=$(tail -1 "$log.rss" 2>/dev/null | grep -E '^[0-9]+$' || echo 0)
      status=ok; [[ $rc == 124 ]] && status=timeout; [[ $rc != 0 && $rc != 124 ]] && status=error
      json=$(grep '^{' "$log" | tail -1 || true)
      [[ -n $json ]] || json="{\"mode\": \"$mode\", \"instruments\": $n}"
      hf=
      if [[ $status == ok ]] && awk -v w="$wall" -v l="$hf_limit_s" 'BEGIN { exit !(w < l) }'; then
        hyperfine --warmup 1 --runs "$hf_runs" --export-json "$log.hf.json" --style none \
          "$rayforce bench/bench.rfl -- -data $data -mode $mode -per_day $per_day -kernel $kernel </dev/null" >/dev/null
        hf=$(python3 -I - "$log.hf.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))["results"][0]
t = r["summary"]["time_wall_clock"]
n = t["count"]
extra = ", \"hf_instructions\": %d" % r["summary"]["instructions"]["mean"] \
    if "instructions" in r["summary"] else ""
print(", \"hf_mean_s\": %.4f, \"hf_stddev_s\": %.4f, \"hf_min_s\": %.4f, \"hf_max_s\": %.4f, \"hf_runs\": %d%s"
      % (t["mean"], t["stddev"], t["min"], t["max"], n, extra))
PY
)
      fi
      echo "${json%\}}, \"period\": \"$period\", \"rss_kb\": $rss, \"wall_s\": $wall, \"status\": \"$status\"$hf}" \
        >> "$out/results.jsonl"
      echo "$period $n $mode: $status ${wall}s"
    done
  done
done
