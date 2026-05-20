# DSM Monitor 测试汇报

## 目标

本轮测试的目标是验证 MySQL/InnoDB 接入 DSM cache 后，monitor 能够区分页访问来源，并基于设定的真实硬件延迟模型重新计算 I/O 成本。

当前延迟模型为：

```text
Buffer Pool = 100 ns
DSM         = 300 ns
Disk        = 30000 ns
```

测试脚本：

```text
run_monitor_workloads_compare.sh
```

该脚本支持 `NO_DSM` 和 `DSM` 两组对比，并输出统一的 `summary.tsv`。

## 测试对象

本轮把实验拆成 4 个独立入口，分别对应 4 类 workload：

```text
run_exp_tpch.sh
run_exp_tpcc.sh
run_exp_micro_scan.sh
run_exp_micro_random.sh
```

对应 workload 为：

```text
TPC-H
TPC-C
MICRO_SCAN
MICRO_RANDOM_LOOKUP
```

`TPC-H` 通过 `qgen` 生成 SF1 查询。本轮完整结果使用代表性查询子集 `Q1/Q3/Q6/Q12/Q14/Q19`，重复 2 轮，并通过 `TPCH_QUERY_TIMEOUT_SEC` 避免单个重查询无限挂住。

`TPC-C` 使用 1 warehouse、1 connection，可通过 `TPCC_DURATION` 控制运行时间，验证事务型路径。

`MICRO_SCAN` 是顺序扫描型 microbench，主要观察顺序读和 read-ahead 场景。

`MICRO_RANDOM_LOOKUP` 是跳跃点查型 microbench，使用较宽的行和小 Buffer Pool，主要观察同步随机缺页是否被 DSM 替代。

## 关键实现

测试依赖 InnoDB 中的 `fil_cache_monitor`。它统计：

```text
buf_hit
runtime_hit
runtime_sync
runtime_async
disk_read
disk_sync
disk_async
wall_time_ns
logical_wall_ns
```

其中最重要的是：

```text
runtime_sync vs disk_sync
runtime_async vs disk_async
wall_time_ns / logical_wall_ns
```

### 字段含义

当前 monitor 输出的是“页访问事件次数”，不是去重后的唯一页数。也就是说，同一个 `page_id` 如果被访问 10 次，会在对应路径上累计 10 次。报告中的 `logical_wall_ns` 也是基于访问次数乘以延迟模型计算出来的。

如果后续要统计“能够 cache 的唯一页数”，需要在 monitor 中额外维护按 `(space_id, page_no)` 去重的集合，分别统计 `buf_unique_pages`、`runtime_unique_pages`、`disk_unique_pages` 等字段。当前实现还没有输出这类唯一页数。

`buf_hit`

Buffer Pool 命中访问次数。表示页在本次访问之前已经驻留在 Buffer Pool 中，没有进入 DSM 或磁盘路径。它包含 B+Tree 根页、内部页、系统页和元数据页，因此不能单独作为 DSM 是否有效的判断标准。

`runtime_hit`

DSM/read-through cache 命中访问总次数，等于 `runtime_sync + runtime_async`。

`runtime_sync`

前台同步读路径上的 DSM 命中次数。它对应用户请求直接触发的 Buffer Pool miss 后，被 DSM 替代的同步磁盘读，是估算请求可感知 I/O 延迟时最关键的 DSM 指标。

`runtime_async`

异步读或 read-ahead 路径上的 DSM 命中次数。它更适合观察顺序扫描、预读等后台/异步 I/O 场景。

`disk_read`

最终真正落到磁盘读的访问总次数，等于 `disk_sync + disk_async`。

`disk_sync`

前台同步读路径上的磁盘读次数。和 `runtime_sync` 对比，可以看到有多少同步缺页被 DSM 替代。

`disk_async`

异步读或 read-ahead 路径上的磁盘读次数。和 `runtime_async` 对比，可以观察 DSM 对扫描/预读路径的替代效果。

`wall_time_ns`

