#!/usr/bin/env bash
# ============================================================================
# MySQL fil_read_cache 的 A/B 基准测试：
#   A) NO-CACHE  : FIL_READ_CACHE_ENABLE=0        → 纯 InnoDB 路径（无 L2）
#   B) DSM       : FIL_READ_CACHE_ENABLE=1 +
#                  DSM_BRIDGE_ENABLE=1            → 走 DSM 分布式二级缓存
#
# 构造的小表场景：
#   * BufferPool = 5 MB（最小值），约 320 个 16K 页
#   * innodb_flush_method = O_DIRECT_NO_FSYNC     → 绕过 OS 页面缓存，
#                                                   让"磁盘读"有真实代价
#   * 热表 hot 约 1500 页 ≈ 24 MB                  → BP 装不下 / DSM 装得下
#
# 工作流：对同一张表做 N 次全表扫描
#   Round 1: BP 冷 → BP miss → 试 L2 → miss → O_DIRECT 读盘 → put L2
#   Round 2..N: BP 仍小 → 每次都 BP miss → L2 命中（DSM 时）/ 继续读盘（NO-CACHE）
#
# 期望：DSM 组的 Round 2+ 远快于 NO-CACHE 组。
#
# 用法：
#   ./bench_cache.sh                 # 默认 5 轮扫描、~1500 页热集
#   ./bench_cache.sh -r 10 -p 2000   # 10 轮 / 2000 页
#   ./bench_cache.sh --trace         # 打开 fil_read_cache 的每页 log（慢！）
#   ./bench_cache.sh --trace-flow    # 跑一个单行查询 + per-page log
#                                    #   可看 BP/DSM/DISK 三路读的日志
#   ./bench_cache.sh --only dsm      # 只跑 DSM 组
#   ./bench_cache.sh --only no       # 只跑 NO-CACHE 组
# ============================================================================
set -euo pipefail

ROUNDS=5
HOT_PAGES=1500      # 期望的 hot set 页数 (approx)
TRACE=0
TRACE_FLOW=0        # --trace-flow: 只跑一个小查询，打开 per-page log 展示读路径
ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r) ROUNDS="$2"; shift 2 ;;
    -p) HOT_PAGES="$2"; shift 2 ;;
    --trace) TRACE=1; shift ;;
    --trace-flow) TRACE_FLOW=1; TRACE=1; ROUNDS=1; shift ;;
    --only) ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -d /workspace/ltCopyWorkspace/mysql-server-8.4 ]]; then
  ROOT=/workspace/ltCopyWorkspace
else
  ROOT=/workspace
fi
SIM_DIR=${ROOT}/ub2_simulator
SIM_BUILD=${SIM_DIR}/dsm_runtime/build
MYSQL_INSTALL=${ROOT}/mysql_install
MYSQL_BIN=${MYSQL_INSTALL}/bin
MYSQL_DATA=${MYSQL_INSTALL}/data
MYSQL_SOCK=/tmp/mysql-bench.sock
MYSQL_PORT=3309
MYSQL_PID_FILE=/tmp/mysql-bench.pid
MYSQLX_SOCK=/tmp/mysqlx-bench.sock
LOG_DIR=/tmp/dsm_bench_logs
CLEAN=${SIM_DIR}/dsm_runtime/cleanup.sh
MYSQL_RUN_USER=${MYSQL_RUN_USER:-root}
export MYSQL_INSTALL MYSQL_SOCK MYSQL_PID_FILE MYSQLX_SOCK
mkdir -p "${LOG_DIR}"

# 使用 COMPACT + CHAR(255) x 2 固定行 ~514 B → ~30 行/页（都保证 inline）
ROWS=$(( HOT_PAGES * 30 ))

say()  { printf "\n\033[1;36m[bench]\033[0m %s\n" "$*"; }
green(){ printf "\033[1;32m%s\033[0m\n" "$*"; }

reset_mysql_runtime_files() {
  rm -f "${MYSQL_SOCK}" "${MYSQL_PID_FILE}" "${MYSQLX_SOCK}" \
        "${MYSQLX_SOCK}.lock" /tmp/mysqlx.sock /tmp/mysqlx.sock.lock
}


ensure_datadir() {
  if [[ -d "${MYSQL_DATA}/mysql" ]]; then
    return 0
  fi
  say "initializing MySQL datadir -> ${MYSQL_DATA}"
  rm -rf "${MYSQL_DATA}"
  mkdir -p "${MYSQL_DATA}"
  reset_mysql_runtime_files
  "${MYSQL_BIN}/mysqld"     --initialize-insecure     --basedir="${MYSQL_INSTALL}"     --datadir="${MYSQL_DATA}"     --log-error="${LOG_DIR}/mysqld_init.log"     --user="${MYSQL_RUN_USER}"
}

