#!/usr/bin/env bash
# Validate in OCaml, then replace this launcher with the read-only engine.
set -euo pipefail
port=${1:?usage: serve-bundle.sh PORT BUNDLE_DIRECTORY}
directory=$(realpath "${2:?usage: serve-bundle.sh PORT BUNDLE_DIRECTORY}")
service=$(cd "$(dirname "$0")" && pwd)
workbench=$(dirname "$service")
cli=${WORKBENCH_BUNDLE:-$workbench/../_build/default/workbench/bin/workbench_bundle.exe}
rayforce=${RAYFORCE:-rayforce}
"$cli" verify -directory "$directory"
exec "$rayforce" -c 1 -p "127.0.0.1:$port" -f "$service/open-bundle.rfl" -- \
  -service "$service/service.rfl" -bundle_module "$service/bundle.rfl" -directory "$directory"
