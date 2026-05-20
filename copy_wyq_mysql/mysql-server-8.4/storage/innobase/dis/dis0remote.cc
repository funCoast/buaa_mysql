
#include <cstdint>
#include <atomic>

using dis_off_t = uint64_t;
struct alignas(64) DisMetaHeader {
  uint64_t magic;
  uint32_t version;
  uint32_t extent_size;     // 64
  uint32_t space_dir_slots; // space_dir 数组长度（可用 max_space_id+1 或 hash slots）
  uint32_t reserved;
  dis_off_t space_dir_off;  // SpaceEntry[] 偏移
};

struct alignas(32) SpaceEntry {
  std::atomic<uint64_t> seq;     // seqlock，读一致性
  uint32_t space_id;
  uint32_t flags;               // present / dropped / etc
  uint64_t extent_count;
  dis_off_t extent_table_off;    // DisExtentEntry[] 偏移
};

struct alignas(64) DisExtentEntry {
  std::atomic<uint64_t> seq;     // 可选：若 space_entry 已保护，也可不要
  std::atomic<uint64_t> bitmap;  // 64 页存在性
};