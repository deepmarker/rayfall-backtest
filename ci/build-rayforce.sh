#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
revision=$(cat "$root/ci/rayforce-revision")
destination=${1:?usage: build-rayforce.sh DESTINATION}
if [[ ! -d $destination/.git ]]; then
  git init "$destination"
  git -C "$destination" remote add origin https://github.com/RayforceDB/rayforce.git
fi
git -C "$destination" fetch --depth 1 origin "$revision"
git -C "$destination" checkout --detach FETCH_HEAD
make -C "$destination" release -j"$(getconf _NPROCESSORS_ONLN)" CC=clang
