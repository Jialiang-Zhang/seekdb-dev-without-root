#!/bin/bash
# Start a fresh standalone seekdb test instance and wait until SQL is available.
# Env: SEEKDB_SRC (source tree, default ~/seekdb), SEEKDB_RUN (wiped, default ~/seekdb-run),
#      SEEKDB_PORT (default 2881), SEEKDB_MEMORY (default 6G).
set -u
SRC=${SEEKDB_SRC:-$HOME/seekdb}
RUN=${SEEKDB_RUN:-$HOME/seekdb-run}
PORT=${SEEKDB_PORT:-2881}
MEMORY=${SEEKDB_MEMORY:-6G}
BIN=$SRC/build_release/src/observer/seekdb
[ -x "$BIN" ] || { echo "seekdb binary not found: $BIN"; exit 1; }

if [ -f "$RUN/pid" ]; then
  old=$(cat "$RUN/pid")
  kill "$old" 2>/dev/null
  for _ in $(seq 1 30); do kill -0 "$old" 2>/dev/null || break; sleep 1; done
  kill -9 "$old" 2>/dev/null
fi
rm -rf "$RUN" && mkdir -p "$RUN/bin" "$RUN/lib" "$RUN/data/run"
cp "$BIN" "$RUN/bin/"
# Ubuntu 24.04 ships libaio as libaio.so.1t64 only.
if [ -e /usr/lib/x86_64-linux-gnu/libaio.so.1t64 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libaio.so.1 ]; then
  ln -s /usr/lib/x86_64-linux-gnu/libaio.so.1t64 "$RUN/lib/libaio.so.1"
fi

# Start inside the base dir: telemetry is written to ./run/telemetry.json.
cd "$RUN/data"
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost LD_LIBRARY_PATH="$RUN/lib" \
  nohup "$RUN/bin/seekdb" --nodaemon --base-dir "$RUN/data" -P "$PORT" \
    --parameter memory_budget="$MEMORY" --parameter datafile_size=4G \
    --parameter datafile_maxsize=8G --parameter log_disk_size=4G \
    > "$RUN/stdout.log" 2>&1 &
echo $! > "$RUN/pid"

for i in $(seq 1 180); do
  if mysql -h127.0.0.1 -P"$PORT" -uroot -e "select 1" >/dev/null 2>&1; then
    echo "seekdb ready on 127.0.0.1:$PORT after ${i}s (pid $(cat "$RUN/pid"))"
    exit 0
  fi
  if ! kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then
    echo "seekdb exited during startup"; tail -30 "$RUN/stdout.log"; exit 1
  fi
  sleep 1
done
echo "seekdb not ready after 180s"; tail -30 "$RUN/stdout.log"; exit 1
