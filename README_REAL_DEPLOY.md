# MySQL + DSM Cache 真机部署代码包说明

本包用于把当前 `copy_wyq_mysql` 的实现迁移到另一台机器或真实超节点环境中重新编译、装载数据并运行性能对比实验。

## 1. 包内容

目录结构：

```bash
mysql_code_real_deploy_v1/
├── copy_wyq_mysql/
│   ├── mysql-server-8.4/              # MySQL 8.4 修改源码
│   ├── ub2_simulator/                 # 共享内存模拟器 / DSM runtime 源码
│   ├── workloads/                     # workload 脚本、TPC-H/TPC-C 工具源码
│   ├── run_monitor_workloads_compare.sh
│   ├── run_tpch_query_windows_reuse.sh
│   ├── run_tpch_query_windows_isolated.sh
│   ├── run_paper_experiments.sh
│   └── ...
├── real_run/                          # 真机阶段专用运行与画图脚本
└── README_REAL_DEPLOY.md
```

本包刻意不包含以下内容：

- MySQL 编译产物：`mysql_install*`、`build/`
- 实验输出：`runs/`
- TPC-H/TPC-C 已生成数据
- TPC-H `.tbl` 文件
- MySQL datadir，例如 `.ibd`、`.MYD`、`.MYI`
- Git 元数据 `.git`
- MySQL 自带 `mysql-test/` 测试数据

换句话说，这个包是“源码 + 脚本 + workload 工具”的部署包，不是完整实验结果包。

## 2. 解压与路径约定

建议在真机上解压到：

```bash
/workspace/ltCopyWorkspace/copy_wyq_mysql
```

如果路径不同，需要在后续脚本中显式设置 `PROJECT_ROOT`。

示例：

```bash
mkdir -p /workspace/ltCopyWorkspace
cd /workspace/ltCopyWorkspace
unzip /path/to/mysql_code_real_deploy_v1.zip

# 如果解压后多了一层 mysql_code_real_deploy_v1，可移动：
mv mysql_code_real_deploy_v1/copy_wyq_mysql .
mv mysql_code_real_deploy_v1/real_run .
```

也可以保留原目录层级，只要运行时设置：

```bash
export PROJECT_ROOT=/path/to/mysql_code_real_deploy_v1/copy_wyq_mysql
```

## 3. 编译 DSM runtime

如果真机仍使用当前 `ub2_simulator/dsm_runtime` 这套接口：

```bash
cd $PROJECT_ROOT/ub2_simulator/dsm_runtime
mkdir -p build
cd build
cmake ..
make -j"$(nproc)"
```

如果真机已经换成真实 DSM/OBMM 后端，需要保证 MySQL 侧 `dsm_bridge` 调用的接口语义仍然一致，至少需要支持：

- 初始化远端 mapped memory
- `read_page`
- `write_page`
- `invalidate`
- 相关容量参数，例如 `DSM_CACHE_BYTES_PER_NODE`

## 4. 编译 MySQL

推荐沿用当前 Debug 构建方式：

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
  -DWITH_UNIT_TESTS=OFF \
  -DENABLE_DOWNLOADS=1 \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

make -j"$(nproc)"
make install
```

如果 `dsm_runtime` 静态库路径变化，需要检查：

```bash
$PROJECT_ROOT/mysql-server-8.4/storage/innobase/CMakeLists.txt
```

确保 MySQL 能链接到当前机器上的 DSM runtime。

## 5. 准备 workload 工具

### 5.1 TPC-H

本包不包含 TPC-H `.tbl` 数据。需要在真机上自行生成或下载数据。

如果使用包内 `tpch-kit`：

```bash
cd $PROJECT_ROOT/workloads/tpch-kit/dbgen
make