# ---------------------------------------------------------------------------
# 通用：等待 mysqld ping 成功
# ---------------------------------------------------------------------------
wait_mysqld() {
  for _ in $(seq 1 80); do
    if [[ -n "${MYSQLD_PID:-}" ]] && ! kill -0 "${MYSQLD_PID}" 2>/dev/null; then
      return 1
    fi
    if "${MYSQL_BIN}/mysqladmin" --protocol=socket -S "$MYSQL_SOCK" -u root ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

start_mysqld() {
  local tag="$1" log="$2"
  shift 2
  say "starting mysqld (${tag}) -> $log"
  reset_mysql_runtime_files
  : >"$log"
  "${MYSQL_BIN}/mysqld"     --datadir="${MYSQL_DATA}"     --socket="${MYSQL_SOCK}"     --port="${MYSQL_PORT}"     --pid-file="${MYSQL_PID_FILE}"     --mysqlx=OFF     --innodb-buffer-pool-size=5M     --innodb-buffer-pool-chunk-size=1M     --innodb-buffer-pool-instances=1     --innodb-flush-method=O_DIRECT_NO_FSYNC     --innodb-doublewrite=OFF     --log-error-verbosity=1     --user="${MYSQL_RUN_USER}"     "$@"     >"$log" 2>&1 &
  MYSQLD_PID=$!
  if ! wait_mysqld; then
    echo "mysqld (${tag}) failed to start:" >&2
    tail -n 120 "$log" >&2
    return 1
  fi
  green "mysqld (${tag}) pid=${MYSQLD_PID}"
}

stop_mysqld() {
  if [[ -n "${MYSQLD_PID:-}" ]] && kill -0 "${MYSQLD_PID}" 2>/dev/null; then
    "${MYSQL_BIN}/mysqladmin" --protocol=socket -S "$MYSQL_SOCK" -u root shutdown 2>/dev/null ||       kill "${MYSQLD_PID}" 2>/dev/null || true
    wait "${MYSQLD_PID}" 2>/dev/null || true
  fi
  reset_mysql_runtime_files
  MYSQLD_PID=""
}

trap 'stop_mysqld; "$CLEAN" >/dev/null 2>&1 || true' EXIT INT TERM

# ---------------------------------------------------------------------------
# 0) 先彻底清一遍
# ---------------------------------------------------------------------------
"$CLEAN" >/dev/null 2>&1 || true
"$CLEAN" --purge-shm >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 1) 启动 simulator + export_client（只做一次，两次 mysqld 都复用）
# ---------------------------------------------------------------------------
say "starting simulator + export_client"
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
  [[ -e "/dev/shm/virtual_node0/obmm_shmdev${m}" ]] || {
    echo "export_client did not leave obmm_shmdev${m}"; exit 4; }
done
green "simulator ready, DSM shm files: $(ls /dev/shm/virtual_node0 | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 2) 造数据：一次性用"任意"一侧的 mysqld（我们用 NO-CACHE 模式）把 hot 表
#    建好。之后两个对照组都读这张已有的表。
# ---------------------------------------------------------------------------
ensure_datadir
say "one-time data prep: create hot table with ~${HOT_PAGES} pages (${ROWS} rows)"
FIL_READ_CACHE_ENABLE=0 start_mysqld "prep" "${LOG_DIR}/mysqld_prep.log"

MYSQL="${MYSQL_BIN}/mysql -S ${MYSQL_SOCK} -u root"
$MYSQL <<SQL
CREATE DATABASE IF NOT EXISTS benchdb;
USE benchdb;
DROP TABLE IF EXISTS hot;
CREATE TABLE hot (
  id   INT PRIMARY KEY AUTO_INCREMENT,
  pad1 CHAR(255) NOT NULL,
  pad2 CHAR(255) NOT NULL                         -- 514B/行，全部 inline
) ENGINE=InnoDB ROW_FORMAT=COMPACT;

INSERT INTO hot (pad1, pad2) VALUES (REPEAT('X',255), REPEAT('Y',255));
SQL

CUR=1
while [[ $CUR -lt $ROWS ]]; do
  $MYSQL -e "USE benchdb;
             INSERT INTO hot (pad1, pad2)
             SELECT pad1, pad2 FROM hot LIMIT $CUR;" >/dev/null
  CUR=$(( CUR * 2 ))
done

$MYSQL -e "ANALYZE TABLE benchdb.hot;" >/dev/null

