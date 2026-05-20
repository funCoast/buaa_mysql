#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/workspace/ltCopyWorkspace}"
INSTALL_DIR="${INSTALL_DIR:-$ROOT_DIR/mysql_install}"
DATADIR="${DATADIR:-$INSTALL_DIR/data}"
TMP_DIR="${TMP_DIR:-$ROOT_DIR/tmp}"
PORT="${PORT:-3308}"
SOCKET="${SOCKET:-$TMP_DIR/mysql-debug.sock}"
PID_FILE="${PID_FILE:-$TMP_DIR/mysql-debug.pid}"
LOG_FILE="${LOG_FILE:-$TMP_DIR/mysqld-debug.log}"
MYSQL_USER="${MYSQL_USER:-root}"
CONSOLE="${CONSOLE:-0}"

mkdir -p "$TMP_DIR"
rm -f "$SOCKET" "$PID_FILE"

cmd=(
  "$INSTALL_DIR/bin/mysqld"
  --user="$MYSQL_USER"
  --datadir="$DATADIR"
  --port="$PORT"
  --socket="$SOCKET"
  --pid-file="$PID_FILE"
  --performance_schema=ON
  --mysqlx=OFF
  --ssl=0
  --secure-file-priv=
)

if [[ "$CONSOLE" == "1" ]]; then
  echo "Starting mysqld in console mode..."
  exec "${cmd[@]}" --console
fi

echo "Starting mysqld in background..."
nohup "${cmd[@]}" >"$LOG_FILE" 2>&1 &
echo $! > "$TMP_DIR/mysqld-launch.pid"
echo "socket=$SOCKET"
echo "port=$PORT"
echo "log=$LOG_FILE"
echo "pid=$!"
