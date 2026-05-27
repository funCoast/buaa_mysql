#include "runtime.h"

#include <iostream>

namespace hw_dsm_runtime {

void runtime::register_memory(uint8_t node_id, void *mapped_addr, size_t size) {
  std::unique_lock<std::shared_mutex> l(mu_);
  auto actor = std::make_shared<byte_actor_t>(node_id, mapped_addr, size);
  if (!actor->init()) {
    std::cerr << "[dsm_runtime] Failed to init actor for node "
              << static_cast<int>(node_id) << std::endl;
    return;
  }
  actors_[node_id] = actor;
}

bool runtime::write_page(const page_id_t &page_id, const void *data,
                         size_t size) {
  std::unique_lock<std::shared_mutex> l(mu_);
  if (actors_.empty()) {
    return false;
  }

  extent_location_t location;
  if (!index_.find(page_id, location)) {
    /* 连续 page_num -> 连续 actor：actor 内的 allocate_page 要求同一 extent
       里的 page_num 严格连续、每次 +1。如果我们用 page_num % actors 轮询，
       每个 actor 看到的 page_num 步长就是 actors_.size()，永远进不去同一
       extent，每页都会浪费整整一个 extent。这里改成按 actor 顺序依次尝试：
       先把 actor0 填满，再填 actor1，再填 actor2。 */
    bool allocated = false;
    for (auto &kv : actors_) {
      auto actor = kv.second;
      auto loc = actor->allocate_page(page_id.space_id, page_id.page_num);
      /* 失败判定：node_id==0 且当前 actor 的 node_id!=0 说明真的失败。
         注意 actor 自己可能正好是 node_id==0（本地单机场景），此时无法区分
         成功返回 (0,0,0) 与失败返回 (0,0,0)。我们的 dsm_bridge 默认用 node_id
         ∈ {1,2,3}，所以这里不会误判。 */
      if (loc.node_id == 0 && actor->get_node_id() != 0) {
        continue;  // 这个 actor 满了，换下一个
      }
      location = loc;
      allocated = true;
      break;
    }
    if (!allocated) return false;
    index_.insert(page_id, location);
  }

  auto it = actors_.find(location.node_id);
  if (it == actors_.end()) return false;
  return it->second->write_page_raw(location.extent_id, location.page_offset,
                                    data, size);
}

bool runtime::read_page(const page_id_t &page_id, void *data, size_t size) {
  std::shared_lock<std::shared_mutex> l(mu_);
  extent_location_t location;
  if (!index_.find(page_id, location)) {
    return false;
  }
  auto it = actors_.find(location.node_id);
  if (it == actors_.end()) return false;
  return it->second->read_page_raw(location.extent_id, location.page_offset,
                                   data, size);
}

void runtime::erase_page(const page_id_t &page_id) {
  std::unique_lock<std::shared_mutex> l(mu_);
  index_.erase(page_id);
  // 注意：底层 extent 的存储不会被回收（runtime 是追加分配模式）。
  // 这里只是从索引里剔除，下次读同一个 page 会视作 miss。
}

}  // namespace hw_dsm_runtime
