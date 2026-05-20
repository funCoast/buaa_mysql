#!/usr/bin/env bash
# ============================================================================
# DSM + MySQL 端到端测试遗留进程清理脚本
#
# 清理对象（按优雅→暴力顺序尝试）：
#   1) mysql / mysqladmin 客户端
#   2) mysqld                  → 先 mysqladmin shutdown，再 SIGTERM / SIGKILL
#   3) mpirun + simulator      → 先 obmm_simulator_finish（用 socket），
#                                不行再 SIGTERM → SIGKILL
#   4) 残留的 socket 文件 /tmp/obmm_simulator_node*.sock
#   5) 残留的 /dev/shm/virtual_node*/obmm_shmdev*（可选 --purge-shm）
#
# 用法：
#   ./cleanup.sh                  # 正常清理
#   ./cleanup.sh --force          # 跳过优雅关闭，直接 SIGKILL
#   ./cleanup.sh --purge-shm      # 额外清理 /dev/shm/virtual_node* 里的 shm
#   ./cleanup.sh --dry-run        # 只打印将要做的事，不真正杀进程
#   ./cleanup.sh --all            # = --force --purge-shm
# ============================================================================

set -u

FORCE=0
PURGE_SHM=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --force)     FORCE=1 ;;
    --purge-shm) PURGE_SHM=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --all)       FORCE=1; PURGE_SHM=1 ;;
    -h|--help)
      sed -n '2,22p' "$0"; exit 0 ;;
    *)
      echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

MYSQL_INSTALL=${MYSQL_INSTALL:-/workspace/ltCopyWorkspace/mysql_install}
MYSQL_SOCK=${MYSQL_SOCK:-/tmp/mysql-bench.sock}

# 我们进程叫什么（只匹配这些，别误伤别人的 mysql）
PATTERNS=(
  "mpirun -np.* \./simulator"
  "mpirun -np.* \./export_client"
  "\./simulator( |$)"
  "\./export_client( |$)"
  "\./example_after_export"
  "\./concurrent_index_test"
  "${MYSQL_INSTALL}/bin/mysqld"
  "mysqld_safe"
  "${MYSQL_INSTALL}/bin/mysql( |$)"
  "${MYSQL_INSTALL}/bin/mysqladmin"
)

say()  { printf "\033[1;36m[cleanup]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[cleanup]\033[0m %s\n" "$*" >&2; }

# 列出匹配某正则的 PID（按父→子顺序，方便先杀 mpirun 再杀 simulator 子）
pids_for() {
  local re="$1"
  # -f 对 full cmdline 做匹配；排除当前 shell / cleanup 自己
  pgrep -f -- "$re" 2>/dev/null \
    | grep -v -x "$$" \
    | grep -v -x "$PPID" \
    || true
}