workload 阶段的实际 wall time。脚本只计 benchmark/query 执行阶段，不把初始化 datadir、装载数据、启动/关闭 mysqld 的时间算进去。

`logical_wall_ns`

端到端重估耗时。它以同一 workload 的 `NO_DSM` 实际运行时间为基准，扣掉 `NO_DSM` 的同步 I/O 估算耗时，再加上当前模式的同步 I/O 估算耗时：

```text
logical_wall_ns =
  NO_DSM.wall_time_ns
  - NO_DSM_sync_io_ns
  + current_sync_io_ns

sync_io_ns =
  buf_hit * COST_BUF_NS
  + runtime_sync * COST_DSM_NS
  + disk_sync * COST_DISK_NS
```

例如实际 NO_DSM 跑了 100s，其中同步 I/O 估算耗时为 20s；如果 DSM 的同步 I/O 估算耗时为 1s，那么 DSM 的端到端重估耗时就是：

```text
100s - 20s + 1s = 81s
```

这个字段用于回答“如果把原本的同步 I/O 成本替换成 DSM 成本，整体运行时间大约会是多少”。它更接近端到端性能影响，但仍然没有建模并发重叠、CPU stall 变化和真实 DSM runtime 开销。

### monitor 是怎么检测页来源的

核心代码位置：

```text
mysql-server-8.4/storage/innobase/include/fil0fil.h
mysql-server-8.4/storage/innobase/fil/fil0fil.cc
mysql-server-8.4/storage/innobase/buf/buf0buf.cc
mysql-server-8.4/storage/innobase/CMakeLists.txt
ub2_simulator/dsm_runtime/dsm_bridge.cpp
```

实现上分成三层：声明统计接口、在 InnoDB 读路径打点、在 mysqld 关闭/窗口 dump 时输出统计。

第一层是统计接口。`fil0fil.h` 里声明了 `fil_cache_monitor` namespace，包含：

```text
enabled()
is_cacheable_page(page_id)
record_buf_hit(page_id)
record_runtime_hit(page_id, sync)
record_disk_read(page_id, sync)
```

这些接口的作用是把 InnoDB 页访问归到三类来源：

```text
buf_hit      = Buffer Pool 已经有这个页，直接命中
runtime_hit  = Buffer Pool miss 后，从 DSM/read-through cache 命中
disk_read    = Buffer Pool miss 且 DSM/read-through cache miss，最后落到磁盘 I/O
```

第二层是计数器和开关。`fil0fil.cc` 中维护了 5 个核心原子计数：

```text
s_buf_hit
s_runtime_hit_sync
s_runtime_hit_async
s_disk_read_sync
s_disk_read_async
```

mysqld 启动时 `fil_cache_monitor::init()` 从环境变量读取开关和成本模型：

```text
FIL_CACHE_MONITOR_ENABLE
FIL_CACHE_MONITOR_TRACE
FIL_CACHE_MONITOR_COST_BUF_NS
FIL_CACHE_MONITOR_COST_RUNTIME_NS
FIL_CACHE_MONITOR_COST_DISK_NS
```

本报告使用的成本参数是：

```text
FIL_CACHE_MONITOR_COST_BUF_NS=100
FIL_CACHE_MONITOR_COST_RUNTIME_NS=300
FIL_CACHE_MONITOR_COST_DISK_NS=30000
```

第三层是实际打点位置。

Buffer Pool 命中在 `buf0buf.cc` 的 page fetch 路径里统计。代码判断本次访问是在 hash lookup 阶段已经找到页，并且这次 fetch 没有发起 I/O：

```text
if (m_found_in_lookup && !m_started_read && !block->page.was_io_fixed()) {
  fil_cache_monitor::record_buf_hit(m_page_id);
}
```

这个判断避免把“刚刚由本次 I/O 读进来的页”误算成 Buffer Pool hit。也就是说，`buf_hit` 统计的是进入当前访问路径之前就已经驻留在 Buffer Pool 的页。

