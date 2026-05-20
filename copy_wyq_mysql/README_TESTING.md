# DSM Monitor Test README

这份目录用于复现 MySQL/InnoDB DSM cache monitor 的测试。核心入口是：

```bash
./run_monitor_workloads_compare.sh
```

脚本会在每个 case 中创建独立 datadir，先装载数据并关闭 MySQL，再重新启动 MySQL 打开 monitor 执行 workload。这样 summary 主要统计 workload 本身，不把数据装载阶段混进去。

## 四个实验入口

现在建议直接用下面 4 个脚本分别跑 4 组实验，每组都只负责一种 workload，避免结果互相干扰：

```text
run_exp_tpch.sh
run_exp_tpcc.sh
run_exp_micro_scan.sh
run_exp_micro_random.sh
```

它们最终都会调用同一个主脚本 `run_monitor_workloads_compare.sh`，只是预先固定了各自的 workload 参数。

`run_exp_tpch.sh` 默认跑的是一组代表性 TPC-H 查询；如果想改成全量 Q1-Q22，可以直接覆盖 `TPCH_QIDS`。

## 论文实验入口

如果目标是生成论文图，建议使用总控脚本：

```bash
./run_paper_experiments.sh
```

这个脚本会打开 `MEASURE_WITH_WINDOW=1`，每个 case 都按“预热阶段 + 正式统计阶段”执行。正式阶段前后会触发 `/tmp/fil_read_cache_dump`，脚本用两次 `tag=window` 的 monitor 快照做 delta，因此 `summary.tsv` 不再把 DSM 第一次填充成本混入正式统计窗口。

为了让 DSM cache 容量实验有意义，容器内 `/dev/shm` 需要明显大于 `3 * DSM_CACHE_BYTES_PER_NODE`。论文实验推荐先用 `--shm-size=4g` 重建容器，再使用：

```bash
DSM_CACHE_BYTES_PER_NODE=536870912
```

即每个 DSM 节点 512MB、三个节点总计约 1.5GB。当前 64MB `/dev/shm` 下只能稳定跑 16MB/节点，更适合功能验证，不适合画大容量收益图。

在当前 gpu7 环境中，已有容器 `fenghaibin_restore` 的镜像和挂载可以按下面方式重建一个大 `/dev/shm` 容器：

```bash
docker stop fenghaibin_restore
docker rm fenghaibin_restore
docker run -dit \
  --name fenghaibin_restore \
  --shm-size=4g \
  -v /mnt/lustre-client/fenghaibin/workspace:/workspace \
  -w /workspace \
  lt_innodb_image:260121 \
  bash
```

如果不想影响当前容器，也可以改一个新名字，例如 `fenghaibin_paper`，然后进入新容器运行同一目录下的脚本。

总控脚本默认输出：

```text
runs/paper_logical_YYYYMMDD_HHMMSS/
  paper_all.tsv
  paper_medians.tsv
  paper_micro_random.tsv
  paper_dsm_capacity.tsv
  paper_bp_sensitivity.tsv
  paper_micro_scan.tsv
  paper_tpcc.tsv
  paper_tpch.tsv
  config.txt
```

每行包含：

```text
experiment workload mode config repeat buf_hit runtime_sync runtime_async disk_sync disk_async wall_time_ns logical_wall_ns status log
```

论文主图优先使用 `paper_medians.tsv` 里的 `logical_wall_ns_median`。`TPC-C` 和 `TPC-H` 不强制写成性能提升实验；如果 `logical_wall_ns` 不稳定或收益不明显，应作为真实负载下访问模式限制来分析。

## 默认实验

进入目录：

```bash
cd /workspace/ltCopyWorkspace/copy_wyq_mysql
./run_monitor_workloads_compare.sh
```

默认主脚本会运行：

```text
TPCH_no_dsm
TPCC_no_dsm
MICRO_SCAN_no_dsm
MICRO_RANDOM_LOOKUP_no_dsm
TPCH_dsm
TPCC_dsm
MICRO_SCAN_dsm
MICRO_RANDOM_LOOKUP_dsm
```

输出目录默认是：

```text
runs/monitor_compare_YYYYMMDD_HHMMSS/
```

最重要的结果文件是：

```text
summary.tsv
```

## Workload 说明

`TPCH`