ACTUAL=$($MYSQL -N -e "SELECT COUNT(*) FROM benchdb.hot;")
PAGES=$($MYSQL -N -e "SELECT IFNULL(data_length/16384,0) FROM information_schema.tables WHERE table_schema='benchdb' AND table_name='hot';")
say "hot table: rows=${ACTUAL}, approx pages=${PAGES}"

# 确保所有数据都 flush 到 ibd，避免后续 BP 内热数据干扰
$MYSQL -e "FLUSH TABLES benchdb.hot WITH READ LOCK; UNLOCK TABLES;" >/dev/null || true
stop_mysqld

# ---------------------------------------------------------------------------
# 3) 单轮 bench 函数：启动给定模式的 mysqld，做 $ROUNDS 轮扫描，打印时间
# ---------------------------------------------------------------------------
get_status() {
  "${MYSQL_BIN}/mysql" -S "$MYSQL_SOCK" -u root -N -B -e \
    "SELECT VARIABLE_VALUE+0 FROM performance_schema.global_status
     WHERE VARIABLE_NAME='$1'"
}

run_bench() {
  local name="$1" log="$2"; shift 2
  local envs=("$@")
  say "=== BENCH [${name}] (${envs[*]}) ==="
  local e
  for e in "${envs[@]}"; do export "$e"; done
  export FIL_READ_CACHE_TRACE=${TRACE}
  start_mysqld "$name" "$log"

  # 定长 CHAR inline，SUM(CRC32) 强制读取每行数据 → 每个 16K 页都被访问
  local Q="SELECT SUM(CRC32(pad1) + CRC32(pad2)) FROM benchdb.hot"
  # --trace-flow: 换成单行 lookup，输出可控（只触发几个 B-tree 页）
  if [[ "${TRACE_FLOW}" -eq 1 ]]; then
    Q="SELECT id, LENGTH(pad1)+LENGTH(pad2) FROM benchdb.hot WHERE id=12345"
  fi
  local results=() bp_reads_rounds=() bp_reqs_rounds=()

  # 启动时基线（冷 BP），后续 delta 基于每轮前后快照
  local ra_rounds=() pr_rounds=() dr_rounds=()
  # 每轮查询前后 touch /tmp/fil_read_cache_dump, 让 mysqld 后台 dumper 把当前
  # fil_read_cache 累计值打到 error log。pairs 里的 delta = 本轮查询的真实
  # fil_read_cache 活动（排除启动期 metadata 读）
  trigger_dump() { rm -f /tmp/fil_read_cache_dump 2>/dev/null || true; touch /tmp/fil_read_cache_dump; }
  wait_dumped()  { for _ in $(seq 1 40); do [[ ! -e /tmp/fil_read_cache_dump ]] && return; sleep 0.01; done; }

  for i in $(seq 1 "$ROUNDS"); do
    # 前快照
    local br0 bq0 ra0 pr0 dr0
    br0=$(get_status Innodb_buffer_pool_reads)
    bq0=$(get_status Innodb_buffer_pool_read_requests)
    ra0=$(get_status Innodb_buffer_pool_read_ahead)
    pr0=$(get_status Innodb_pages_read)
    dr0=$(get_status Innodb_data_reads)

    trigger_dump; wait_dumped

    local t0 t1
    t0=$(date +%s%N)
    "${MYSQL_BIN}/mysql" -S "$MYSQL_SOCK" -u root -N -e "$Q" >/dev/null
    t1=$(date +%s%N)

    trigger_dump; wait_dumped

    local br1 bq1 ra1 pr1 dr1
    br1=$(get_status Innodb_buffer_pool_reads)
    bq1=$(get_status Innodb_buffer_pool_read_requests)
    ra1=$(get_status Innodb_buffer_pool_read_ahead)
    pr1=$(get_status Innodb_pages_read)
    dr1=$(get_status Innodb_data_reads)

    local ms=$(( (t1 - t0) / 1000000 ))
    local dreqs=$(( bq1 - bq0 ))
    local dreads=$(( br1 - br0 ))
    local dra=$(( ra1 - ra0 ))
    local dpr=$(( pr1 - pr0 ))
    local ddr=$(( dr1 - dr0 ))
    results+=("$ms")
    bp_reads_rounds+=("$dreads")
    bp_reqs_rounds+=("$dreqs")
    ra_rounds+=("$dra")
    pr_rounds+=("$dpr")
    dr_rounds+=("$ddr")
    printf "  round %d  %5d ms  BP_reqs=%-6d bp_reads=%-6d read_ahead=%-5d pages_read=%-5d data_reads=%-5d\n" \
      "$i" "$ms" "$dreqs" "$dreads" "$dra" "$dpr" "$ddr"
  done

  # 查询完的最后一次 sigusr1 快照 = 所有 rounds 的累计终点
  # 这个快照要在 stop_mysqld 之前抓，避免与 close 的 stats 混在一起
  sleep 0.2   # 再给后台 dumper 5ms*2 写完
  stop_mysqld
  sleep 0.2

  # 汇总时间
  local sum=0 count=0 min=999999 max=0
  for v in "${results[@]}"; do
    sum=$((sum + v)); count=$((count + 1))
    [[ $v -lt $min ]] && min=$v
    [[ $v -gt $max ]] && max=$v
  done
  local avg=$(( sum / count ))
  echo "  summary: min=${min}ms avg=${avg}ms max=${max}ms total=${sum}ms"

  # === 抽取 bench 窗口 delta（基于 sigusr1 快照） ===
  # 日志里的 sigusr1 行按时间顺序排列：
  #   第一行 ≈ 第 1 轮查询前 → metadata baseline
  #   最后一行 ≈ 第 N 轮查询后 → 包含 N 轮查询累计
  # delta = last - first = 所有 rounds 的真实 DSM 计数（排除启动 metadata）
  # stats/timing_ns 行 tag 分别为 window（touch 文件触发）或 close；取 window 算窗口 delta
  local first_stats last_stats first_timing last_timing
  first_stats=$( awk '/fil_read_cache.*\[stats\]/ && /tag=window/ {print; exit}' "$log")
  last_stats=$(  awk '/fil_read_cache.*\[stats\]/ && /tag=window/ {last=$0} END{print last}' "$log")
  first_timing=$(awk '/fil_read_cache.*\[stats\]/ && /tag=window/ {getline; print; exit}' "$log")
  last_timing=$(awk '/fil_read_cache.*\[stats\]/ && /tag=window/ {getline; last=$0} END{print last}' "$log")

  local close_stats close_timing
  close_stats=$(grep -E 'fil_read_cache.*\[stats\].*tag=close' "$log" | tail -n 1)
  close_timing=$(grep -E 'fil_read_cache.*timing_ns'           "$log" | tail -n 1)

  local first_mon_stats last_mon_stats first_mon_est last_mon_est close_mon_stats close_mon_est
  first_mon_stats=$( awk '/fil_cache_monitor.*\[stats\]/ && /tag=window/ {print; exit}' "$log")
  last_mon_stats=$(  awk '/fil_cache_monitor.*\[stats\]/ && /tag=window/ {last=$0} END{print last}' "$log")
  first_mon_est=$(  awk '/fil_cache_monitor.*\[stats\]/ && /tag=window/ {getline; print; exit}' "$log")
  last_mon_est=$(   awk '/fil_cache_monitor.*\[stats\]/ && /tag=window/ {getline; last=$0} END{print last}' "$log")
  close_mon_stats=$(grep -E 'fil_cache_monitor.*\[stats\].*tag=close' "$log" | tail -n 1)
  close_mon_est=$(  grep -E 'fil_cache_monitor.*\[estimate_ns\].*tag=close' "$log" | tail -n 1)

  echo "  [window first] ${first_stats}"
  echo "  [window last ] ${last_stats}"
  echo "  [close (含mysqld startup/shutdown)] ${close_stats}"
  [[ -n "$last_mon_stats" ]] && echo "  [monitor last ] ${last_mon_stats}"
  [[ -n "$close_mon_stats" ]] && echo "  [monitor close] ${close_mon_stats}"

  parse_ctr() { echo "$1" | sed -n "s/.*$2=\([0-9]*\).*/\1/p"; }
  local dsm_hit=0 dsm_miss=0 dsm_put=0 dsm_inv=0
  if [[ -n "$first_stats" && -n "$last_stats" ]]; then
    local gh0 gh1 gm0 gm1 pt0 pt1 iv0 iv1
    gh0=$(parse_ctr "$first_stats" get_hit);  gh1=$(parse_ctr "$last_stats" get_hit)
    gm0=$(parse_ctr "$first_stats" get_miss); gm1=$(parse_ctr "$last_stats" get_miss)
    pt0=$(parse_ctr "$first_stats" put);      pt1=$(parse_ctr "$last_stats" put)
    iv0=$(parse_ctr "$first_stats" invalidate); iv1=$(parse_ctr "$last_stats" invalidate)
    dsm_hit=$(( gh1 - gh0 ))
    dsm_miss=$(( gm1 - gm0 ))
    dsm_put=$(( pt1 - pt0 ))
    dsm_inv=$(( iv1 - iv0 ))
  else
    # fallback：没有 sigusr1 快照，退化为 close 全程
    local sl
    sl=$(grep -E "fil_read_cache.*\[stats\].*tag=close" "$log" | tail -n 1)
    dsm_hit=$(parse_ctr "$sl" get_hit)
    dsm_miss=$(parse_ctr "$sl" get_miss)
    dsm_put=$(parse_ctr "$sl" put)
    dsm_inv=$(parse_ctr "$sl" invalidate)
  fi
  dsm_hit=${dsm_hit:-0}; dsm_miss=${dsm_miss:-0}
  dsm_put=${dsm_put:-0}; dsm_inv=${dsm_inv:-0}

  local ns_get=0 ns_put=0 ns_inv=0 ns_doio=0 cnt_doio=0
  if [[ -n "$first_timing" && -n "$last_timing" ]]; then
    local g0 g1 p0 p1 i0 i1 d0 d1 c0 c1
    g0=$(parse_ctr "$first_timing" get);        g1=$(parse_ctr "$last_timing" get)
    # "put" 会被 "doio_read" 的 "put" 误匹配吗？不会，doio_read 里没有 put 子串
    p0=$(echo "$first_timing" | sed -n 's/.*[^o]put=\([0-9]*\).*/\1/p')
    p1=$(echo "$last_timing"  | sed -n 's/.*[^o]put=\([0-9]*\).*/\1/p')
    i0=$(parse_ctr "$first_timing" invalidate); i1=$(parse_ctr "$last_timing" invalidate)
    d0=$(parse_ctr "$first_timing" doio_read);  d1=$(parse_ctr "$last_timing" doio_read)
    c0=$(echo "$first_timing" | sed -n 's/.*doio_read=[0-9]*(n=\([0-9]*\)).*/\1/p')
    c1=$(echo "$last_timing"  | sed -n 's/.*doio_read=[0-9]*(n=\([0-9]*\)).*/\1/p')
    ns_get=$(( ${g1:-0} - ${g0:-0} ))
    ns_put=$(( ${p1:-0} - ${p0:-0} ))
    ns_inv=$(( ${i1:-0} - ${i0:-0} ))
    ns_doio=$(( ${d1:-0} - ${d0:-0} ))
    cnt_doio=$(( ${c1:-0} - ${c0:-0} ))
  fi

  local mon_buf_hit=0 mon_runtime_sync=0 mon_runtime_async=0 mon_disk_sync=0 mon_disk_async=0
  local mon_logical_total=0 mon_all_total=0 mon_est_logical_ns=0 mon_est_all_ns=0
  if [[ -n "$first_mon_stats" && -n "$last_mon_stats" ]]; then
    local mb0 mb1 mrs0 mrs1 mra0 mra1 mds0 mds1 mda0 mda1 mlt0 mlt1 mat0 mat1
    mb0=$(parse_ctr "$first_mon_stats" buf_hit);             mb1=$(parse_ctr "$last_mon_stats" buf_hit)
    mrs0=$(parse_ctr "$first_mon_stats" runtime_hit_sync);   mrs1=$(parse_ctr "$last_mon_stats" runtime_hit_sync)
    mra0=$(parse_ctr "$first_mon_stats" runtime_hit_async);  mra1=$(parse_ctr "$last_mon_stats" runtime_hit_async)
    mds0=$(parse_ctr "$first_mon_stats" disk_read_sync);     mds1=$(parse_ctr "$last_mon_stats" disk_read_sync)
    mda0=$(parse_ctr "$first_mon_stats" disk_read_async);    mda1=$(parse_ctr "$last_mon_stats" disk_read_async)
    mlt0=$(parse_ctr "$first_mon_stats" logical_total);      mlt1=$(parse_ctr "$last_mon_stats" logical_total)
    mat0=$(parse_ctr "$first_mon_stats" all_total);          mat1=$(parse_ctr "$last_mon_stats" all_total)
    mon_buf_hit=$(( ${mb1:-0} - ${mb0:-0} ))
    mon_runtime_sync=$(( ${mrs1:-0} - ${mrs0:-0} ))
    mon_runtime_async=$(( ${mra1:-0} - ${mra0:-0} ))
    mon_disk_sync=$(( ${mds1:-0} - ${mds0:-0} ))
    mon_disk_async=$(( ${mda1:-0} - ${mda0:-0} ))
    mon_logical_total=$(( ${mlt1:-0} - ${mlt0:-0} ))
    mon_all_total=$(( ${mat1:-0} - ${mat0:-0} ))
  elif [[ -n "$close_mon_stats" ]]; then
    mon_buf_hit=$(parse_ctr "$close_mon_stats" buf_hit)
    mon_runtime_sync=$(parse_ctr "$close_mon_stats" runtime_hit_sync)
    mon_runtime_async=$(parse_ctr "$close_mon_stats" runtime_hit_async)
    mon_disk_sync=$(parse_ctr "$close_mon_stats" disk_read_sync)
    mon_disk_async=$(parse_ctr "$close_mon_stats" disk_read_async)
    mon_logical_total=$(parse_ctr "$close_mon_stats" logical_total)
    mon_all_total=$(parse_ctr "$close_mon_stats" all_total)
  fi
  mon_buf_hit=${mon_buf_hit:-0}; mon_runtime_sync=${mon_runtime_sync:-0}
  mon_runtime_async=${mon_runtime_async:-0}; mon_disk_sync=${mon_disk_sync:-0}
  mon_disk_async=${mon_disk_async:-0}; mon_logical_total=${mon_logical_total:-0}
  mon_all_total=${mon_all_total:-0}

  if [[ -n "$first_mon_est" && -n "$last_mon_est" ]]; then
    local mel0 mel1 mea0 mea1
    mel0=$(parse_ctr "$first_mon_est" logical_total_ns); mel1=$(parse_ctr "$last_mon_est" logical_total_ns)
    mea0=$(parse_ctr "$first_mon_est" all_total_ns);     mea1=$(parse_ctr "$last_mon_est" all_total_ns)
    mon_est_logical_ns=$(( ${mel1:-0} - ${mel0:-0} ))
    mon_est_all_ns=$(( ${mea1:-0} - ${mea0:-0} ))
  elif [[ -n "$close_mon_est" ]]; then
    mon_est_logical_ns=$(parse_ctr "$close_mon_est" logical_total_ns)
    mon_est_all_ns=$(parse_ctr "$close_mon_est" all_total_ns)
  fi
  mon_est_logical_ns=${mon_est_logical_ns:-0}; mon_est_all_ns=${mon_est_all_ns:-0}
  # 汇总 delta 计数
  local total_bp_reads=0 total_bp_reqs=0 total_ra=0 total_pr=0 total_dr=0
  for v in "${bp_reads_rounds[@]}"; do total_bp_reads=$((total_bp_reads + v)); done
  for v in "${bp_reqs_rounds[@]}"; do total_bp_reqs=$((total_bp_reqs + v)); done
  for v in "${ra_rounds[@]}";       do total_ra=$((total_ra + v)); done
  for v in "${pr_rounds[@]}";       do total_pr=$((total_pr + v)); done
  for v in "${dr_rounds[@]}";       do total_dr=$((total_dr + v)); done

  # 走 fil_io 的入口 = sync miss + read_ahead
  local total_filio=$(( total_bp_reads + total_ra ))
  # 真正走磁盘 = fil_io - DSM 命中
  local actual_disk=$(( total_filio - dsm_hit ))
  [[ $actual_disk -lt 0 ]] && actual_disk=0

  # 交叉验证（与 DSM 无关）：代数上 expect_pr = dsm_hit + actual_disk
  #   = dsm_hit + (bp_reads+ra - dsm_hit) = bp_reads + read_ahead。
  # 故这里实际比较的是 Innodb_pages_read 与 (buffer_pool_reads+read_ahead)，
  # 不是「DSM 命中 + 磁盘」语义；echo 里旧标签易误解。
  # 两者在 InnoDB 里来自不同层计数，允许小偏差（预读批读、后台读、窗口边界等）。
  local expect_pr=$(( dsm_hit + actual_disk ))
  local diff_pr=$(( total_pr - expect_pr ))
  echo "  [cross-check] pages_read=${total_pr}  vs  bp_reads+read_ahead=${expect_pr}  diff=${diff_pr}"

  for e in "${envs[@]}"; do unset "${e%%=*}"; done
  unset FIL_READ_CACHE_TRACE

  eval "BENCH_${name}_min=$min"
  eval "BENCH_${name}_avg=$avg"
  eval "BENCH_${name}_max=$max"
  eval "BENCH_${name}_total=$sum"
  eval "BENCH_${name}_rounds='${results[*]}'"
  eval "BENCH_${name}_bp_reqs=$total_bp_reqs"
  eval "BENCH_${name}_bp_reads=$total_bp_reads"
  eval "BENCH_${name}_ra=$total_ra"
  eval "BENCH_${name}_pr=$total_pr"
  eval "BENCH_${name}_dr=$total_dr"
  eval "BENCH_${name}_filio=$total_filio"
  eval "BENCH_${name}_dsm_hit=$dsm_hit"
  eval "BENCH_${name}_dsm_miss=$dsm_miss"
  eval "BENCH_${name}_dsm_put=$dsm_put"
  eval "BENCH_${name}_dsm_inv=$dsm_inv"
  eval "BENCH_${name}_actual_disk=$actual_disk"
  eval "BENCH_${name}_diff_pr=$diff_pr"
  eval "BENCH_${name}_ns_get=${ns_get:-0}"
  eval "BENCH_${name}_ns_put=${ns_put:-0}"
  eval "BENCH_${name}_ns_inv=${ns_inv:-0}"
  eval "BENCH_${name}_ns_doio=${ns_doio:-0}"
  eval "BENCH_${name}_cnt_doio=${cnt_doio:-0}"
  eval "BENCH_${name}_mon_buf_hit=${mon_buf_hit:-0}"
  eval "BENCH_${name}_mon_runtime_sync=${mon_runtime_sync:-0}"
  eval "BENCH_${name}_mon_runtime_async=${mon_runtime_async:-0}"
  eval "BENCH_${name}_mon_disk_sync=${mon_disk_sync:-0}"
  eval "BENCH_${name}_mon_disk_async=${mon_disk_async:-0}"
  eval "BENCH_${name}_mon_logical_total=${mon_logical_total:-0}"
  eval "BENCH_${name}_mon_all_total=${mon_all_total:-0}"
  eval "BENCH_${name}_mon_est_logical_ns=${mon_est_logical_ns:-0}"
  eval "BENCH_${name}_mon_est_all_ns=${mon_est_all_ns:-0}"
}

