# 真机性能实验运行说明

本目录用于后续在真实超节点环境上重跑论文中最关键的性能对比实验。目标不是重复模拟器阶段的所有验证，而是用同一套 MySQL/InnoDB + DSM cache 实现，在真机上重新评估真实 `wall_time_ns`。

## 1. 实验范围

真机阶段建议只跑三类性能对比：

| 类别 | workload | 作用 |
|---|---|---|
| Microbench | `MICRO_RANDOM_LOOKUP` | 主机制验证，观察同步随机缺页中 `disk_sync -> runtime_sync` 是否带来真实 wall time 改善。 |
| Microbench | `MICRO_SCAN` | 顺序扫描/read-ahead 场景，观察异步路径是否被 DSM 接管。 |
| Microbench | `MICRO_RANDOM_UPDATE` | 写路径补充，验证更新前读冷页是否可以被 DSM 接管。 |
| TPC-C | warehouse + connections 扫描 | 事务型负载下的真实端到端性能对比。 |
| TPC-H | 代表查询或完整查询集 | 分析型负载下的真实端到端性能对比。 |

当前不建议在真机阶段优先跑完整的消融、PFS 对齐、生命周期、写后失效等实验。这些实验已经在模拟器阶段用于验证机制和统计口径；真机阶段更应该把时间花在真实性能对比上。

## 2. 文件说明

| 文件 | 说明 |
|---|---|
| `run_real_machine_perf.sh` | 真机性能实验总入口。内部调用项目已有的 `run_monitor_workloads_compare.sh`。 |
| `summarize_real_machine_results.py` | 聚合每组重复实验，生成 median 与 speedup 表。 |
| `plot_real_machine_results.py` | 基于 `real_medians.tsv` 和 `real_speedup.tsv` 生成论文用性能图。 |
| `REAL_MACHINE_REPRODUCE_CHECKLIST.md` | 不依赖远端访问的完整复现检查清单。 |
| `README.md` | 本说明文档。 |

TPC-H 默认采用逐查询隔离口径，需要项目工作区中存在：

```bash
/workspace/ltCopyWorkspace/copy_wyq_mysql/run_tpch_query_windows_isolated.sh
```

该脚本会对每个 `qid/mode/repeat` 单独启动 MySQL，并只 warmup 当前查询，避免多个 TPC-H 查询在同一个 mysqld 进程中相互污染缓存状态。如果目标工作区暂时没有该脚本，可以先从当前实现包中复制，或设置 `REAL_TPCH_ISOLATED=0` 回退到旧的聚合 TPC-H 运行方式。

## 3. 前置条件

真机工作区需要已经准备好以下内容：

```bash
/workspace/ltCopyWorkspace/copy_wyq_mysql
├── run_monitor_workloads_compare.sh
├── mysql_install_verify/
├── workloads/
├── ub2_simulator/dsm_runtime/       # 如果真机仍复用模拟器启动方式
└── ...
```

如果真机已经接入真实 DSM 后端，而不是 `ub2_simulator/dsm_runtime`，需要保证 `run_monitor_workloads_compare.sh` 中 `DSM` 模式对应的启动、环境变量和共享内存映射路径已经改成真机后端。本文脚本不重新实现 DSM 后端，只负责组织实验矩阵。

## 4. 推荐运行方式

将整个 `real_run` 目录复制到真机，然后执行：

```bash
cd /path/to/real_run
chmod +x run_real_machine_perf.sh summarize_real_machine_results.py

PROJECT_ROOT=/workspace/ltCopyWorkspace/copy_wyq_mysql \
REAL_RUN_ROOT=/workspace/ltCopyWorkspace/copy_wyq_mysql/runs/real_machine_perf_$(date +%Y%m%d_%H%M%S) \
./run_real_machine_perf.sh
```

如果是在当前 Docker/模拟器环境中预演，也可以直接设置相同的 `PROJECT_ROOT`。但论文真机结果应以真实硬件环境中的 `wall_time_ns` 为准。

