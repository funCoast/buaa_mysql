#!/usr/bin/env bash
set -euo pipefail

DB="${1:?DB required}"
WH="${2:?warehouse count required}"
ROOT_DIR="${ROOT_DIR:-/workspace/ltCopyWorkspace}"
WORKLOAD_DIR="$ROOT_DIR/workloads/tpcc-mysql"
MYSQL_BIN="${MYSQL_BIN:-$ROOT_DIR/mysql_install/bin/mysql}"
MYSQL_SOCKET="${MYSQL_SOCKET:-$ROOT_DIR/tmp/mysql-debug.sock}"
MYSQL_CMD=("$MYSQL_BIN" --protocol=socket -S "$MYSQL_SOCKET" -uroot)

"${MYSQL_CMD[@]}" -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\`;"
"${MYSQL_CMD[@]}" "$DB" < "$WORKLOAD_DIR/create_table.sql"
"${MYSQL_CMD[@]}" "$DB" < "$WORKLOAD_DIR/add_fkey_idx.sql"
(
  cd "$WORKLOAD_DIR"
  ROOT_DIR="$ROOT_DIR" ./load.sh "$DB" "$WH"
)
"${MYSQL_CMD[@]}" "$DB" < "$WORKLOAD_DIR/count.sql"