# ---------------------------------------------------------------------------
# 4) 按需跑 A / B
# ---------------------------------------------------------------------------
if [[ -z "$ONLY" || "$ONLY" == "no" ]]; then
  run_bench "NO_CACHE" "${LOG_DIR}/mysqld_no_cache.log" \
            FIL_READ_CACHE_ENABLE=0
fi

if [[ -z "$ONLY" || "$ONLY" == "dsm" ]]; then
  run_bench "DSM" "${LOG_DIR}/mysqld_dsm.log" \
            FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=1
fi

# ---------------------------------------------------------------------------
# 5) 最终汇总
# ---------------------------------------------------------------------------
say "=============== SUMMARY ==============="
echo "--- 1. 页来源统计（fil_cache_monitor，按查询窗口累计） ---"
printf "  %-10s %10s %10s %10s %10s %10s %10s %10s
"   mode Buf DSM_sync Disk_sync DSM_async Disk_async logical all
dump_monitor_row() {
  local n=$1
  local buf_var="BENCH_${n}_mon_buf_hit"
  local rs_var="BENCH_${n}_mon_runtime_sync"
  local ds_var="BENCH_${n}_mon_disk_sync"
  local ra_var="BENCH_${n}_mon_runtime_async"
  local da_var="BENCH_${n}_mon_disk_async"
  local logical_var="BENCH_${n}_mon_logical_total"
  local all_var="BENCH_${n}_mon_all_total"
  local v="${!buf_var-}"
  [[ -z "$v" ]] && return
  printf "  %-10s %10s %10s %10s %10s %10s %10s %10s
"     "$n"     "${!buf_var}"     "${!rs_var}"     "${!ds_var}"     "${!ra_var}"     "${!da_var}"     "${!logical_var}"     "${!all_var}"
}
dump_monitor_row NO_CACHE
dump_monitor_row DSM