kill_group() {
  local signal="$1"; shift
  local pids=("$@")
  [[ ${#pids[@]} -eq 0 ]] && return
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "[dry-run] kill -${signal} ${pids[*]}"
    return
  fi
  kill -"${signal}" "${pids[@]}" 2>/dev/null || true
}

wait_gone() {
  local pid="$1" timeout_ms="${2:-3000}"
  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge "$timeout_ms" ]]; then
      return 1
    fi
    sleep 0.1
    elapsed=$((elapsed + 100))
  done
  return 0
}

# ---------------------------------------------------------------------------
# 1) 优雅关闭 mysqld（--force 时跳过）
# ---------------------------------------------------------------------------
if [[ "$FORCE" -eq 0 ]]; then
  if [[ -S "$MYSQL_SOCK" ]] && [[ -x "${MYSQL_INSTALL}/bin/mysqladmin" ]]; then
    say "graceful: mysqladmin shutdown via ${MYSQL_SOCK}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] ${MYSQL_INSTALL}/bin/mysqladmin -S ${MYSQL_SOCK} -u root shutdown"
    else
      "${MYSQL_INSTALL}/bin/mysqladmin" -S "$MYSQL_SOCK" -u root shutdown \
        2>/dev/null || warn "mysqladmin shutdown failed (will fall back to kill)"
    fi
  fi

  # 也优雅停止 simulator（通过 obmm client finish 协议：直接 rm socket 不够，
  # 这里稳妥起见跳过，直接进入 SIGTERM 阶段即可，simulator 会被 mpirun 传递信号）
fi

# ---------------------------------------------------------------------------
# 2) 汇总所有需要杀掉的 pid
# ---------------------------------------------------------------------------
declare -A SEEN=()
ALL_PIDS=()
for re in "${PATTERNS[@]}"; do
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    if [[ -z "${SEEN[$pid]:-}" ]]; then
      SEEN[$pid]=1
      ALL_PIDS+=("$pid")
    fi
  done < <(pids_for "$re")
done

if [[ ${#ALL_PIDS[@]} -eq 0 ]]; then
  say "no leftover processes matched."
else
  say "found ${#ALL_PIDS[@]} leftover pid(s):"
  # 打印人类可读的进程信息
  ps -o pid=,cmd= -p "${ALL_PIDS[@]}" 2>/dev/null | sed 's/^/  /'
fi

# ---------------------------------------------------------------------------
# 3) SIGTERM → 等待 → SIGKILL
# ---------------------------------------------------------------------------
if [[ ${#ALL_PIDS[@]} -gt 0 ]]; then
  if [[ "$FORCE" -eq 0 ]]; then
    say "sending SIGTERM..."
    kill_group TERM "${ALL_PIDS[@]}"
    # 最多等 3s（dry-run 下跳过等待）
    if [[ "$DRY_RUN" -eq 0 ]]; then
      for pid in "${ALL_PIDS[@]}"; do
        wait_gone "$pid" 3000 || true
      done
    fi
  fi

  # 检查谁还活着（dry-run 下视作“全部还活着”以演示 SIGKILL 分支）
  REMAIN=()
  if [[ "$DRY_RUN" -eq 1 ]]; then
    REMAIN=("${ALL_PIDS[@]}")
  else
    for pid in "${ALL_PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        REMAIN+=("$pid")
      fi
    done
  fi
  if [[ ${#REMAIN[@]} -gt 0 ]]; then
    say "SIGKILL ${#REMAIN[@]} remaining: ${REMAIN[*]}"
    kill_group KILL "${REMAIN[@]}"
  fi
fi

# ---------------------------------------------------------------------------
# 4) 清理残留 socket / pid 文件
# ---------------------------------------------------------------------------
say "removing leftover sockets / pid files..."
LEFTOVERS=(
  /tmp/obmm_simulator_node*.sock
  /tmp/mysql-dsm.sock
  /tmp/mysql-dsm.sock.lock
  /tmp/mysql-dsm.pid
  /tmp/mysql-debug.sock
  /tmp/mysql-debug.sock.lock
  /tmp/mysql-bench.sock
  /tmp/mysql-bench.pid
  /tmp/mysqlx.sock
  /tmp/mysqlx.sock.lock
  /tmp/mysqlx-bench.sock
  /tmp/mysqlx-bench.sock.lock
)
for f in "${LEFTOVERS[@]}"; do
  for real in $f; do
    [[ -e "$real" || -L "$real" ]] || continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] rm -f $real"
    else
      rm -f "$real" 2>/dev/null || true
    fi
  done
done

# ---------------------------------------------------------------------------
# 5) 可选：清理 /dev/shm/virtual_node* 下的 OBMM 共享内存
# ---------------------------------------------------------------------------
if [[ "$PURGE_SHM" -eq 1 ]]; then
  say "purging /dev/shm/virtual_node*/obmm_shmdev*"
  for d in /dev/shm/virtual_node*; do
    [[ -d "$d" ]] || continue
    if [[ "$DRY_RUN" -eq 1 ]]; then
      say "[dry-run] rm -rf $d"
    else
      rm -rf "$d" 2>/dev/null || true
    fi
  done
fi

# ---------------------------------------------------------------------------
# 6) 汇报最终状态
# ---------------------------------------------------------------------------
say "final state:"
REMAIN_AFTER=()
for re in "${PATTERNS[@]}"; do
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && REMAIN_AFTER+=("$pid")
  done < <(pids_for "$re")
done
if [[ ${#REMAIN_AFTER[@]} -eq 0 ]]; then
  printf "  \033[1;32mOK\033[0m all target processes cleared.\n"
else
  warn "still alive: ${REMAIN_AFTER[*]}"
  ps -o pid=,cmd= -p "${REMAIN_AFTER[@]}" 2>/dev/null | sed 's/^/  /'
  exit 1
fi
