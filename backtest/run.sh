#!/usr/bin/env bash
# Run a strategy and the buy-and-hold baseline on a verified data snapshot.
#
#   make data && ./run.sh trend data/binance-spot-1d-2023-10_2026-09 out/trend
#
# RAYFORCE selects the binary (default: rayforce on PATH). The output
# directory must not exist yet: runs are never overwritten in place.
set -euo pipefail
cd "$(dirname "$0")"

strategy=$1 data=$2 out=$3
shift 3
rayforce=${RAYFORCE:-rayforce}

[[ -e $out ]] && { echo "run.sh: $out exists" >&2; exit 1; }
(cd "$data" && sha256sum --quiet --check SHA256SUMS) || {
  echo "run.sh: $data does not match its SHA256SUMS" >&2; exit 1; }

rev=$(git rev-parse HEAD)
# Untracked files count: a new strategy file is part of the code that ran.
[[ -z $(git status --porcelain -- .) ]] || rev="$rev-dirty"
snapshot_sha=$(sha256sum "$data/SHA256SUMS" | cut -d' ' -f1)
# .sys.build carries no commit for a locally built rayforce, so the binary
# itself is identified by its hash.
rayforce_sha=$(sha256sum "$(command -v "$rayforce")" | cut -d' ' -f1)

mkdir -p "$out/$strategy" "$out/buyhold"
exec "$rayforce" run.rfl -- -strategy "$strategy" -data "$data" -out "$out" \
  -rev "$rev" -snapshot_sha "$snapshot_sha" -rayforce_sha "$rayforce_sha" "$@" </dev/null
