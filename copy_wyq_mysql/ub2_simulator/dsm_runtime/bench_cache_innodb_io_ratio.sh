#!/usr/bin/env bash
# ============================================================================
# 与 bench_cache.sh 相同场景（小 BP、hot 全表扫、NO_CACHE vs DSM），
# 仅用 InnoDB 在 performance_schema.global_status 里的计数器，估算
# 「数据文件读」在逻辑读里的占比，不依赖 fil_read_cache / touch dump。
#
# 使用的状态变量（MySQL 8.4 语义，见手册 InnoDB Standard Monitor）：
#   Innodb_buffer_pool_read_requests  — 引擎发起的逻辑读页请求次数（大）
#   Innodb_buffer_pool_reads        — 无法从 BP 满足、从磁盘同步读入 BP 的页次数
#   Innodb_buffer_pool_read_ahead   — 预读页数
#   Innodb_pages_read               — 读入 BP 的页数（含 sync + read-ahead）
#   Innodb_data_reads               — InnoDB 对数据文件的读系统调用次数（近似 OS 读次数）
#   Innodb_data_read                — 从数据文件读入的字节数（累计）
#
# 输出的「占比」均为「整段 bench 查询窗口内」的累计 delta 之比（百分数）：
#   bp_sync%   = 100 * sum(Δ buffer_pool_reads) / sum(Δ read_requests)
#   bp_sync_ra%= 100 * sum(Δ reads + Δ read_ahead) / sum(Δ read_requests)
#   pages%     = 100 * sum(Δ pages_read) / sum(Δ read_requests)
#   data_reads%=100 * sum(Δ Innodb_data_reads) / sum(Δ read_requests)
#   data_bytes/req = sum(Δ Innodb_data_read) / sum(Δ read_requests)  (字节/请求，非百分比)
#
# 「数据文件 I/O 时间 / 端到端墙钟时间」（Performance Schema，皮秒→纳秒）：
#   每轮在客户端包一层 date，测「一次 mysql 执行 SELECT」墙钟时间 sum_wall_ns；
#   同时读 events_waits_summary_global_by_event_name 里
#   event_name LIKE 'wait/io/file/innodb/innodb_data_file%' 的 SUM(sum_timer_wait)，
#   做轮次前后差得到 Δwait（所有线程在该类 wait 上的累计等待时间之和）。
#   datafile_wait_wall_% = 100 * sum(Δwait_ps) / sum_wall_ns / 1000
#   （wait 为皮秒，墙钟为纳秒，故除以 1000 对齐到纳秒再比。）
#   注意：Δwait 含**所有连接/后台线程**在同一时间窗内的数据文件等待；并行多
#   I/O 线程时 sum(等待) 可大于单线程墙钟，比值**可超过 100%**，这是 P_S 语义
#   而非纯「单查询独占」的 CPU 占比。
#
# 用法（与 bench_cache 对齐）：
#   ./bench_cache_innodb_io_ratio.sh
#   ./bench_cache_innodb_io_ratio.sh -r 5 -p 1500
#   ./bench_cache_innodb_io_ratio.sh --only no
#   ./bench_cache_innodb_io_ratio.sh --mem          # 不启 simulator，第二组改为 mem-fallback
# ============================================================================
set -euo pipefail

ROUNDS=5
HOT_PAGES=1500
ONLY=""
USE_DSM=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r) ROUNDS="$2"; shift 2 ;;
    -p) HOT_PAGES="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --mem)  USE_DSM=0; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ROOT=/workspace
SIM_DIR=${ROOT}/ub2_simulator
SIM_BUILD=${SIM_DIR}/dsm_runtime/build
MYSQL_INSTALL=${ROOT}/mysql_install
MYSQL_BIN=${MYSQL_INSTALL}/bin
MYSQL_DATA=${MYSQL_INSTALL}/data
MYSQL_SOCK=/tmp/mysql-bench-io.sock
MYSQL_PORT=3311
LOG_DIR=/tmp/dsm_bench_innodb_io_logs
CLEAN=${SIM_DIR}/dsm_runtime/cleanup.sh
ROWS=$(( HOT_PAGES * 30 ))

