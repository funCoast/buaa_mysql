#!/usr/bin/env bash
# ============================================================================
# MySQL + DSM Runtime 端到端测试
#
# 前置条件：
#   - /workspace/ub2_simulator/dsm_runtime/build 里已构建
#     simulator / export_client / libdsm_runtime_lib.a
#   - /workspace/mysql_install 里已完成 make install（且 data 已 --initialize）
#
# 本脚本会：
#   1) 后台启动 simulator（mpirun -np 4 ./simulator）
#   2) 跑一次 export_client 让 simulator 留下
#      /dev/shm/virtual_node0/obmm_shmdev{1,2,3} 这三个共享内存文件
#   3) 启动 mysqld（其内部 fil_read_cache 会自动 mmap 上述 shm 作为 L2 缓存）
#   4) 通过 mysql 客户端执行缓存命中用例
#   5) 收敛清理所有进程
#
# 用法：
#   ./e2e_test.sh                # 只跑冷/热命中小用例（秒级）
#   ./e2e_test.sh --big          # 附加大表场景（会往 data 写 ~2GB）
# ============================================================================

set -euo pipefail

ROOT_DIR=/workspace
SIM_DIR=${ROOT_DIR}/ub2_simulator
SIM_BUILD=${SIM_DIR}/dsm_runtime/build
MYSQL_INSTALL=${ROOT_DIR}/mysql_install
MYSQL_DATA=${MYSQL_INSTALL}/data
MYSQL_SOCK=/tmp/mysql-dsm.sock
MYSQL_PORT=3308
LOG_DIR=/tmp/dsm_e2e_logs
mkdir -p "${LOG_DIR}"

SIM_LOG=${LOG_DIR}/simulator.log
EXPORT_LOG=${LOG_DIR}/export_client.log
MYSQLD_LOG=${LOG_DIR}/mysqld.log

WANT_BIG=0
for arg in "$@"; do
  case "$arg" in
    --big) WANT_BIG=1 ;;
    *) echo "unknown arg: $arg"; exit 2 ;;
  esac
done

say() { printf "\n\033[1;36m[E2E]\033[0m %s\n" "$*"; }

cleanup() {
  say "cleaning up..."
  if [[ -n "${MYSQLD_PID:-}" ]] && kill -0 "${MYSQLD_PID}" 2>/dev/null; then
    "${MYSQL_INSTALL}/bin/mysqladmin" -S "${MYSQL_SOCK}" -u root shutdown \
      2>/dev/null || kill "${MYSQLD_PID}" 2>/dev/null || true
    wait "${MYSQLD_PID}" 2>/dev/null || true
  fi
  if [[ -n "${SIM_PID:-}" ]] && kill -0 "${SIM_PID}" 2>/dev/null; then
    # simulator 通常已被 obmm_simulator_finish() 优雅关闭
    kill "${SIM_PID}" 2>/dev/null || true
    wait "${SIM_PID}" 2>/dev/null || true
  fi
  rm -f /tmp/obmm_simulator_node*.sock 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1) 启动 simulator
# ---------------------------------------------------------------------------
say "1) starting simulator (log: ${SIM_LOG})"
. "${SIM_DIR}/sim_env.sh"
( cd "${SIM_BUILD}" && mpirun -np 4 ./simulator ) >"${SIM_LOG}" 2>&1 &
SIM_PID=$!

# 等待 simulator 上来（出现 node socket）
for i in $(seq 1 50); do
  if [[ -S /tmp/obmm_simulator_node0.sock ]]; then
    break
  fi
  sleep 0.2
done
if [[ ! -S /tmp/obmm_simulator_node0.sock ]]; then
  echo "simulator did not start in time"; tail -n 40 "${SIM_LOG}"; exit 3
fi
say "simulator is up (pid=${SIM_PID})"

# ---------------------------------------------------------------------------
# 2) 跑 export_client：在 node 1/2/3 上 export 内存，node 0 做 import，落下
#    /dev/shm/virtual_node0/obmm_shmdev{1,2,3}
# ---------------------------------------------------------------------------
say "2) running export_client (log: ${EXPORT_LOG})"
( cd "${SIM_BUILD}" && mpirun -np 4 ./export_client ) >"${EXPORT_LOG}" 2>&1