DSM/read-through cache 命中在 `fil0fil.cc` 的 `fil_io()` 前半段统计。读请求进入磁盘 I/O 之前，先调用：

```text
fil_read_cache::get(page_id, len, buf)
```

如果命中，并且当前后端是 DSM，则记录：

```text
fil_cache_monitor::record_runtime_hit(page_id, sync);
```

这里的 `sync` 来自 InnoDB I/O 请求本身，用来区分：

```text
runtime_sync   = 前台同步缺页从 DSM 命中
runtime_async  = async/read-ahead 路径从 DSM 命中
```

如果是 async 读从 DSM 命中，代码会合成一次 AIO completion，让上层 Buffer Pool 状态机看到和真实磁盘读完成一致的状态，因此不需要改调用者逻辑。

磁盘读统计发生在同一个 `fil_io()` 里。如果 DSM/read-through cache 没命中，流程继续落到：

```text
shard->do_io(...)
```

只有 `do_io` 返回成功，才记录：

```text
fil_cache_monitor::record_disk_read(page_id, sync);
```

因此：

```text
disk_sync   = 前台同步路径最终真的读了磁盘
disk_async  = async/read-ahead 路径最终真的读了磁盘
```

第四层是 cacheable 页过滤。`is_cacheable_page()` 排除了系统表空间、临时表空间和 undo tablespace：

```text
page_id.space() != TRX_SYS_SPACE
!fsp_is_system_temporary(page_id.space())
!fsp_is_undo_tablespace(page_id.space())
```

所以 monitor 统计的是“我们关心且可被 DSM/read-through cache 替代的页路径”。这也是它和 `performance_schema.global_status` 不会严格相等的原因：PFS 是全局 InnoDB 读计数，包含更多内部页和系统页。

第五层是输出和重算耗时。`dump_stats_to_err()` 会输出两行到 mysqld error log：

```text
[fil_cache_monitor][stats] ...
[fil_cache_monitor][estimate_ns] ...
```

其中 `estimate_ns` 在脚本内部用于计算 `logical_wall_ns`，同步 I/O 估算公式是：

```text
sync_io_ns =
  buf_hit * COST_BUF_NS
  + runtime_sync * COST_DSM_NS
  + disk_sync * COST_DISK_NS
```

报告不再展示中间估算列，只保留最终的 `logical_wall_ns`。

### DSM cache 后端是怎么接入的

`fil_cache_monitor` 只负责计数；真正的 DSM 二级缓存由 `fil_read_cache` 和 `dsm_bridge` 提供。

编译接入在 `storage/innobase/CMakeLists.txt`。InnoDB 会优先从当前工作区查找：

```text
../ub2_simulator/dsm_runtime
../../ub2_simulator/dsm_runtime
/workspace/ltCopyWorkspace/ub2_simulator/dsm_runtime
/workspace/ub2_simulator/dsm_runtime
```

然后链接：

```text
libdsm_runtime_lib.a
libobmm_client.a
```

运行时 `fil_read_cache::init()` 根据环境变量初始化：

```text
FIL_READ_CACHE_ENABLE=1      打开 read-through cache 层
DSM_BRIDGE_ENABLE=1          尝试使用 DSM 后端
FIL_READ_CACHE_MAX_PAGES=N   DSM 不可用时，内存 fallback LRU 的最大页数
DSM_CACHE_BYTES_PER_NODE=N   DSM 每个节点可用容量
```

当前容器 `ShmSize=67108864`，即 `/dev/shm` 只有 64MB。因此默认使用 `DSM_CACHE_BYTES_PER_NODE=16777216`，即每个 DSM 节点 16MB，共 3 个 memid，总计 48MB。若用更大的 `--shm-size` 重建容器，可以再把该值放大到 128MB/节点做大容量复用实验。

如果 `DSM_BRIDGE_ENABLE=1` 且 simulator/export_client 已经创建共享内存，`dsm_bridge::setup()` 会 mmap：

