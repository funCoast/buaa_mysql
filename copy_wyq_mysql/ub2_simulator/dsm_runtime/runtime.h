#ifndef HW_DSM_RUNTIME_H
#define HW_DSM_RUNTIME_H

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <shared_mutex>

#include "actor.h"
#include "dsm_config.h"
#include "dsm_types.h"
#include "index.h"

namespace hw_dsm_runtime {

// 独立可链接的 runtime：从 init.cpp 里抽出的 class runtime，添加全局锁
// 保证并发读写安全。可被 MySQL 之类的多线程宿主进程直接调用。
class runtime {
public:
  using byte_actor_t = node_actor<uint8_t>;
  using page_index_t = page_index<page_id_t, extent_location_t>;

  runtime() = default;
  ~runtime() = default;

  runtime(const runtime &) = delete;
  runtime &operator=(const runtime &) = delete;

  // 注册一个节点的内存（由调用方 mmap 远端共享内存后传入）
  void register_memory(uint8_t node_id, void *mapped_addr, size_t size);

  // 写入/读取/擦除 page（线程安全）
  bool write_page(const page_id_t &page_id, const void *data, size_t size);
  bool read_page(const page_id_t &page_id, void *data, size_t size);
  void erase_page(const page_id_t &page_id);

  size_t index_size() const {
    std::shared_lock<std::shared_timed_mutex> l(mu_);
    return index_.size();
  }
  size_t node_count() const {
    std::shared_lock<std::shared_timed_mutex> l(mu_);
    return actors_.size();
  }

private:
  mutable std::shared_timed_mutex mu_;
  std::map<uint8_t, std::shared_ptr<byte_actor_t>> actors_;
  page_index_t index_;
};

}  // namespace hw_dsm_runtime

#endif  // HW_DSM_RUNTIME_H