# 生成 SF1 数据，输出到 workloads/tpch_data/sf1
mkdir -p $PROJECT_ROOT/workloads/tpch_data/sf1
cd $PROJECT_ROOT/workloads/tpch_data/sf1
$PROJECT_ROOT/workloads/tpch-kit/dbgen/dbgen -s 1 -f
```

确认数据文件存在：

```bash
ls $PROJECT_ROOT/workloads/tpch_data/sf1/*.tbl
```

如果要跑更大规模，可以生成 `sf10` 等目录，并在真机脚本中设置：

```bash
REAL_TPCH_DATASET=sf10
```

### 5.2 TPC-C

TPC-C 工具源码在：

```bash
$PROJECT_ROOT/workloads/tpcc-mysql
```

如需重新编译：

```bash
cd $PROJECT_ROOT/workloads/tpcc-mysql
make clean || true
make
```

数据装载由 `run_monitor_workloads_compare.sh` 内部调用：

```bash
$PROJECT_ROOT/workloads/prepare_tpcc.sh
```

因此通常不需要提前手动装载；每个实验 case 会创建隔离 datadir 并装载对应 TPC-C 数据。

## 6. 与真机脚本结合运行

真机运行脚本在：

```bash
real_run/
├── run_real_machine_perf.sh
├── summarize_real_machine_results.py
├── plot_real_machine_results.py
└── REAL_MACHINE_REPRODUCE_CHECKLIST.md
```

推荐命令：

```bash
cd /path/to/mysql_code_real_deploy_v1/real_run
chmod +x *.sh *.py

PROJECT_ROOT=/path/to/mysql_code_real_deploy_v1/copy_wyq_mysql \
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
REAL_TPCH_DATASET=sf1 \
REAL_TPCH_ISOLATED=1 \
REAL_TPCH_QIDS="1 3 6 12 14 19" \
./run_real_machine_perf.sh
```

TPC-H 默认使用逐查询隔离方式：每个 `qid/mode/repeat` 单独启动 MySQL，只 warmup 当前查询，然后记录正式查询窗口。这样可以避免 Q1/Q3/Q6 等查询在同一个 mysqld 进程中互相污染缓存状态。该路径依赖：

```bash
$PROJECT_ROOT/run_tpch_query_windows_isolated.sh
$PROJECT_ROOT/run_tpch_query_windows_reuse.sh
```

`run_tpch_query_windows_reuse.sh` 会输出 `seconds` 和更精细的 `wall_time_ns`；`real_run/run_real_machine_perf.sh` 汇总时会优先使用 `wall_time_ns`，因此真机 TPC-H 图表不再只依赖整秒计时。

输出目录默认在：

```bash
$PROJECT_ROOT/runs/real_machine_perf_YYYYMMDD_HHMMSS
```

主要结果文件：

```bash
real_all.tsv
real_medians.tsv
real_speedup.tsv
config.txt
```

## 7. 生成真机实验图

跑完后生成图：

```bash
cd /path/to/mysql_code_real_deploy_v1/real_run
./plot_real_machine_results.py $PROJECT_ROOT/runs/real_machine_perf_YYYYMMDD_HHMMSS
```

生成目录：

```bash
$PROJECT_ROOT/runs/real_machine_perf_YYYYMMDD_HHMMSS/figures
```

图包括：

- `real_overview_speedup.png`
- `real_micro_random_lookup.png`
- `real_micro_random_update.png`
- `real_tpcc_concurrency.png`
- `real_tpch_summary.png`
- `real_dsm_residual_disk_by_experiment.png`

## 8. 真机论文口径

真机阶段建议优先报告：

- `wall_time_ns`
- `wall_speedup`
- TPC-C 日志中的 TpmC/吞吐
- `disk_sync -> runtime_sync`
- DSM 模式残余 `disk_sync`

`logical_wall_ns` 仍可保留，但它主要用于和模拟器阶段衔接，不能替代真机 `wall_time_ns`。

推荐论文叙述：

1. Microbench 证明真实硬件上 DSM cache 是否能降低同步随机缺页端到端时间。
2. TPC-C 证明事务型负载下的收益和限制。
3. TPC-H 证明分析型查询中不同访问模式下的收益差异。
4. 若 `wall_time_ns` 和 `logical_wall_ns` 趋势不同，应优先以真机 `wall_time_ns` 为准，再结合 monitor 解释原因。

## 9. 常见问题

### `/dev/shm` 不够

如果仍使用共享内存模拟器，容器或系统 `/dev/shm` 必须大于 DSM cache 总需求。当前推荐 `DSM_CACHE_BYTES_PER_NODE=4GB`，3 个远端节点约需要 12GB 以上。模拟器阶段已经观察到：TPC-H isolated 在 512MB/节点下，Q1 这类扫描查询 warmup 会把 DSM cache 填满并触发 `[Actor Node X] No available memory`，因此不建议继续使用 512MB/节点跑 TPC-H 论文数据。

Docker 示例：

```bash
docker run --shm-size=16g ...
```

如果使用真实 DSM 后端而不是 `/dev/shm` 模拟器，则重点不是 Docker `--shm-size`，而是确认每个远端节点实际可用 cache 容量至少达到实验配置中的 `DSM_CACHE_BYTES_PER_NODE`。

### `runtime_hit` 一直为 0

优先检查：

- DSM runtime 是否启动成功
- `export_client` 是否创建了共享内存对象
- MySQL 是否以 `FIL_READ_CACHE_ENABLE=1 DSM_BRIDGE_ENABLE=1` 启动
- `DSM_CACHE_BYTES_PER_NODE` 是否过小
- `dsm_runtime` 是否和 MySQL 链接的是同一版本接口

### TPC-H 没有数据

本包不包含 `.tbl`，需要自行生成：

```bash
cd $PROJECT_ROOT/workloads/tpch-kit/dbgen
make
mkdir -p $PROJECT_ROOT/workloads/tpch_data/sf1
cd $PROJECT_ROOT/workloads/tpch_data/sf1
$PROJECT_ROOT/workloads/tpch-kit/dbgen/dbgen -s 1 -f
```

### 包内没有实验结果

这是预期行为。本包只包含源码、部署脚本和真机运行脚本。实验结果请在真机上重新生成。
