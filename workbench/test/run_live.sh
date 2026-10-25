#!/usr/bin/env bash
set -euo pipefail
exe=$(realpath "$1")
backtest=$(realpath "$2")
launcher=$(realpath "$(dirname "$0")/serve_fixture.sh")
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
log=$(mktemp)
extra=()
if [[ $# -ge 3 ]]; then
  launcher=$(realpath "$(dirname "$0")/../rayfall/serve-bundle.sh")
  source_directory=$(realpath "$3")
  extra=(--saved)
else
  source_directory=$backtest
fi
bash "$launcher" "$port" "$source_directory" >"$log" 2>&1 </dev/null &
server=$!
cleanup() {
  kill "$server" 2>/dev/null || true
  wait "$server" 2>/dev/null || true
  rm -f "$log"
}
trap cleanup EXIT
for ((attempt=0;attempt<100;attempt++)); do
  if ! kill -0 "$server" 2>/dev/null; then cat "$log"; exit 1; fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then break; fi
  sleep 0.05
done
if ! "$exe" "$port" "${extra[@]}"; then cat "$log"; exit 1; fi