```text
/dev/shm/virtual_node0/obmm_shmdev1
/dev/shm/virtual_node0/obmm_shmdev2
/dev/shm/virtual_node0/obmm_shmdev3
```

随后把 `(space_id, page_no)` 映射成 DSM runtime 内部的连续 `vpage`。读路径是：

```text
dsm_bridge::read_page(space_id, page_no, buf, len)
```

写入/填充路径是：

```text
dsm_bridge::write_page(space_id, page_no, buf, len)
```

在 InnoDB `fil_io()` 中，成功同步磁盘读后会调用 `fil_read_cache::put(page_id, len, buf)`，把页填充到 DSM/read-through cache；后续 Buffer Pool miss 再读同一页时，先尝试 `fil_read_cache::get()`，命中则计入 `runtime_hit`，否则才进入磁盘 I/O 并计入 `disk_read`。

整体访问路径可以概括为：

```text
InnoDB page request
  -> Buffer Pool lookup
      -> hit: record_buf_hit
      -> miss:
          -> fil_io()
              -> fil_read_cache::get()
                  -> DSM hit: record_runtime_hit
                  -> DSM miss:
                      -> shard->do_io()
                      -> record_disk_read
                      -> fil_read_cache::put()
```

## 已验证结果

### 当前实验配置

本轮有效数据来自修正后的容器配置：

```text
Docker container: fenghaibin_restore
Docker ShmSize: 67108864 bytes
/dev/shm inside container: 64MB
DSM_CACHE_BYTES_PER_NODE=16777216
DSM memids=1,2,3
DSM total mapped capacity=48MB
FIL_READ_CACHE_MAX_PAGES=16384
MYSQL_BP_SIZE=5M
COST_BUF_NS=100
COST_DSM_NS=300
COST_DISK_NS=30000
```

此前使用 `DSM_CACHE_BYTES_PER_NODE=134217728`，即每个 DSM 节点 128MB，总计 384MB，已经超过当前容器 `/dev/shm=64MB`。这会导致 mmap 后段写入时触发 `SIGBUS`，表现为 mysqld 在 `fil_read_cache::put()` 中崩溃。当前脚本已经改为每节点 16MB，先保证在现有 Docker 配置下能够完整复现实验。

### TPC-H 完整对照

结果目录：

```text
runs/exp_tpch_retry_16m_20260515_090907/
```

本组使用 SF1 数据，查询集合为 `Q1/Q3/Q6/Q12/Q14/Q19`，重复 2 轮。`NO_DSM` 和 `DSM` 两组均完成装载、查询、PFS 采集和 monitor 汇总，状态均为 `OK`。

查询完成状态：

```text
qid  repeat  status  seconds
1    1       OK      132
3    1       OK      203
6    1       OK      52
12   1       OK      68
14   1       OK      68
19   1       OK      105
1    2       OK      132
3    2       OK      202
6    2       OK      52
12   2       OK      69
14   2       OK      69
19   2       OK      104
```

结果：

```text
case         buf_hit  runtime_hit  runtime_sync  runtime_async  disk_sync  disk_async  wall_time_ns    logical_wall_ns  status
TPCH_no_dsm  8004238  0            0             0              1700301    712924      1247097500521   1247097500521   OK
TPCH_dsm     8003946  11988        661           11327          1714135    701583      1257676063617   1247512689621   OK
```

结论：

```text
TPC-H 的 DSM 组 runtime_hit=11988，其中 runtime_async=11327，说明 DSM 主要命中 read-ahead/async 路径。
disk_async 从 712924 降到 701583，DSM 替代了一部分异步预读磁盘访问。
disk_sync 没有下降，反而从 1700301 增至 1714135；这说明本轮 TPC-H 子集里 DSM 对前台同步缺页帮助有限，主要收益不在同步随机读。
logical_wall_ns 基本持平：1247097500521 -> 1247512689621。
```

### TPC-C 完整对照

结果文件：

```text
runs/exp_tpcc_retry_20260515_085300/summary.tsv
```