## 5. 默认实验参数

### 5.1 通用参数

| 参数 | 默认值 | 说明 |
|---|---:|---|
| `REAL_REPEATS` | `3` | 每组实验重复次数，最终取 median。 |
| `MYSQL_BP_SIZE` | `5M` | 正式测量阶段 Buffer Pool。用于稳定制造 Buffer Pool miss。 |
| `LOAD_MYSQL_BP_SIZE` | `512M` | 数据装载阶段 Buffer Pool。 |
| `DSM_CACHE_BYTES_PER_NODE` | `4294967296` | 每节点 DSM cache 容量，默认 4GB。TPC-H isolated 预热会写入大量 clean page，512MB/节点容易触发 runtime 容量耗尽。 |
| `FIL_READ_CACHE_MAX_PAGES` | `1048576` | read-through cache 最大页数。默认与 4GB/节点、3 个远端节点的实验口径匹配。 |
| `COST_BUF_NS` | `100` | 逻辑耗时模型中的 Buffer Pool 成本。 |
| `COST_DSM_NS` | `300` | 逻辑耗时模型中的 DSM 成本。真机阶段主要看 `wall_time_ns`。 |
| `COST_DISK_NS` | `30000` | 逻辑耗时模型中的 Disk 成本。真机阶段主要看 `wall_time_ns`。 |

真机论文中应优先报告 `wall_time_ns` / wall time speedup；`logical_wall_ns` 仍可作为页来源替代的解释指标保留。

### 5.2 Microbench 参数

| workload | 默认参数 |
|---|---|
| `MICRO_RANDOM_LOOKUP` | `REAL_RANDOM_PAGES_LIST="3000 6000 12000"`，`REAL_RANDOM_WARMUP_PASSES=1`，`REAL_RANDOM_PASSES=8` |
| `MICRO_SCAN` | `REAL_SCAN_PAGES_LIST="3000 6000"`，`REAL_SCAN_WARMUP_REPEATS=1`，`REAL_SCAN_REPEATS=8` |
| `MICRO_RANDOM_UPDATE` | `REAL_RANDOM_UPDATE_PAGES_LIST="800 1500"`，`REAL_RANDOM_UPDATE_WARMUP_PASSES=1`，`REAL_RANDOM_UPDATE_PASSES=2` |

如果真机时间有限，建议优先保留：

```bash
REAL_RUN_MICRO_RANDOM=1
REAL_RUN_MICRO_SCAN=1
REAL_RUN_MICRO_RANDOM_UPDATE=1
REAL_RANDOM_PAGES_LIST="6000 12000"
REAL_SCAN_PAGES_LIST="6000"
REAL_RANDOM_UPDATE_PAGES_LIST="1500"
```

### 5.3 TPC-C 参数

默认配置：

```bash
REAL_TPCC_W=4
REAL_TPCC_CONNS_LIST="1 2 4 8"
REAL_TPCC_WARMUP_DURATION=60
REAL_TPCC_RAMPUP=0
REAL_TPCC_DURATION=180
```

如果真机资源更充足，可以提高：

```bash
REAL_TPCC_W=8
REAL_TPCC_DURATION=300
REAL_TPCC_CONNS_LIST="1 2 4 8 16"
```

TPC-C 除了 `wall_time_ns` 外，还应保留 `tpcc_start` 日志中的 TpmC/吞吐信息。`run_monitor_workloads_compare.sh` 会把每次运行日志保存在对应 run 目录中。

### 5.4 TPC-H 参数

默认配置：

```bash
REAL_TPCH_DATASET=sf1
REAL_TPCH_QIDS="1 3 6 12 14 19"
REAL_TPCH_ISOLATED=1
REAL_TPCH_WARMUP_REPEATS=1
REAL_REPEATS=3
REAL_TPCH_QUERY_TIMEOUT_SEC=600
```

