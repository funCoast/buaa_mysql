#include "dis0dis.h"
#include <filesystem>
#include <iostream>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include "buf0types.h"
#include "db0err.h"
#include "fil0fil.h"
#include "os0file.h"
#include "srv0srv.h"
#include "ut0ut.h"

struct page_id_hash {
  size_t operator()(const page_id_t &p) const noexcept {
    return (static_cast<uint64_t>(p.space()) << 32) ^ p.page_no();
  }
};

/** The tablespace memory cache */
class Dis_system {
 public:
  using node_id_t = uint32_t;
  /** Constructor. **/
  Dis_system(node_id_t supernodes, std::string root_dir = "/workspace/mysql_install/runtime_data")
      : supernodes(supernodes),
        local_pages{},
        root_dir_(std::move(root_dir)) {
    // local_pages.insert(page_id_t{0, 3});
    for (auto i = 0; i < supernodes; ++i) {
      local_pages.insert(
          page_id_t{0, static_cast<uint32_t>(4 + i)});  // just for test
    }
  }
  ~Dis_system() = default;

  /** Print the system state. **/
  void _print() const;
  bool lookup_location(const page_id_t &page_id);
  bool _dis_lookup(const IORequest &type, AIO_mode mode, const char *name,
                   void *file_handle, void *buf, os_offset_t offset, ulint n,
                   bool read_only, void *file_msg, void *message,
                   const page_id_t &page_id, node_id_t *node_id,
                   bool *is_local);
  node_id_t dis_hash(page_id_t page_id);

 private:
  node_id_t supernodes;
  std::unordered_set<page_id_t, page_id_hash> local_pages;
  // std::vector<void *> nodes_metadatas; // for container metadata on each node

  Dis_system(Dis_system &&) = delete;
  Dis_system(const Dis_system &) = delete;
  Dis_system &operator=(const Dis_system &) = delete;
  std::string root_dir_;

  struct LockEntry {
    std::shared_mutex m;
  };
  std::mutex locks_mu_;
  std::unordered_map<std::string, std::shared_ptr<LockEntry>> locks_;

  // 3) 构建路径：/root/space_<sid>/page_<pageno>.bin
  std::string build_path(const page_id_t &pid) const {
    // 也可以按 extent 建目录：extent_no = pid.page_no()/FSP_EXTENT_SIZE
    std::filesystem::path p(root_dir_);
    p /= ("space_" + std::to_string(pid.space()));
    p /= ("page_" + std::to_string(pid.page_no()) + ".bin");
    return p.string();
  }

  std::shared_ptr<LockEntry> get_lock(const std::string &path) {
    std::lock_guard<std::mutex> g(locks_mu_);
    auto it = locks_.find(path);
    if (it != locks_.end()) return it->second;
    auto e = std::make_shared<LockEntry>();
    locks_.emplace(path, e);
    return e;
  }
  class FileGuard {
   public:
    FileGuard(std::shared_ptr<LockEntry> e, bool write) : entry_(std::move(e)) {
      if (write) {
        wlock_.emplace(entry_->m);
      } else {
        rlock_.emplace(entry_->m);
      }
    }

   private:
    std::shared_ptr<LockEntry> entry_;
    std::optional<std::unique_lock<std::shared_mutex>> wlock_;
    std::optional<std::shared_lock<std::shared_mutex>> rlock_;
  };
};

static Dis_system *dis_system = nullptr;

void Dis_system::_print() const {
  // std::cout << "Dis_system nodes:";
  // for (auto page_info : local_pages) {
  //   std::cout << ' ' << page_info;
  // }
  // std::cout << std::endl;
}

static inline uint64_t dis_mix64(uint64_t x) {
  // SplitMix64 finalizer
  x += 0x9e3779b97f4a7c15ULL;
  x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
  x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
  return x ^ (x >> 31);
}
// node_id_t Dis_system::dis_hash(page_id_t page_id) {
//   const uint64_t extent_no =
//       static_cast<uint64_t>(page_id.page_no()) / FSP_EXTENT_SIZE;

//   // key = (space_id, extent_no)
//   // 组合成 64-bit，再做一次强混合，避免 % supernodes 时出现偏斜
//   uint64_t key = (static_cast<uint64_t>(page_id.space()) << 32) ^ extent_no;

//   const uint64_t h = dis_mix64(key);
//   return static_cast<node_id_t>(h % supernodes);
// }