mkdir -p "${LOG_DIR}"

say()   { printf "\n\033[1;36m[innodb-io]\033[0m %s\n" "$*"; }
green() { printf "\033[1;32m%s\033[0m\n" "$*"; }

pct() {
  # pct num den → 百分数字符串，den=0 时返回 "n/a"
  awk -v n="$1" -v d="$2" 'BEGIN {
    if (d == 0) { print "n/a"; exit }
    printf "%.4f", 100.0 * n / d
  }'
}

ratio_bytes() {
  awk -v b="$1" -v d="$2" 'BEGIN {
    if (d == 0) { print "n/a"; exit }
    printf "%.2f", b / d
  }'
}

wait_mysqld() {
  for _ in $(seq 1 80); do
    if "${MYSQL_BIN}/mysqladmin" -S "$MYSQL_SOCK" -u root ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

MYSQLD_PID=""
stop_mysqld() {
  if [[ -n "${MYSQLD_PID:-}" ]] && kill -0 "${MYSQLD_PID}" 2>/dev/null; then
    "${MYSQL_BIN}/mysqladmin" -S "$MYSQL_SOCK" -u root shutdown 2>/dev/null || \
      kill "${MYSQLD_PID}" 2>/dev/null || true
    wait "${MYSQLD_PID}" 2>/dev/null || true
  fi
  MYSQLD_PID=""
}

trap 'stop_mysqld; "$CLEAN" >/dev/null 2>&1 || true' EXIT INT TERM

start_mysqld() {
  local tag="$1" log="$2"
  shift 2
  say "starting mysqld (${tag}) -> $log"
  "${MYSQL_BIN}/mysqld" \
    --datadir="${MYSQL_DATA}" \
    --socket="${MYSQL_SOCK}" \
    --port="${MYSQL_PORT}" \
    --pid-file=/tmp/mysql-bench-io.pid \
    --innodb-buffer-pool-size=5M \
    --innodb-buffer-pool-chunk-size=1M \
    --innodb-buffer-pool-instances=1 \
    --innodb-flush-method=O_DIRECT_NO_FSYNC \
    --innodb-doublewrite=OFF \
    --log-error-verbosity=1 \
    --user="$(whoami)" \
    "$@" \
    >"$log" 2>&1 &
  MYSQLD_PID=$!
  if ! wait_mysqld; then
    echo "mysqld (${tag}) failed:" >&2
    tail -n 60 "$log" >&2
    exit 1
  fi
  green "mysqld (${tag}) pid=${MYSQLD_PID}"
}

get_status() {
  "${MYSQL_BIN}/mysql" -S "$MYSQL_SOCK" -u root -N -B -e \
    "SELECT VARIABLE_VALUE+0 FROM performance_schema.global_status
     WHERE VARIABLE_NAME='$1'" 2>/dev/null || echo 0
}

# InnoDB 数据文件 wait 累计（皮秒），全局表自 mysqld 启动以来单调增
get_ps_datafile_wait_ps() {
  local v
  v=$("${MYSQL_BIN}/mysql" -S "$MYSQL_SOCK" -u root -N -B -e \
    "SELECT IFNULL(SUM(sum_timer_wait),0)
     FROM performance_schema.events_waits_summary_global_by_event_name
     WHERE event_name LIKE 'wait/io/file/innodb/innodb_data_file%'" \
    2>/dev/null) || v=0
  v=${v//$'\r'/}
  v=${v//$'\n'/}
  printf '%s' "${v:-0}"
}

enable_ps_datafile_waits() {
  "${MYSQL_BIN}/mysql" -S "$MYSQL_SOCK" -u root -N -e \
    "UPDATE performance_schema.setup_consumers SET ENABLED='YES'
       WHERE NAME IN ('global_instrumentation','thread_instrumentation');
     UPDATE performance_schema.setup_instruments
       SET ENABLED='YES', TIMED='YES'
       WHERE NAME LIKE 'wait/io/file/innodb/innodb_data_file%'" \
    >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
"$CLEAN" >/dev/null 2>&1 || true
"$CLEAN" --purge-shm >/dev/null 2>&1 || true

if [[ "$USE_DSM" -eq 1 ]]; then
  say "simulator + export_client"
  # shellcheck source=/dev/null
  . "${SIM_DIR}/sim_env.sh"
  ( cd "${SIM_BUILD}" && mpirun -np 4 ./simulator ) \
    >"${LOG_DIR}/simulator.log" 2>&1 &
  for _ in $(seq 1 50); do
    [[ -S /tmp/obmm_simulator_node0.sock ]] && break
    sleep 0.2
  done
  ( cd "${SIM_BUILD}" && mpirun -np 4 ./export_client ) \
    >"${LOG_DIR}/export_client.log" 2>&1
  for m in 1 2 3; do
    [[ -e "/dev/shm/virtual_node0/obmm_shmdev${m}" ]] || { echo "missing obmm_shmdev${m}"; exit 4; }
  done
  green "DSM shm ready"
else
  say "跳过 simulator（--mem）"
fi

say "prep: hot ~${HOT_PAGES} pages (${ROWS} rows)"
FIL_READ_CACHE_ENABLE=0 start_mysqld "prep" "${LOG_DIR}/mysqld_prep.log"
MYSQL="${MYSQL_BIN}/mysql -S ${MYSQL_SOCK} -u root"
$MYSQL <<SQL
CREATE DATABASE IF NOT EXISTS benchdb;
USE benchdb;
DROP TABLE IF EXISTS hot;
CREATE TABLE hot (
  id   INT PRIMARY KEY AUTO_INCREMENT,
  pad1 CHAR(255) NOT NULL,
  pad2 CHAR(255) NOT NULL
) ENGINE=InnoDB ROW_FORMAT=COMPACT;
INSERT INTO hot (pad1, pad2) VALUES (REPEAT('X',255), REPEAT('Y',255));
SQL
CUR=1
while [[ $CUR -lt $ROWS ]]; do
  $MYSQL -e "USE benchdb; INSERT INTO hot (pad1, pad2) SELECT pad1, pad2 FROM hot LIMIT $CUR;" >/dev/null
  CUR=$(( CUR * 2 ))
done
$MYSQL -e "ANALYZE TABLE benchdb.hot;" >/dev/null
$MYSQL -e "FLUSH TABLES benchdb.hot WITH READ LOCK; UNLOCK TABLES;" >/dev/null || true
stop_mysqld

run_case() {
  local name="$1" log="$2"; shift 2
  local envs=("$@")
  say "=== ${name} (${envs[*]}) ==="
  local e
  for e in "${envs[@]}"; do export "$e"; done

  start_mysqld "$name" "$log"
  MYSQL="${MYSQL_BIN}/mysql -S ${MYSQL_SOCK} -u root"
  enable_ps_datafile_waits
  local Q="SELECT SUM(CRC32(pad1) + CRC32(pad2)) FROM benchdb.hot"

  local sum_br=0 sum_bq=0 sum_ra=0 sum_pr=0 sum_dr=0 sum_dbytes=0
  local sum_wall_ns=0 sum_wait_ps=0
  local r1_br=0 r1_bq=0 r1_ra=0 r1_pr=0 r1_dr=0 r1_db=0
  local r1_wall_ns=0 r1_wait_ps=0
  local i ms t0 t1 tw_ns dps dw_ms

  for i in $(seq 1 "$ROUNDS"); do
    local br0 bq0 ra0 pr0 dr0 db0 br1 bq1 ra1 pr1 dr1 db1
    br0=$(get_status Innodb_buffer_pool_reads)
    bq0=$(get_status Innodb_buffer_pool_read_requests)
    ra0=$(get_status Innodb_buffer_pool_read_ahead)
    pr0=$(get_status Innodb_pages_read)
    dr0=$(get_status Innodb_data_reads)
    db0=$(get_status Innodb_data_read)

    local ps0 ps1
    ps0=$(get_ps_datafile_wait_ps)
    t0=$(date +%s%N)
    "${MYSQL_BIN}/mysql" -S "$MYSQL_SOCK" -u root -N -e "$Q" >/dev/null
    t1=$(date +%s%N)
    ps1=$(get_ps_datafile_wait_ps)
    tw_ns=$(( t1 - t0 ))
    ms=$(( tw_ns / 1000000 ))
    dps=$(( ps1 - ps0 ))
    [[ "$dps" -lt 0 ]] && dps=0
    dw_ms=$(( dps / 1000000000 ))
    sum_wall_ns=$(( sum_wall_ns + tw_ns ))
    sum_wait_ps=$(( sum_wait_ps + dps ))

    br1=$(get_status Innodb_buffer_pool_reads)
    bq1=$(get_status Innodb_buffer_pool_read_requests)
    ra1=$(get_status Innodb_buffer_pool_read_ahead)
    pr1=$(get_status Innodb_pages_read)
    dr1=$(get_status Innodb_data_reads)
    db1=$(get_status Innodb_data_read)

    local dbr dbq dra dpr ddr ddb
    dbr=$(( br1 - br0 ))
    dbq=$(( bq1 - bq0 ))
    dra=$(( ra1 - ra0 ))
    dpr=$(( pr1 - pr0 ))
    ddr=$(( dr1 - dr0 ))
    ddb=$(( db1 - db0 ))

    sum_br=$(( sum_br + dbr ))
    sum_bq=$(( sum_bq + dbq ))
    sum_ra=$(( sum_ra + dra ))
    sum_pr=$(( sum_pr + dpr ))
    sum_dr=$(( sum_dr + ddr ))
    sum_dbytes=$(( sum_dbytes + ddb ))

    if [[ "$i" -eq 1 ]]; then
      r1_br=$dbr; r1_bq=$dbq; r1_ra=$dra; r1_pr=$dpr; r1_dr=$ddr; r1_db=$ddb
      r1_wall_ns=$tw_ns
      r1_wait_ps=$dps
    fi

    printf "  round %2d  wall=%5d ms  datafile_wait=%6d ms  d_reqs=%-7d d_bp_reads=%-5d d_ra=%-5d d_pages=%-5d d_data_rd=%-5d d_bytes=%s\n" \
      "$i" "$ms" "$dw_ms" "$dbq" "$dbr" "$dra" "$dpr" "$ddr" "$ddb"
  done

  stop_mysqld
  for e in "${envs[@]}"; do unset "${e%%=*}"; done

  local sum_fil=$(( sum_br + sum_ra ))
  local p_sync p_fil p_pages p_dr p_bytes

  p_sync=$(pct "$sum_br" "$sum_bq")
  p_fil=$(pct "$sum_fil" "$sum_bq")
  p_pages=$(pct "$sum_pr" "$sum_bq")
  p_dr=$(pct "$sum_dr" "$sum_bq")
  p_bytes=$(ratio_bytes "$sum_dbytes" "$sum_bq")

  echo "  --- 累计 ${ROUNDS} 轮（相对 sum(Δ read_requests)）---"
  printf "  bp_sync%%          (buffer_pool_reads / read_requests)     = %s %%\n" "$p_sync"
  printf "  bp_sync+ra%%       ((reads+read_ahead) / read_requests)  = %s %%\n" "$p_fil"
  printf "  pages_read%%       (pages_read / read_requests)           = %s %%\n" "$p_pages"
  printf "  innodb_data_reads%% (Innodb_data_reads / read_requests)   = %s %%\n" "$p_dr"
  printf "  data_bytes_per_req (Δ Innodb_data_read / read_requests)  = %s B/req\n" "$p_bytes"

  local p1s p1f
  p1s=$(pct "$r1_br" "$r1_bq")
  p1f=$(pct "$(( r1_br + r1_ra ))" "$r1_bq")
  echo "  --- 仅第 1 轮 ---"
  printf "  bp_sync%%=%s %%   bp_sync+ra%%=%s %%\n" "$p1s" "$p1f"
  local w1_pct
  w1_pct=$(awk -v w="$r1_wait_ps" -v wall="$r1_wall_ns" 'BEGIN {
    if (wall <= 0) { print "n/a"; exit }
    printf "%.2f", 100.0 * (w/1000) / wall
  }')
  r1_dw_ms=$(( r1_wait_ps / 1000000000 ))
  printf "  第1轮 datafile_wait=%d ms / wall=%.3f s => P_S_wait/墙钟≈ %s %%\n" \
    "$r1_dw_ms" "$(awk -v n="$r1_wall_ns" 'BEGIN{printf "%.3f", n/1e9}')" "$w1_pct"

  local pct_wait_wall
  pct_wait_wall=$(awk -v w="$sum_wait_ps" -v wall="$sum_wall_ns" 'BEGIN {
    if (wall <= 0) { print "n/a"; exit }
    printf "%.2f", 100.0 * (w/1000) / wall
  }')
  local sum_wall_ms sum_wait_ms
  sum_wall_ms=$(( sum_wall_ns / 1000000 ))
  sum_wait_ms=$(( sum_wait_ps / 1000000000 ))
  echo "  --- 端到端墙钟 vs InnoDB 数据文件 wait（P_S 全局累加，可>100%%）---"
  printf "  sum_wall=%d ms  sum_datafile_wait(P_S)=%d ms  wait/墙钟≈ %s %%\n" \
    "$sum_wall_ms" "$sum_wait_ms" "$pct_wait_wall"

  eval "IO_${name}_sum_bq=$sum_bq"
  eval "IO_${name}_sum_br=$sum_br"
  eval "IO_${name}_sum_ra=$sum_ra"
  eval "IO_${name}_sum_pr=$sum_pr"
  eval "IO_${name}_sum_dr=$sum_dr"
  eval "IO_${name}_sum_dbytes=$sum_dbytes"
  eval "IO_${name}_pct_sync=$p_sync"
  eval "IO_${name}_pct_fil=$p_fil"
  eval "IO_${name}_pct_pages=$p_pages"
  eval "IO_${name}_pct_dr=$p_dr"
  eval "IO_${name}_pct_wait_wall=${pct_wait_wall}"
  eval "IO_${name}_sum_wall_ms=${sum_wall_ms}"
  eval "IO_${name}_sum_wait_ms=${sum_wait_ms}"
}

if [[ -z "$ONLY" || "$ONLY" == "no" ]]; then
  run_case "NO_CACHE" "${LOG_DIR}/mysqld_no_cache.log" FIL_READ_CACHE_ENABLE=0
fi

if [[ -z "$ONLY" || "$ONLY" == "dsm" ]]; then
  if [[ "$USE_DSM" -eq 1 ]]; then
    run_case "DSM" "${LOG_DIR}/mysqld_dsm.log" FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=1
  else
    run_case "MEM_L2" "${LOG_DIR}/mysqld_mem_l2.log" FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=0
  fi
fi

say "=============== 对比（累计 ${ROUNDS} 轮）==============="
printf "%-12s %8s %8s %10s %10s %10s %10s %10s %12s\n" \
  mode "wall_ms" "wait_ms" "bp_sync%" "sync+ra%" "pages_r%" "data_rd%" "wait/墙%" "bytes/req"
print_row() {
  local n=$1
  v=$(eval echo \$IO_${n}_pct_sync); [[ -z "$v" ]] && return
  printf "%-12s %8s %8s %10s %10s %10s %10s %10s %12s\n" \
    "$n" \
    "$(eval echo \$IO_${n}_sum_wall_ms)" \
    "$(eval echo \$IO_${n}_sum_wait_ms)" \
    "$(eval echo \$IO_${n}_pct_sync)" \
    "$(eval echo \$IO_${n}_pct_fil)" \
    "$(eval echo \$IO_${n}_pct_pages)" \
    "$(eval echo \$IO_${n}_pct_dr)" \
    "$(eval echo \$IO_${n}_pct_wait_wall)" \
    "$(ratio_bytes "$(eval echo \$IO_${n}_sum_dbytes)" "$(eval echo \$IO_${n}_sum_bq)")"
}
print_row NO_CACHE
print_row DSM
print_row MEM_L2

say "日志目录: ${LOG_DIR}/"
say "说明: read_requests 为逻辑读次数；wait/墙% 为 P_S 上 innodb_data_file 类 wait 时间之和 / 客户端 mysql 墙钟之和（多线程 I/O 时可>100%）。"
