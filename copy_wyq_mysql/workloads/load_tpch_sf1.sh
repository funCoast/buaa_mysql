#!/usr/bin/env bash
set -euo pipefail

DB="${1:-tpch}"
ROOT_DIR="${ROOT_DIR:-/workspace/ltCopyWorkspace}"
WORKLOAD_DIR="$ROOT_DIR/workloads"
MYSQL_BIN="${MYSQL_BIN:-$ROOT_DIR/mysql_install/bin/mysql}"
MYSQL_SOCKET="${MYSQL_SOCKET:-$ROOT_DIR/tmp/mysql-debug.sock}"
DATA_DIR="${DATA_DIR:-$WORKLOAD_DIR/tpch_data/sf1}"
SCHEMA_SQL="$WORKLOAD_DIR/tpch_schema_mysql.sql"
MYSQL_CMD=("$MYSQL_BIN" --protocol=socket -S "$MYSQL_SOCKET" -uroot)

"${MYSQL_CMD[@]}" -e "DROP DATABASE IF EXISTS \`$DB\`; CREATE DATABASE \`$DB\`;"
"${MYSQL_CMD[@]}" "$DB" < "$SCHEMA_SQL"

load_tbl() {
  local table="$1"
  local cols="$2"
  local file="$DATA_DIR/${table}.tbl"
  "${MYSQL_CMD[@]}" "$DB" -e "LOAD DATA INFILE '$file' INTO TABLE $table FIELDS TERMINATED BY '|' LINES TERMINATED BY '\n' ($cols, @dummy);"
}

load_tbl region   "r_regionkey, r_name, r_comment"
load_tbl nation   "n_nationkey, n_name, n_regionkey, n_comment"
load_tbl supplier "s_suppkey, s_name, s_address, s_nationkey, s_phone, s_acctbal, s_comment"
load_tbl customer "c_custkey, c_name, c_address, c_nationkey, c_phone, c_acctbal, c_mktsegment, c_comment"
load_tbl part     "p_partkey, p_name, p_mfgr, p_brand, p_type, p_size, p_container, p_retailprice, p_comment"
load_tbl partsupp "ps_partkey, ps_suppkey, ps_availqty, ps_supplycost, ps_comment"
load_tbl orders   "o_orderkey, o_custkey, o_orderstatus, o_totalprice, o_orderdate, o_orderpriority, o_clerk, o_shippriority, o_comment"
load_tbl lineitem "l_orderkey, l_partkey, l_suppkey, l_linenumber, l_quantity, l_extendedprice, l_discount, l_tax, l_returnflag, l_linestatus, l_shipdate, l_commitdate, l_receiptdate, l_shipinstruct, l_shipmode, l_comment"

echo "Loaded TPCH SF1 into $DB"