本组使用 `1 warehouse / 1 connection / 5s rampup / 60s duration`，并在 `NO_DSM` 和 `DSM` 两个 case 中分别创建独立 datadir、装载数据、运行 workload。两组状态均为 `OK`。

装载后计数：

```text
case         warehouse  district  customer  history  new_orders  orders  item    stock
TPCC_no_dsm  1          10        30000     30000    9000        30000   100000  100000
TPCC_dsm     1          10        30000     30000    9000        30000   100000  100000
```

结果：

```text
case         buf_hit  runtime_hit  runtime_sync  runtime_async  disk_sync  disk_async  wall_time_ns  logical_wall_ns  status
TPCC_no_dsm  72481    0            0             0              13171      2948        65392483518   65392483518     OK
TPCC_dsm     78349    5564         5435          129            9268       2683        65059478124   65277610818     OK
```

结论：

```text
TPC-C 的 NO_DSM 和 DSM 对照已经完整跑通。
DSM 组 runtime_sync=5435，说明部分前台同步磁盘读被 DSM 命中替代。
disk_sync 从 13171 降到 9268，说明一部分前台同步缺页被 DSM 替代。
logical_wall_ns 从 65392483518 降到 65277610818，端到端估算收益较小，原因是本组事务总 wall time 中同步 I/O 只占一部分。
```

### MICRO_SCAN / MICRO_RANDOM_LOOKUP 完整对照

结果文件：

```text
MICRO_SCAN:          runs/exp_micro_scan_retry_20260515_084607/summary.tsv
MICRO_RANDOM_LOOKUP: runs/exp_micro_random_retry_20260515_084941/summary.tsv
```

参数：

```text
MYSQL_BP_SIZE=5M
MICRO_SCAN_HOT_PAGES=1500
MICRO_SCAN_QUERY_REPEATS=6
MICRO_RANDOM_PAGES=1500
MICRO_RANDOM_ROWS_PER_PAGE=4
MICRO_RANDOM_PASSES=6
MICRO_RANDOM_STRIDE=997
DSM_CACHE_BYTES_PER_NODE=16777216
FIL_READ_CACHE_MAX_PAGES=16384
```

结果：

```text
case                         buf_hit  runtime_hit  runtime_sync  runtime_async  disk_sync  disk_async  wall_time_ns  logical_wall_ns  status
MICRO_SCAN_no_dsm            36706    0            0             0              529        14014       4210571233    4210571233     OK
MICRO_SCAN_dsm               36716    5300         247           5053           278        8973        4448001283    4203116333     OK
MICRO_RANDOM_LOOKUP_no_dsm   40745    0            0             0              8227       3           4741977695    4741977695     OK
MICRO_RANDOM_LOOKUP_dsm      40736    6650         6647          3              1571       13          4455968159    4544290895     OK
```

结论：

```text
MICRO_SCAN 中 DSM 主要命中 async/read-ahead 路径，runtime_async 达到 5053，disk_async 从 14014 降到 8973。
MICRO_SCAN 的 logical_wall_ns 从 4210571233 降到 4203116333。
MICRO_RANDOM_LOOKUP 中 DSM 主要命中同步点查路径，disk_sync 从 8227 降到 1571，runtime_sync 增加到 6647。
MICRO_RANDOM_LOOKUP 的 logical_wall_ns 从 4741977695 降到 4544290895。
```

这里 scan/random 之所以比短实验更明显，是因为第 1 轮主要填充 DSM，后续轮次开始复用 DSM。若只跑 1-2 轮，性能提升会被低估。

同理，TPC-C 也应该按“足够容量 + 足够运行时间”测试；当前在 16MB/节点配置下已完成对照，后续若重建更大 `/dev/shm` 容器，可以继续测试 128MB/节点的大 DSM 容量版本。

虽然 `buf_hit` 两组接近，但这是预期现象。随机点查会重复访问 B+Tree 根页和内部页，这些页通常常驻 Buffer Pool。DSM 的作用发生在 Buffer Pool miss 之后，因此应该看 `runtime_sync` 和 `disk_sync` 的变化。