echo ""
echo "--- 2. 估算 I/O 耗时（按 FIL_CACHE_MONITOR_COST_* 重算，单位 ns） ---"
printf "  %-10s %16s %16s
" mode logical_total_ns all_total_ns
dump_monitor_est() {
  local n=$1
  local logical_var="BENCH_${n}_mon_est_logical_ns"
  local all_var="BENCH_${n}_mon_est_all_ns"
  local v="${!logical_var-}"
  [[ -z "$v" ]] && return
  printf "  %-10s %16s %16s
"     "$n"     "${!logical_var}"     "${!all_var}"
}
dump_monitor_est NO_CACHE
dump_monitor_est DSM

echo ""
echo "  列说明:"
echo "    Buf        = 直接命中 buffer pool 的逻辑页请求"
echo "    DSM_sync   = 前台同步缺页最终由 DSM 满足"
echo "    Disk_sync  = 前台同步缺页最终走磁盘"
echo "    DSM_async  = 后台/预读路径由 DSM 满足"
echo "    Disk_async = 后台/预读路径走磁盘"
echo "    logical    = Buf + DSM_sync + Disk_sync    (忽略并发/重叠时，用它估前台时间)"
echo "    all        = logical + DSM_async + Disk_async"
echo ""
echo "--- 3. 读取路径的命中/走盘计数（按整轮累计） ---"
printf "  %-10s %6s %6s %6s %8s %10s %9s %9s %9s %9s %9s %8s
"   mode min avg max total BP_reqs BP_reads RA pages_r DSM_hit DISK check
dump_row() {
  local n=$1
  local min_var="BENCH_${n}_min"
  local avg_var="BENCH_${n}_avg"
  local max_var="BENCH_${n}_max"
  local total_var="BENCH_${n}_total"
  local bp_reqs_var="BENCH_${n}_bp_reqs"
  local bp_reads_var="BENCH_${n}_bp_reads"
  local ra_var="BENCH_${n}_ra"
  local pr_var="BENCH_${n}_pr"
  local dsm_hit_var="BENCH_${n}_dsm_hit"
  local disk_var="BENCH_${n}_actual_disk"
  local check_var="BENCH_${n}_diff_pr"
  local v="${!min_var-}"
  [[ -z "$v" ]] && return
  printf "  %-10s %6s %6s %6s %8s %10s %9s %9s %9s %9s %9s %8s\n"     "$n"     "${!min_var}"     "${!avg_var}"     "${!max_var}"     "${!total_var}"     "${!bp_reqs_var}"     "${!bp_reads_var}"     "${!ra_var}"     "${!pr_var}"     "${!dsm_hit_var}"     "${!disk_var}"     "${!check_var}"
}
dump_row NO_CACHE
dump_row DSM

