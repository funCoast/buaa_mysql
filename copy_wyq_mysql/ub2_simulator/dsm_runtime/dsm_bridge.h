// dsm_bridge: 供 MySQL / InnoDB fil_read_cache 调用的薄接口。
// 职责：
//  - 在 mysqld 启动阶段，打开由 simulator + export_client 预先留下的
//    /dev/shm/virtual_node0/obmm_shmdev{memid} 共享内存块，
//    通过 mmap 获得远端 DSM 内存视图，注册给内部 runtime。
//  - 提供 read/write/erase 的 page 级接口。失败/未启用时优雅降级。
//
// 环境变量：
//   DSM_BRIDGE_ENABLE          (默认 1) 设为 0 可完全禁用
//   DSM_BRIDGE_SHM_DIR         (默认 /dev/shm/virtual_node0)
//   DSM_BRIDGE_MEMIDS          (默认 "1,2,3") 要打开的 memid 列表
//   DSM_CACHE_BYTES_PER_NODE   (推荐，统一控制 DSM cache size)
//   DSM_BRIDGE_BYTES_PER_NODE  (兼容旧变量；默认 ARRAY_SIZE * sizeof(int), 即 16MB)
//
// 所有接口线程安全、可重入。
#ifndef DSM_BRIDGE_H
#define DSM_BRIDGE_H

#include <cstddef>
#include <cstdint>

namespace dsm_bridge {

// 尝试建立与 DSM 的连接并注册内存。已 setup 过的重复调用是 no-op。
// @return 成功 setup 并且至少注册到一个节点时返回 true；否则返回 false。
bool setup();

// 释放 runtime 和 mmap。幂等。
void teardown();

// setup 是否已成功、可用。
bool is_ready();

// 从 DSM 中读取一个 page。大小必须与之前 put 时一致才能命中。
// @return 命中且拷贝成功返回 true，miss / 未启用返回 false。
bool read_page(uint32_t space_id, uint32_t page_num, void *buf, size_t len);

// 将一个 page 写入 DSM 缓存。
// @return 成功返回 true，未启用/失败返回 false。
bool write_page(uint32_t space_id, uint32_t page_num, const void *buf,
                size_t len);

// 从 DSM 中失效一个 page。未命中 / 未启用皆为 no-op。
void erase_page(uint32_t space_id, uint32_t page_num);

}  // namespace dsm_bridge

#endif  // DSM_BRIDGE_H
