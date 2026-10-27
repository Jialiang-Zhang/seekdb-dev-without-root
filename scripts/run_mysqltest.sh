#!/bin/bash
# Run mysqltest cases without obd against a local seekdb.
# Usage: run_mysqltest.sh SUITE CASE [CASE ...]
# Env: SEEKDB_SRC (default ~/seekdb), SEEKDB_RUN (default ~/seekdb-run), SEEKDB_PORT (default 2881),
#      MT_RECORD=1 to record .result files instead of comparing.
set -u
[ $# -ge 2 ] || { echo "usage: $0 SUITE CASE [CASE ...]"; exit 2; }
SRC=${SEEKDB_SRC:-$HOME/seekdb}
RUN=${SEEKDB_RUN:-$HOME/seekdb-run}
PORT=${SEEKDB_PORT:-2881}
HERE=$(cd "$(dirname "$0")" && pwd)
SUITE=$1; shift
MT=$SRC/deps/3rd/u01/obclient/bin/mysqltest
[ -x "$MT" ] || { echo "mysqltest not found: $MT (run build.sh init first)"; exit 1; }

# Local Mock services listen on 127.0.0.1; never route them through a proxy.
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
# Variables obd normally exports for connect commands inside test files.
export OBMYSQL_MS0=127.0.0.1 OBMYSQL_MS0_DEV=lo OBMYSQL_PORT=$PORT OBMYSQL_USR=admin OBMYSQL_PWD=admin
# Some suites copy fixtures next to the observer through ssh/scp; run those locally.
export OBSERVER_DIR=$RUN/data PATH=$HERE/testbin:$PATH

OUT=$RUN/mysqltest/$SUITE
mkdir -p "$OUT/tmp" "$OUT/log"
mysql -h127.0.0.1 -P"$PORT" -uroot -e "create user if not exists 'admin' identified by 'admin';
  grant all on *.* to 'admin' with grant option; create database if not exists test" || exit 1

RECORD=()
[ "${MT_RECORD:-0}" = 1 ] && RECORD=(--record)
cd "$SRC/tools/deploy" || exit 1
pass=0; fail=0
for c in "$@"; do
  start=$(date +%s)
  # --password=admin, not "--password admin": the latter waits for a terminal prompt.
  timeout 1800 "$MT" "${RECORD[@]}" --host=127.0.0.1 --port="$PORT" --user=admin --password=admin \
    --database=test --silent --tmpdir="$OUT/tmp" --logdir="$OUT/log" --tail-lines=40 \
    --test-file="mysql_test/test_suite/$SUITE/t/$c.test" \
    --result-file="mysql_test/test_suite/$SUITE/r/mysql/$c.result" \
    < /dev/null > "$OUT/$c.out" 2>&1
  rc=$?
  el=$(( $(date +%s) - start ))
  if [ $rc -eq 0 ]; then
    pass=$((pass + 1)); echo "PASS $SUITE/$c (${el}s)"
  else
    fail=$((fail + 1)); echo "FAIL $SUITE/$c rc=$rc (${el}s) -> $OUT/$c.out"
  fi
done
echo "suite=$SUITE pass=$pass fail=$fail"
[ $fail -eq 0 ]