`REAL_TPCH_ISOLATED=1` 时，脚本不再把全部查询放在一次聚合 TPC-H run 中，而是调用 `run_tpch_query_windows_isolated.sh`。输出会按 `TPCH_Q1`、`TPCH_Q3`、`TPCH_Q6`、`TPCH_Q12`、`TPCH_Q14`、`TPCH_Q19` 分别进入 `real_all.tsv`、`real_medians.tsv` 和 `real_speedup.tsv`，更适合论文画逐查询对比图。

当前部署包中的 `run_tpch_query_windows_reuse.sh` 会同时输出 `seconds` 和 `wall_time_ns`。`run_real_machine_perf.sh` 汇总 TPC-H isolated 结果时优先使用 `wall_time_ns`，因此真机 TPC-H 的 wall time 图不再只依赖整秒级计时。如果目标机器上的脚本仍是旧版，只输出 `seconds`，汇总脚本会自动回退到 `seconds * 1e9`，但论文正式数据建议使用新版纳秒字段。

在当前模拟器环境中已经验证过：若仍使用 512MB/节点，TPC-H Q1 这类扫描查询在 warmup 填充 DSM cache 时可能出现 `[Actor Node X] No available memory`。因此真机或模拟器复现实验建议保证：

```bash
# Docker/容器环境
--shm-size=16g

# 实验环境变量
DSM_CACHE_BYTES_PER_NODE=4294967296
FIL_READ_CACHE_MAX_PAGES=1048576
```

如果真机 DSM 后端本身不是通过 `/dev/shm` 暴露容量，则不需要 Docker `--shm-size`，但仍应保证每节点可用远端缓存容量不低于 TPC-H 预热阶段的 clean page 填充需求。

如果真机时间足够，可以跑完整 Q1-Q22：

```bash
REAL_TPCH_QIDS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22"
REAL_REPEATS=1
```

## 6. 只跑部分实验

所有实验都可以通过开关控制：

```bash
REAL_RUN_MICRO_RANDOM=1
REAL_RUN_MICRO_SCAN=1
REAL_RUN_MICRO_RANDOM_UPDATE=1
REAL_RUN_TPCC=1
REAL_RUN_TPCH=1
```

例如只跑 microbench：

```bash
PROJECT_ROOT=/workspace/ltCopyWorkspace/copy_wyq_mysql \
REAL_RUN_MICRO_RANDOM=1 \
REAL_RUN_MICRO_SCAN=1 \
REAL_RUN_MICRO_RANDOM_UPDATE=1 \
REAL_RUN_TPCC=0 \
REAL_RUN_TPCH=0 \
./run_real_machine_perf.sh
```

例如只跑 TPC-C：

```bash
PROJECT_ROOT=/workspace/ltCopyWorkspace/copy_wyq_mysql \
REAL_RUN_MICRO_RANDOM=0 \
REAL_RUN_MICRO_SCAN=0 \
REAL_RUN_MICRO_RANDOM_UPDATE=0 \
REAL_RUN_TPCC=1 \
REAL_RUN_TPCH=0 \
REAL_TPCC_CONNS_LIST="1 2 4 8" \
./run_real_machine_perf.sh
```

例如只跑 TPC-H：

```bash
PROJECT_ROOT=/workspace/ltCopyWorkspace/copy_wyq_mysql \
DSM_CACHE_BYTES_PER_NODE=4294967296 \
FIL_READ_CACHE_MAX_PAGES=1048576 \
REAL_RUN_MICRO_RANDOM=0 \
REAL_RUN_MICRO_SCAN=0 \
REAL_RUN_MICRO_RANDOM_UPDATE=0 \
REAL_RUN_TPCC=0 \
REAL_RUN_TPCH=1 \
REAL_TPCH_ISOLATED=1 \
REAL_TPCH_QIDS="1 3 6 12 14 19" \
./run_real_machine_perf.sh
```

## 7. 输出结果

运行结束后会生成：

```bash
$REAL_RUN_ROOT/
├── config.txt
├── real_all.tsv
├── real_medians.tsv
├── real_speedup.tsv
├── figures/
├── micro_random_lookup/
├── micro_scan/
├── micro_random_update/
├── tpcc/
├── tpch/                    # REAL_TPCH_ISOLATED=0 时生成
└── tpch_isolated/           # 默认 TPC-H 逐查询隔离结果
```

