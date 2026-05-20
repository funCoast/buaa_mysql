#include "dsm_bridge.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "dsm_config.h"
#include "dsm_types.h"
#include "runtime.h"

namespace dsm_bridge {

namespace {

struct MappedRegion {
  void *addr = nullptr;
  size_t size = 0;
};

std::mutex g_init_mu;
std::atomic<bool> g_ready{false};
std::atomic<bool> g_tried{false};
std::unique_ptr<hw_dsm_runtime::runtime> g_rt;
std::vector<MappedRegion> g_regions;

/* --- Page-id 虚拟化层 -------------------------------------------------------
 * dsm_runtime 的 allocate_page 要求同 extent 内 page_num 必须从 0 开始严格
 * 连续自增；而 MySQL 页号是稀疏/乱序的。为了让 runtime 能线性铺满 extent，
 * dsm_bridge 把 (space_id, page_num) 映射成一个全局单调自增的虚拟 page_num，
 * 并把所有写都归一到 space_id=0，这样 runtime 内部从零开始顺序分配。
 *
 * 索引是 dsm_bridge 自己持有的，不依赖 runtime 的 index_；这也意味着
 * mysqld 进程重启后整个映射会失效（预期行为，与 L2 缓存语义一致）。
 * ---------------------------------------------------------------------------*/
std::mutex g_id_mu;
std::unordered_map<uint64_t, uint32_t> g_id_to_vpage;
uint32_t g_next_vpage = 0;
uint32_t g_vpage_capacity = 0;

inline uint64_t make_key(uint32_t space_id, uint32_t page_num) {
  return (static_cast<uint64_t>(space_id) << 32) | page_num;
}

const char *env_or(const char *key, const char *dflt) {
  const char *v = std::getenv(key);
  return (v && *v) ? v : dflt;
}

uint64_t env_u64_prefer(const char *primary, const char *secondary,
                        uint64_t dflt) {
  const char *v = std::getenv(primary);
  if (!(v && *v) && secondary != nullptr) {
    v = std::getenv(secondary);
  }
  if (!(v && *v)) {
    return dflt;
  }
  char *end = nullptr;
  errno = 0;
  const auto parsed = std::strtoull(v, &end, 10);
  if (errno != 0 || end == v || (end != nullptr && *end != '\0')) {
    return dflt;
  }
  return static_cast<uint64_t>(parsed);
}

std::vector<int> parse_memids(const std::string &s) {
  std::vector<int> out;
  std::string cur;
  for (char c : s) {
    if (c == ',' || c == ' ') {
      if (!cur.empty()) {
        out.push_back(std::atoi(cur.c_str()));
        cur.clear();
      }
    } else {
      cur.push_back(c);
    }
  }
  if (!cur.empty()) out.push_back(std::atoi(cur.c_str()));
  return out;
}

bool do_setup_unlocked() {
  const char *enable = env_or("DSM_BRIDGE_ENABLE", "1");
  if (enable[0] == '0') {
    std::cerr << "[dsm_bridge] disabled by DSM_BRIDGE_ENABLE=0\n";
    return false;
  }

  const std::string shm_dir = env_or("DSM_BRIDGE_SHM_DIR",
                                     "/dev/shm/virtual_node0");
  const std::string memids_env = env_or("DSM_BRIDGE_MEMIDS", "1,2,3");
  const std::vector<int> memids = parse_memids(memids_env);
  if (memids.empty()) {
    std::cerr << "[dsm_bridge] empty memid list\n";
    return false;
  }

  size_t bytes_per_node = static_cast<size_t>(env_u64_prefer(
      "DSM_CACHE_BYTES_PER_NODE", "DSM_BRIDGE_BYTES_PER_NODE",
      static_cast<uint64_t>(ARRAY_SIZE) * sizeof(int)));

  auto rt = std::make_unique<hw_dsm_runtime::runtime>();
  std::vector<MappedRegion> regions;

  int mapped = 0;
  for (int memid : memids) {
    char path[512];
    std::snprintf(path, sizeof(path), "%s/obmm_shmdev%d", shm_dir.c_str(),
                  memid);

    int fd = ::open(path, O_RDWR);
    if (fd < 0) {
      std::cerr << "[dsm_bridge] open(" << path
                << ") failed: " << std::strerror(errno) << "\n";
      continue;
    }

    // 若文件大小小于预期，就按实际大小映射
    struct stat st{};
    size_t map_size = bytes_per_node;
    if (::fstat(fd, &st) == 0 && st.st_size > 0 &&
        static_cast<size_t>(st.st_size) < map_size) {
      map_size = static_cast<size_t>(st.st_size);
    }

    void *addr = ::mmap(nullptr, map_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                        fd, 0);
    ::close(fd);
    if (addr == MAP_FAILED) {
      std::cerr << "[dsm_bridge] mmap(" << path
                << ") failed: " << std::strerror(errno) << "\n";
      continue;
    }

    // memid 映射到 node_id：简单起见用 memid 自身（≥1）作为 node_id
    const uint8_t node_id = static_cast<uint8_t>(memid);
    rt->register_memory(node_id, addr, map_size);
    regions.push_back({addr, map_size});
    ++mapped;

    std::cerr << "[dsm_bridge] mapped " << path << " -> node_id=" << memid
              << ", size=" << map_size << "\n";
  }

  if (mapped == 0) {
    std::cerr << "[dsm_bridge] no shm segments mapped; DSM disabled.\n"
              << "  Make sure simulator and export_client are running and the "
                 "shm files exist under DSM_BRIDGE_SHM_DIR.\n";
    return false;
  }

  g_rt = std::move(rt);
  g_regions = std::move(regions);

  // 容量 = sum(map_size) / EXTENT_SIZE * PAGES_PER_EXTENT
  size_t total_bytes = 0;
  for (const auto &r : g_regions) total_bytes += r.size;
  g_vpage_capacity = static_cast<uint32_t>(
      (total_bytes / EXTENT_SIZE) * PAGES_PER_EXTENT);
  {
    std::lock_guard<std::mutex> l(g_id_mu);
    g_id_to_vpage.clear();
    g_next_vpage = 0;
  }

  g_ready.store(true, std::memory_order_release);
  std::cerr << "[dsm_bridge] ready (nodes=" << mapped
            << ", vpage_capacity=" << g_vpage_capacity << ")\n";
  return true;
}

}  // namespace

bool setup() {
  std::lock_guard<std::mutex> lock(g_init_mu);
  if (g_ready.load(std::memory_order_acquire)) return true;
  if (g_tried.exchange(true)) {
    // 已经试过但没 ready，不再重复尝试
    return g_ready.load(std::memory_order_acquire);
  }
  return do_setup_unlocked();
}

void teardown() {
  std::lock_guard<std::mutex> lock(g_init_mu);
  if (!g_ready.load(std::memory_order_acquire) && !g_rt) {
    return;
  }
  g_rt.reset();
  for (auto &r : g_regions) {
    if (r.addr && r.addr != MAP_FAILED) {
      ::munmap(r.addr, r.size);
    }
  }
  g_regions.clear();
  {
    std::lock_guard<std::mutex> l(g_id_mu);
    g_id_to_vpage.clear();
    g_next_vpage = 0;
    g_vpage_capacity = 0;
  }
  g_ready.store(false, std::memory_order_release);
  g_tried.store(false, std::memory_order_release);
}

bool is_ready() { return g_ready.load(std::memory_order_acquire); }

/* 返回是否有映射；若 allocate=true 且当前没有映射，则尝试分配一个新的 vpage。 */
static bool lookup_or_allocate(uint32_t space_id, uint32_t page_num,
                               bool allocate, uint32_t *out_vpage) {
  uint64_t key = make_key(space_id, page_num);
  std::lock_guard<std::mutex> l(g_id_mu);
  auto it = g_id_to_vpage.find(key);
  if (it != g_id_to_vpage.end()) {
    *out_vpage = it->second;
    return true;
  }
  if (!allocate) return false;
  if (g_next_vpage >= g_vpage_capacity) {
    return false;  // DSM full
  }
  uint32_t v = g_next_vpage++;
  g_id_to_vpage.emplace(key, v);
  *out_vpage = v;
  return true;
}

bool read_page(uint32_t space_id, uint32_t page_num, void *buf, size_t len) {
  if (!g_ready.load(std::memory_order_acquire) || !g_rt) return false;
  uint32_t vpage;
  if (!lookup_or_allocate(space_id, page_num, false, &vpage)) return false;
  hw_dsm_runtime::page_id_t pid(0u, vpage);
  return g_rt->read_page(pid, buf, len);
}

bool write_page(uint32_t space_id, uint32_t page_num, const void *buf,
                size_t len) {
  if (!g_ready.load(std::memory_order_acquire) || !g_rt) return false;
  uint32_t vpage;
  if (!lookup_or_allocate(space_id, page_num, true, &vpage)) return false;
  hw_dsm_runtime::page_id_t pid(0u, vpage);
  return g_rt->write_page(pid, buf, len);
}

void erase_page(uint32_t space_id, uint32_t page_num) {
  if (!g_ready.load(std::memory_order_acquire) || !g_rt) return;
  uint32_t vpage;
  if (!lookup_or_allocate(space_id, page_num, false, &vpage)) return;
  // 仅从 runtime 索引中剔除；vpage 槽位暂不回收（DSM capacity 够一次全表装下）。
  hw_dsm_runtime::page_id_t pid(0u, vpage);
  g_rt->erase_page(pid);
}

}  // namespace dsm_bridge