echo ""
echo "  列说明:"
echo "    BP_reqs = Innodb_buffer_pool_read_requests delta  (InnoDB BP 查询页面的次数)"
echo "    BP_reads = Innodb_buffer_pool_reads delta        (8.4 status 变量本体；本 workload 下近似前台 miss)"
echo "    RA      = Innodb_buffer_pool_read_ahead delta     (后台预取 async read)"
echo "    pages_r = Innodb_pages_read delta                 (实际进入 BP 的新页数=sync+RA)"
echo "    DSM_hit = fil_read_cache::get 命中次数             (被 DSM 拦下的页)"
echo "    DISK    = BP_sync + RA - DSM_hit                   (真正走磁盘/ibd)"
echo "    check   = pages_r - (BP_sync+RA)     理论≈0       (pages_read vs buffer_pool_reads+read_ahead)"
echo ""
echo "--- 4. 时间 breakdown（纳秒累计，多线程叠加）---"
printf "  %-10s %14s %14s %14s %14s %14s\n" \
  mode ns_doio_read ns_dsm_get ns_dsm_put ns_dsm_inv total_io_ns
dump_ns() {
  local n=$1
  local doio_var="BENCH_${n}_ns_doio"
  local get_var="BENCH_${n}_ns_get"
  local put_var="BENCH_${n}_ns_put"
  local inv_var="BENCH_${n}_ns_inv"
  local v="${!get_var-}"
  [[ -z "$v" ]] && return
  local total=$(( ${!doio_var:-0} + ${!get_var:-0} + ${!put_var:-0} + ${!inv_var:-0} ))
  printf "  %-10s %14s %14s %14s %14s %14s\n"     "$n"     "${!doio_var}"     "${!get_var}"     "${!put_var}"     "${!inv_var}"     "$total"
}
dump_ns NO_CACHE
dump_ns DSM
echo ""
echo "  这些是 mysqld 全进程、全 $ROUNDS 轮累加的 ns。每一次 fil_io/do_io/DSM 操作"
echo "  都用 steady_clock 测了一次；多线程同时跑时会叠加，所以 total_io_ns 可能"
echo "  超过 wall-clock。用来比较\"DSM 引入的额外开销\"和\"节省的 do_io 时间\"。"

if [[ -n "${BENCH_NO_CACHE_avg:-}" && -n "${BENCH_DSM_avg:-}" ]]; then
  # 避免 avg=0 的除零
  if [[ ${BENCH_DSM_avg} -gt 0 ]]; then
    speedup=$(awk "BEGIN{ printf \"%.2f\", ${BENCH_NO_CACHE_avg}/${BENCH_DSM_avg} }")
    say "avg speedup (NO_CACHE / DSM) = ${speedup}x"
  fi
fi

say "logs: ${LOG_DIR}/"
