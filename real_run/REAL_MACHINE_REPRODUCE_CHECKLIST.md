# 真机复现实验检查清单

这份清单用于在我无法继续访问远端机器时复现论文实验。默认目标是跑出真机 `wall_time_ns`，同时保留 monitor 页来源字段用于解释 `disk_sync -> runtime_sync`。

## 1. 部署代码

推荐把部署包解压到固定路径：

```bash
mkdir -p /workspace/ltCopyWorkspace
cd /workspace/ltCopyWorkspace
unzip /path/to/mysql_code_real_deploy_v1.zip

# 若解压后多一层目录：
mv mysql_code_real_deploy_v1/copy_wyq_mysql .
mv mysql_code_real_deploy_v1/real_run .

export PROJECT_ROOT=/workspace/ltCopyWorkspace/copy_wyq_mysql
```

如果路径不同，后续所有命令都显式设置 `PROJECT_ROOT=/your/path/copy_wyq_mysql`。

## 2. 容量要求

如果仍使用当前 `/dev/shm` 模拟器：

```bash
docker run --shm-size=16g ...
```

实验默认：

```bash
DSM_CACHE_BYTES_PER_NODE=4294967296
FIL_READ_CACHE_MAX_PAGES=1048576
MYSQL_BP_SIZE=5M
```

原因：TPC-H isolated 会先 warmup 当前查询，再正式测量；Q1/Q3 这类查询会填入大量 clean page。512MB/节点在模拟器阶段已经触发过 `[Actor Node X] No available memory`，不能作为论文最终 TPC-H 配置。

如果使用真实 DSM 后端，不一定需要 Docker `--shm-size`，但需要保证每个远端节点实际可用 cache 容量不低于 `DSM_CACHE_BYTES_PER_NODE`。

## 3. 编译

DSM runtime：

```bash
cd $PROJECT_ROOT/ub2_simulator/dsm_runtime
mkdir -p build
cd build
cmake ..
make -j"$(nproc)"
```

MySQL：

```bash
cd $PROJECT_ROOT/mysql-server-8.4
mkdir -p build
cd build

cmake .. \
  -DCMAKE_BUILD_TYPE=Debug \
  -DWITH_DEBUG=1 \
  -DADD_GDB_INDEX=ON \
  -DCMAKE_INSTALL_PREFIX="$PROJECT_ROOT/mysql_install_verify" \
  -DWITH_SSL=system \
  -DENABLE_DOWNLOADS=1 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

make -j"$(nproc)"
make install
```

检查：

```bash
test -x $PROJECT_ROOT/mysql_install_verify/bin/mysqld
test -x $PROJECT_ROOT/run_monitor_workloads_compare.sh
test -x $PROJECT_ROOT/run_tpch_query_windows_isolated.sh
test -x $PROJECT_ROOT/run_tpch_query_windows_reuse.sh
```

## 4. 准备数据

TPC-H SF1：

```bash
cd $PROJECT_ROOT/workloads/tpch-kit/dbgen
make
mkdir -p $PROJECT_ROOT/workloads/tpch_data/sf1
cd $PROJECT_ROOT/workloads/tpch_data/sf1
$PROJECT_ROOT/workloads/tpch-kit/dbgen/dbgen -s 1 -f
ls *.tbl
```

TPC-C：

```bash
cd $PROJECT_ROOT/workloads/tpcc-mysql
make clean || true
make
```

TPC-C 数据由实验脚本创建隔离 datadir 并装载，通常不需要手动提前装载。

## 5. 推荐一键实验

```bash
cd /workspace/ltCopyWorkspace/real_run
chmod +x *.sh *.py

PROJECT_ROOT=/workspace/ltCopyWorkspace/copy_wyq_mysql \
REAL_REPEATS=3 \
MYSQL_BP_SIZE=5M \
DSM_CACHE_BYTES_PER_NODE=4294967296 \
FIL_READ_CACHE_MAX_PAGES=1048576 \
REAL_RANDOM_PAGES_LIST="6000 12000" \
REAL_SCAN_PAGES_LIST="6000" \
REAL_RANDOM_UPDATE_PAGES_LIST="1500" \
REAL_TPCC_W=4 \
REAL_TPCC_CONNS_LIST="1 2 4 8" \
REAL_TPCC_DURATION=180 \
REAL_TPCH_ISOLATED=1 \
REAL_TPCH_QIDS="1 3 6 12 14 19" \
./run_real_machine_perf.sh
```