关键文件：

| 文件 | 内容 |
|---|---|
| `config.txt` | 本次运行的参数、CPU、磁盘和 `/dev/shm` 信息。 |
| `real_all.tsv` | 每次重复的原始结果。 |
| `real_medians.tsv` | 按 `experiment/workload/mode/config` 聚合后的中位数。 |
| `real_speedup.tsv` | `NO_DSM` 与 `DSM` 配对后的 wall/logical speedup 和页来源替代比例。 |
| `figures/` | 使用 `plot_real_machine_results.py` 生成的论文用图。 |

论文真机阶段建议优先使用 `real_speedup.tsv` 中的：

| 字段 | 用途 |
|---|---|
| `no_dsm_wall_s` / `dsm_wall_s` | 真机端到端耗时对比。 |
| `wall_speedup` | 真机最核心性能指标。 |
| `no_dsm_disk_sync` | 对照组同步磁盘读事件数。 |
| `dsm_runtime_sync` | DSM 组同步远端命中事件数。 |
| `dsm_disk_sync` | DSM 组残余同步磁盘读事件数。 |
| `sync_disk_replaced_pct` | 同步磁盘读被替代比例。 |

## 8. 生成论文图

`run_real_machine_perf.sh` 默认只负责跑数和汇总 TSV。真机实验跑完后，可以用下面命令生成图：

```bash
cd /path/to/real_run
./plot_real_machine_results.py /workspace/ltCopyWorkspace/copy_wyq_mysql/runs/real_machine_perf_xxx
```

也可以指定输出目录：

```bash
./plot_real_machine_results.py \
  /workspace/ltCopyWorkspace/copy_wyq_mysql/runs/real_machine_perf_xxx \
  /workspace/ltCopyWorkspace/copy_wyq_mysql/runs/real_machine_perf_xxx/figures
```

默认会生成以下图：

| 图片 | 内容 |
|---|---|
| `real_overview_speedup.png` | 所有实验的 wall speedup 与 logical speedup 总览。 |
| `real_micro_random_lookup.png` | 随机点查的真实 wall time 和同步页来源替代关系。 |
| `real_micro_random_update.png` | 随机更新中更新前读冷页的 wall time 和页来源替代关系。 |
| `real_tpcc_concurrency.png` | TPC-C 不同并发下的 speedup 与同步页来源变化。 |
| `real_tpch_summary.png` | TPC-H 逐查询或聚合结果的 wall time 与同步页来源变化。默认逐查询展示 Q1/Q3/Q6/Q12/Q14/Q19。 |
| `real_dsm_residual_disk_by_experiment.png` | DSM 模式下各实验残余同步磁盘读，用于检查 DSM 是否仍有落盘。 |

## 9. 写论文时的建议表述

真机实验可以这样组织：

1. Microbench 先证明机制上真实有效：同步随机缺页中，DSM 组应同时表现为 `wall_time` 下降和 `disk_sync -> runtime_sync`。
2. TPC-C 再说明事务场景下的真实收益和限制：如果收益低，需要结合锁、日志、更新路径解释。
3. TPC-H 最后说明分析型查询中不同 query 的差异：同步缺页占比高的 query 更可能受益，长扫描/read-ahead 场景可能收益较弱。

如果真机 `wall_time_ns` 与 `logical_wall_ns` 趋势不一致，应优先相信 `wall_time_ns`，再用 monitor 字段解释原因，例如真实 DSM 后端开销、网络/总线带宽、并发竞争或模拟阶段成本模型偏差。

## 10. 最小推荐命令

如果只想先跑一版可写进论文的真机性能结果：

```bash
cd /path/to/real_run
chmod +x run_real_machine_perf.sh summarize_real_machine_results.py

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

./plot_real_machine_results.py "$REAL_RUN_ROOT"
```