默认使用 `tpch_data/sf1`，通过 `tpch-kit/dbgen/qgen` 生成查询。当前复现实验脚本默认执行代表性子集 `Q1/Q3/Q6/Q12/Q14/Q19`，重复 2 轮；如果要跑全量 Q1-Q22，可以覆盖 `TPCH_QIDS`。每条查询会写入独立 SQL 文件，执行状态会记录到 `TPCH_*_tpch_query_status.tsv`。

注意：在 `MYSQL_BP_SIZE=5M` 的默认配置下，Q18 等重查询可能明显慢于 Q6。脚本默认给每条查询设置 `TPCH_QUERY_TIMEOUT_SEC=300`，超时会记录为 `TIMEOUT`，不会无限挂住整组实验。

如果包里没有附带 `workloads/tpch_data/*.tbl`，需要先自行下载或生成 TPC-H 数据，见下面的 “TPC-H 数据准备”。

`TPCC`

默认 `1 warehouse / 1 connection / 5s rampup / 60s duration`。它用于验证事务型 workload 可以跑通，且给 DSM 足够时间进入复用阶段。

脚本会为每个 TPC-C case 额外保存：

```text
TPCC_*_load.log
TPCC_*_tpcc_counts_after_load.tsv
TPCC_*_tpcc_counts_before_workload.tsv
TPCC_*_tpcc_counts_after_workload.tsv
```

这些文件用于确认 `tpcc_load` 是否真的装载了数据。`warehouse=1`、`district=10`、`customer=30000`、`stock=100000` 是 `TPCC_W=1` 下的基本完整性检查。

`MICRO_SCAN`

顺序扫描型 microbench。它创建 `hot` 表并多次全表扫描，热集大于 `5MB` Buffer Pool，适合观察 read-ahead/async 路径和 DSM 对顺序扫描的影响。

`MICRO_RANDOM_LOOKUP`

跳跃点查型 microbench。它使用较宽的行，让一页大约放 4 条记录；访问顺序用固定 stride 打散，目标是让点查的数据叶子页更容易从 Buffer Pool 中被挤出，从而观察 `runtime_sync` 和 `disk_sync` 的变化。

## 关键参数

成本模型：

```bash
COST_BUF_NS=100
COST_DSM_NS=300
COST_DISK_NS=30000
```

Buffer Pool：

```bash
MYSQL_BP_SIZE=5M
```

TPC-H：

```bash
TPCH_DATASET=sf1
TPCH_QUERY_REPEATS=2
TPCH_QIDS="1 3 6 12 14 19"
TPCH_QUERY_TIMEOUT_SEC=300
```

## TPC-H 数据准备

为了减小代码包体积，`workloads/tpch_data/*.tbl` 可以不随包分发。用户有两种方式准备数据。

方式一：从已有机器复制数据。

把数据放到下面目录：

```text
workloads/tpch_data/smoke/
workloads/tpch_data/sf1/
```

每个目录需要包含 8 个 `.tbl` 文件：

```text
region.tbl
nation.tbl
supplier.tbl
customer.tbl
part.tbl
partsupp.tbl
orders.tbl
lineitem.tbl
```

方式二：用 `tpch-kit/dbgen` 生成。

如果 `workloads/tpch-kit/dbgen/dbgen` 已经编译好：

```bash
cd workloads/tpch-kit/dbgen
mkdir -p ../../tpch_data/sf1
./dbgen -s 1 -f
mv *.tbl ../../tpch_data/sf1/
```

如果 `dbgen` 还没有编译：

```bash
cd workloads/tpch-kit/dbgen
make
mkdir -p ../../tpch_data/sf1
./dbgen -s 1 -f
mv *.tbl ../../tpch_data/sf1/
```

如果确实需要一个更小的快速验证集，也可以从 SF1 截取子集。下面命令会保留小规模行数，适合快速验证：

```bash
cd workloads
mkdir -p tpch_data/smoke
head -n 5 tpch_data/sf1/region.tbl   > tpch_data/smoke/region.tbl
head -n 25 tpch_data/sf1/nation.tbl   > tpch_data/smoke/nation.tbl
head -n 100 tpch_data/sf1/supplier.tbl > tpch_data/smoke/supplier.tbl
head -n 1500 tpch_data/sf1/customer.tbl > tpch_data/smoke/customer.tbl
head -n 2000 tpch_data/sf1/part.tbl > tpch_data/smoke/part.tbl
head -n 8000 tpch_data/sf1/partsupp.tbl > tpch_data/smoke/partsupp.tbl
head -n 15000 tpch_data/sf1/orders.tbl > tpch_data/smoke/orders.tbl
head -n 60000 tpch_data/sf1/lineitem.tbl > tpch_data/smoke/lineitem.tbl
```