如果只跑 TPC-H：

```bash
PROJECT_ROOT=/workspace/ltCopyWorkspace/copy_wyq_mysql \
REAL_RUN_MICRO_RANDOM=0 \
REAL_RUN_MICRO_SCAN=0 \
REAL_RUN_MICRO_RANDOM_UPDATE=0 \
REAL_RUN_TPCC=0 \
REAL_RUN_TPCH=1 \
REAL_REPEATS=3 \
DSM_CACHE_BYTES_PER_NODE=4294967296 \
FIL_READ_CACHE_MAX_PAGES=1048576 \
REAL_TPCH_ISOLATED=1 \
REAL_TPCH_QIDS="1 3 6 12 14 19" \
./run_real_machine_perf.sh
```

## 6. TPC-H isolated 的口径

`REAL_TPCH_ISOLATED=1` 时：

- 每个 `qid/mode/repeat` 单独启动 MySQL。
- 每次只 warmup 当前 query。
- 正式 query 前后触发 monitor window。
- `run_tpch_query_windows_reuse.sh` 输出 `wall_time_ns`，不是只输出整秒。
- `real_all.tsv` 中 workload 会是 `TPCH_Q1`、`TPCH_Q3` 等，便于逐查询画图。

模拟器阶段已经确认：Q1/Q6/Q14/Q19 的 `disk_async/runtime_async=57759` 是稳定 read-ahead 页足迹，不是 monitor 固定值。Q3/Q12 分别是其他数值，可以用于说明该字段随查询路径变化。

## 7. 输出文件

实验输出目录：

```bash
$PROJECT_ROOT/runs/real_machine_perf_YYYYMMDD_HHMMSS
```

关键文件：

```bash
config.txt
real_all.tsv
real_medians.tsv
real_speedup.tsv
figures/
```

论文优先使用：

- `real_speedup.tsv` 的 `no_dsm_wall_s`、`dsm_wall_s`、`wall_speedup`
- `real_speedup.tsv` 的 `no_dsm_disk_sync`、`dsm_runtime_sync`、`dsm_disk_sync`
- TPC-C 日志中的 TpmC/吞吐

`logical_wall_ns` 只用于解释页来源替代，不替代真机 `wall_time_ns`。

## 8. 画图

```bash
cd /workspace/ltCopyWorkspace/real_run
./plot_real_machine_results.py $PROJECT_ROOT/runs/real_machine_perf_YYYYMMDD_HHMMSS
```

生成：

```bash
real_overview_speedup.png
real_micro_random_lookup.png
real_micro_random_update.png
real_tpcc_concurrency.png
real_tpch_summary.png
real_dsm_residual_disk_by_experiment.png
```

## 9. 异常处理

如果看到 `[Actor Node X] No available memory`：

- 增大 `DSM_CACHE_BYTES_PER_NODE`。
- 增大 Docker `/dev/shm`。
- 确认 `FIL_READ_CACHE_MAX_PAGES` 不小于 DSM 可容纳页数。
- TPC-H isolated 不建议低于 4GB/节点。

如果 `runtime_sync/runtime_async` 一直是 0：

- 检查 DSM runtime 是否启动成功。
- 检查 `export_client` 是否成功导出共享内存。
- 检查 DSM 组 mysqld 日志是否有 `DSM backend ACTIVE`。
- 检查是否设置了 `FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=1`。

如果真机 `wall_speedup` 和 `logical_speedup` 不一致：

- 论文优先报告真实 `wall_time_ns`。
- 用 monitor 字段解释差异：真实 DSM 延迟、网络/总线带宽、并发竞争、日志/锁开销等都会影响端到端时间。