# 校验 shm 文件
for m in 1 2 3; do
  if [[ ! -e "/dev/shm/virtual_node0/obmm_shmdev${m}" ]]; then
    echo "missing /dev/shm/virtual_node0/obmm_shmdev${m}; export_client failed"
    tail -n 40 "${EXPORT_LOG}"
    exit 4
  fi
done
say "shm files ready: $(ls /dev/shm/virtual_node0/ | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# 3) 启动 mysqld
# ---------------------------------------------------------------------------
say "3) starting mysqld (log: ${MYSQLD_LOG})"
# 用小 buffer pool 方便后续把 small_test 从 bp 挤出
"${MYSQL_INSTALL}/bin/mysqld" \
  --datadir="${MYSQL_DATA}" \
  --socket="${MYSQL_SOCK}" \
  --port="${MYSQL_PORT}" \
  --pid-file=/tmp/mysql-dsm.pid \
  --innodb-buffer-pool-size=256M \
  --log-error-verbosity=2 \
  --user="$(whoami)" \
  >"${MYSQLD_LOG}" 2>&1 &
MYSQLD_PID=$!

# 等 mysqld ready
for i in $(seq 1 80); do
  if "${MYSQL_INSTALL}/bin/mysqladmin" -S "${MYSQL_SOCK}" -u root ping \
       >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! "${MYSQL_INSTALL}/bin/mysqladmin" -S "${MYSQL_SOCK}" -u root ping \
      >/dev/null 2>&1; then
  echo "mysqld did not come up"; tail -n 80 "${MYSQLD_LOG}"; exit 5
fi
say "mysqld is ready (pid=${MYSQLD_PID})"

MYSQL="${MYSQL_INSTALL}/bin/mysql -S ${MYSQL_SOCK} -u root"

# ---------------------------------------------------------------------------
# 4) 小用例：冷读 miss→put；热读 BP 命中（缓存无感知）；
#    大表扫描挤掉 bp；再读 small_test 应该 bp miss + DSM cache 命中
# ---------------------------------------------------------------------------
say "4a) creating testdb / small_test / big_table"
$MYSQL <<'SQL'
CREATE DATABASE IF NOT EXISTS testdb;
USE testdb;
DROP TABLE IF EXISTS small_test;
DROP TABLE IF EXISTS big_table;
CREATE TABLE small_test (id INT PRIMARY KEY, val VARCHAR(100)) ENGINE=InnoDB;
INSERT INTO small_test VALUES (1, 'hello');

CREATE TABLE big_table (
  id INT AUTO_INCREMENT PRIMARY KEY,
  data VARCHAR(4000),
  padding VARCHAR(4000)
) ENGINE=InnoDB;
INSERT INTO big_table (data, padding)
  VALUES (REPEAT('A', 4000), REPEAT('B', 4000));
SQL

say "4b) first SELECT small_test (冷启动：BP miss → fil_io read → cache miss → put)"
$MYSQL -e "USE testdb; SELECT * FROM small_test WHERE id=1;"

# 把 big_table 倍增到约 2GB（--big 时执行完整 18 轮；默认只做 14 轮约 128MB）
say "4c) doubling big_table to fill buffer pool"
ROUNDS=14
if [[ "${WANT_BIG}" -eq 1 ]]; then ROUNDS=18; fi
for i in $(seq 1 ${ROUNDS}); do
  $MYSQL -e "USE testdb; INSERT INTO big_table (data, padding) \
             SELECT data, padding FROM big_table;" >/dev/null
done
$MYSQL -e "USE testdb; SELECT COUNT(*) AS big_rows FROM big_table;"

say "4d) full-scan big_table (evicts small_test pages out of BP)"
$MYSQL -e "USE testdb; SELECT COUNT(*) FROM big_table WHERE data LIKE '%A%';"

say "4e) SELECT small_test again (期待 BP miss 但 DSM cache 命中)"
$MYSQL -e "USE testdb; SELECT * FROM small_test WHERE id=1;"

# ---------------------------------------------------------------------------
# 5) 打印 DSM 相关 trace（fil_read_cache / dsm_bridge 的 stdout）
# ---------------------------------------------------------------------------
say "5) DSM traces from mysqld:"
grep -E "fil_read_cache|dsm_bridge|Actor Node|\[Runtime\]" "${MYSQLD_LOG}" \
  | tail -n 50 || true

say "E2E test done. Full logs in ${LOG_DIR}"