## 正确性观察

已对照 MySQL 8.4 的 `performance_schema.global_status` 做校验，关键关系是：

```text
runtime_sync + runtime_async + disk_sync + disk_async ~= Innodb_pages_read
disk_sync + disk_async ~= Innodb_data_reads
```

TPC-C 完整对照数据：

```text
case         monitor_pages  pfs_pages_read  delta_pages  monitor_disk  pfs_data_reads  delta_disk
TPCC_no_dsm  16119          24259           8140         16119         24309           8190
TPCC_dsm     17515          25745           8230         11951         15773           3822
```

Microbench 数据：

```text
case                         monitor_pages  pfs_pages_read  delta_pages  monitor_disk  pfs_data_reads  delta_disk
MICRO_SCAN_no_dsm            14543          15438           895          14543         15462           919
MICRO_SCAN_dsm               14551          15453           902          9251          9969            718
MICRO_RANDOM_LOOKUP_no_dsm   8230           9129            899          8230          9155            925
MICRO_RANDOM_LOOKUP_dsm      8234           9137            903          1584          2303            719
```

这里不是严格相等，原因是 monitor 当前统计的是我们认为“可 cache/可替换”的 InnoDB 页路径，而 `performance_schema` 的全局状态还包含内部页、系统页、undo/metadata 等额外读。重要的是数量级一致，并且 DSM 组满足：

```text
monitor_pages = runtime_sync + runtime_async + disk_sync + disk_async
monitor_disk = disk_sync + disk_async
```

因此它可以作为估算模型的数据源；如果后续要和 PFS 做逐页严格对齐，需要继续把 monitor 细分到 page type / space id / index level。

## 当前结论

1. DSM monitor 在当前容器配置 `DSM_CACHE_BYTES_PER_NODE=16MB` 下，对 `TPC-H`、`TPC-C`、`MICRO_SCAN` 和 `MICRO_RANDOM_LOOKUP` 均已完成 `NO_DSM` vs `DSM` 对照。

2. 此前的 `SIGBUS` 主要来自 Docker `/dev/shm=64MB` 与 `DSM_CACHE_BYTES_PER_NODE=128MB` 不匹配；当前脚本已改成 16MB/节点，总计 48MB，能在现有容器中稳定运行。

3. 在真实延迟模型下，scan/random microbench 都能清楚显示 DSM 替代磁盘读的收益。

4. `MICRO_SCAN` 更适合观察顺序扫描和 read-ahead 场景，收益主要体现在 `runtime_async` 和 `logical_wall_ns`。

5. `MICRO_RANDOM_LOOKUP` 更适合观察前台同步随机缺页，收益主要体现在 `runtime_sync` 增加、`disk_sync` 减少和 `logical_wall_ns` 下降。

6. TPC-H 已拆成单独脚本 `run_exp_tpch.sh`；当前 16MB/节点配置下，SF1 代表性查询子集已完整跑通，但 DSM 收益主要体现在 async/read-ahead 路径，同步 I/O 时间没有明显改善。

## 后续建议

如果要做“大 DSM 容量”实验，需要用更大的 `--shm-size` 重建 Docker 容器，例如让 `/dev/shm` 至少大于 `3 * DSM_CACHE_BYTES_PER_NODE` 并留出余量。否则 mmap 后段写入会再次触发 SIGBUS。

当前 `TPC-C` 已在 1 warehouse / 1 connection 下跑通；后续可以扩大运行时间、并发和 warehouse 数量，观察事务型 workload 中 DSM 是否能获得更多命中。

对 TPC-H 若需要更全面结论，可以继续扩大到 Q1-Q22，并保留多轮重复查询，避免单次冷扫导致 DSM 只有填充、缺少复用。

如果需要进一步解释 `buf_hit`，可以继续把 monitor 拆成用户叶子页、B+Tree 内部页和元数据页三类。