// bool Dis_system::lookup_location(const page_id_t &page_id) {
//   node_id_t target_node = dis_hash(page_id);
//   // TODO: just read the page metadata container info on remote node
//   void *remote_base =
//   static_cast<unordered_set>(nodes_metadatas[target_node]); uint64_t h =
//       (static_cast<uint64_t>(page_id.space()) << 32) ^ page_id.page_no();
//   uint32_t target = static_cast<uint32_t>(h % nodes_.size());

//   if (node_id) {
//     *node_id = target;
//   }
//   // TODO: 通过 RPC 向 target 查询远端页首地址；占位返回 0
//   if (remote_base) {
//     *remote_base = 0;
//   }
//   return true;
// }

// bool Dis_system::_dis_lookup(IORequest &req_type, AIO_mode aio_mode,
//                              const char *name, fil_node_t *file, void *buf,
//                              os_offset_t offset, ulint len, bool read_only,
//                              void *file_msg, void *message,
//                              const page_id_t &page_id) {
//   /* for now, when step into this func, the page isn't possible to be local
//   */
//   // TODO: loopup the page location: Disk/SHM
//   dberr_t err = DB_SUCCESS;
//   bool is_shm = lookup_location(page_id);

//   if (is_shm) {
//     if (req_type.is_read()) {
//       // TODO: memcpy
//     } else if (req_type.is_write()) {
//       // TODO: RPC
//     }

//   } else {
//     err = os_aio(
//         req_type, aio_mode, file->name, file->handle, buf, offset, len,
//         fsp_is_system_temporary(page_id.space()) ? false :
//         srv_read_only_mode, file, message);
//   }

//   return err;
// }

void dis_runtime_init() {
  ut_a(dis_system == nullptr);
  // TODO: HPX runtime or other RPC way to init the distributed system
  /*
    Process in other nodes:
      1. init the metadata container like set of pages.
      2. register the node to the master node(IP, port or other info for heart
      3. return to the master node of the container start address to fill the
         nodes_metadatas
    beat).
  */
  dis_system = ut::new_withkey<Dis_system>(UT_NEW_THIS_FILE_PSI_KEY, 48);
}

void dis_runtime_print() {
  // TODO: Print the distributed system state.
  if (dis_system != nullptr) {
    dis_system->_print();
  }
}

// bool dis_lookup(const IORequest &type, AIO_mode mode, const char *name,
//                 void *file_handle, void *buf, os_offset_t offset, ulint n,
//                 bool read_only, void *file_msg, void *message,
//                 const page_id_t &page_id, uint32_t *node_id, bool *is_local)
//                 {
//   ut_a(dis_system == nullptr);
//   return dis_system->_dis_lookup(type, mode, name, file_handle, buf, offset,
//   n,
//                                  read_only, file_msg, message, page_id,
//                                  node_id, is_local);
// }
bool Dis_system::_dis_lookup(const IORequest &type, AIO_mode mode,
                             const char *name, void *file_handle, void *buf,
                             os_offset_t offset, ulint n, bool read_only,
                             void *file_msg, void *message,
                             const page_id_t &page_id, node_id_t *node_id,
                             bool *is_local) {
  // 1) 构建该 page 对应的文件路径
  const std::string path = build_path(page_id);

  // 2) 获取该路径对应的锁，并按读/写上锁
  const bool is_write = type.is_write();              // 写：独占锁
  FileGuard guard(get_lock(path), /*write=*/is_write);

  // 3) 这里开始就保证了同一 path 的并发访问满足你的锁语义
  //    你可以选择：
  //    - 文件存在就从文件读/写
  //    - 不存在则 fall back 到 os_aio / shm / rpc 等

  // 例：确保目录存在（生产环境要注意：mkdir 也可能需要锁，但我们锁已持有）
  std::filesystem::create_directories(std::filesystem::path(path).parent_path());

  if (type.is_read()) {
    // TODO: 从 path 读入 buf（offset, n）
    // 比如用 os_file_read / std::ifstream / pread 等
    // 注意 InnoDB 通常需要对齐/错误码转换为 dberr_t
  } else if (type.is_write()) {
    // TODO: 写 buf 到 path（offset, n）
    // 比如用 os_file_write / std::ofstream / pwrite 等
  }

  // 4) 离开作用域自动释放锁（guard 析构）
  return true;
}