准备好后即可运行 TPC-H：

```bash
./run_exp_tpch.sh
```

如果只想快速验证某几个查询，可以显式指定 `TPCH_QIDS`：

```bash
TPCH_DATASET=sf1 TPCH_QIDS="1 6 12 18" TPCH_QUERY_REPEATS=1 ./run_exp_tpch.sh
```

TPC-C：

```bash
TPCC_W=1
TPCC_CONNS=1
TPCC_RAMPUP=5
TPCC_DURATION=60
DSM_CACHE_BYTES_PER_NODE=16777216
```

TPC-C 也需要让 DSM 有足够时间从填充进入复用阶段；过短的运行时间会让 DSM 主要承担填充，低估替代磁盘读的效果。

MICRO_SCAN：

```bash
MICRO_SCAN_HOT_PAGES=1500
MICRO_SCAN_QUERY_REPEATS=6
DSM_CACHE_BYTES_PER_NODE=16777216
```

顺序扫描同样需要多轮重复。第 1 轮主要把扫描页写入 DSM，后续扫描才会更多命中 `runtime_async`。

MICRO_RANDOM_LOOKUP：

```bash
MICRO_RANDOM_PAGES=1500
MICRO_RANDOM_ROWS_PER_PAGE=4
MICRO_RANDOM_PASSES=6
MICRO_RANDOM_STRIDE=997
DSM_CACHE_BYTES_PER_NODE=16777216
FIL_READ_CACHE_MAX_PAGES=16384
```

随机点查需要多轮重复访问才能体现 DSM 的价值：第 1 轮主要负责把页填充进 DSM，后续轮次才会大量命中 DSM。当前容器 `/dev/shm` 只有 64MB，因此默认把 DSM 每节点共享内存设为 16MB，总计 48MB；如果用更大的 `--shm-size` 重建容器，可以再放大这个参数。

选择 workload：

```bash
RUN_TPCH=0
RUN_TPCC=0
RUN_MICRO_SCAN=0
RUN_MICRO_RANDOM=1
```

例如只跑随机点查：

```bash
RUN_TPCH=0 RUN_TPCC=0 RUN_MICRO_SCAN=0 RUN_MICRO_RANDOM=1 ./run_monitor_workloads_compare.sh
```

## Summary 字段

`buf_hit`

Buffer Pool 命中次数。注意它包含 B+Tree 根页、内部页、系统页和元数据页，所以随机点查里两组 `buf_hit` 接近是正常的。

`runtime_hit`

DSM 命中总次数。

`runtime_sync`

前台同步路径上的 DSM 命中。这个字段对随机点查很关键。

`runtime_async`

异步/预读路径上的 DSM 命中。这个字段对顺序扫描更关键。

`disk_read`

实际走磁盘的读次数。

`disk_sync`

前台同步路径上的磁盘读。这个字段越低，说明同步缺页被 DSM 替代得越多。

`disk_async`

异步/预读路径上的磁盘读。

`wall_time_ns`

workload 阶段的实际 wall time，不包含 datadir 初始化、数据装载、mysqld 启停时间。

`logical_wall_ns`

端到端重估耗时。公式是：

```text
NO_DSM.wall_time_ns - NO_DSM_sync_io_ns + current_sync_io_ns
```

例如 NO_DSM 实际跑 100s，其中同步 I/O 估算 20s；DSM 同步 I/O 重估 1s，则 DSM 的端到端重估耗时为 `100s - 20s + 1s = 81s`。

`pfs_pages_read` / `pfs_data_reads`

来自 MySQL `performance_schema.global_status`，用于和 monitor 做正确性对照。

## 推荐复现实验

TPC-H：

```bash
./run_exp_tpch.sh
```

TPC-C：

```bash
./run_exp_tpcc.sh
```

Micro scan：

```bash
./run_exp_micro_scan.sh
```

Micro random lookup：

```bash
./run_exp_micro_random.sh
```

## 当前注意事项

`buf_hit` 不能单独用来判断 DSM 是否有效。DSM 只在 Buffer Pool miss 之后介入，所以应重点比较：

```text
runtime_sync / disk_sync
runtime_async / disk_async
wall_time_ns / logical_wall_ns
```

在随机点查中，B+Tree 根页和内部页会常驻 Buffer Pool，因此 `buf_hit` 在 DSM 和 no_dsm 两组接近是合理的。
