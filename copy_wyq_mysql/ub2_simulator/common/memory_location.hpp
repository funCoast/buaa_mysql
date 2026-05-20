#ifndef UNIFIED_MEMORY_LOCATION_HPP
#define UNIFIED_MEMORY_LOCATION_HPP

#include <cstdint>
#include <cstddef>

namespace unified_memory {

/**
 * @brief 统一的内存定位信息
 * 
 * 这是 dsm_runtime 和 Midas 共享的核心抽象
 * 用于表示内存在系统中的位置
 */
struct MemoryLocation {
    // 节点/进程标识
    // dsm_runtime: node_id (0-15)
    // Midas: process_id
    uint32_t node_or_process_id;
    
    // 大块内存标识
    // dsm_runtime: extent_id (4MB chunks)
    // Midas: region_id
    uint32_t chunk_id;
    
    // 小块内存偏移
    // dsm_runtime: page_offset (16KB pages within extent)
    // Midas: offset_in_region
    uint32_t offset;
    
    // 可选的元数据
    struct Metadata {
        uint32_t space_id;      // dsm_runtime 的 space_id
        uint64_t timestamp;      // 分配时间戳
        uint32_t flags;          // 标志位（如延迟关键、只读等）
        
        Metadata() : space_id(0), timestamp(0), flags(0) {}
    } metadata;
    
    MemoryLocation(uint32_t nid = 0, uint32_t cid = 0, uint32_t off = 0)
        : node_or_process_id(nid), chunk_id(cid), offset(off) {}
    
    MemoryLocation(uint32_t nid, uint32_t cid, uint32_t off, 
                   uint32_t space_id, uint64_t ts, uint32_t f)
        : node_or_process_id(nid), chunk_id(cid), offset(off) {
        metadata.space_id = space_id;
        metadata.timestamp = ts;
        metadata.flags = f;
    }
    
    bool operator==(const MemoryLocation& other) const {
        return node_or_process_id == other.node_or_process_id &&
               chunk_id == other.chunk_id &&
               offset == other.offset;
    }
    
    bool operator<(const MemoryLocation& other) const {
        if (node_or_process_id != other.node_or_process_id) {
            return node_or_process_id < other.node_or_process_id;
        }
        if (chunk_id != other.chunk_id) {
            return chunk_id < other.chunk_id;
        }
        return offset < other.offset;
    }
    
    // 检查是否为有效位置
    bool is_valid() const {
        return node_or_process_id != 0 || chunk_id != 0 || offset != 0;
    }
    
    // 获取完整地址（需要配合 base_addr 使用）
    void* compute_address(void* base_addr, size_t chunk_size, size_t page_size) const {
        if (!is_valid()) return nullptr;
        
        uint8_t* base = static_cast<uint8_t*>(base_addr);
        uint8_t* chunk_addr = base + (chunk_id * chunk_size);
        uint8_t* page_addr = chunk_addr + (offset * page_size);
        
        return page_addr;
    }
};

} // namespace unified_memory

// 为 std::hash 提供特化
namespace std {
    template<>
    struct hash<unified_memory::MemoryLocation> {
        size_t operator()(const unified_memory::MemoryLocation& loc) const {
            return hash<uint32_t>()(loc.node_or_process_id) ^
                   (hash<uint32_t>()(loc.chunk_id) << 1) ^
                   (hash<uint32_t>()(loc.offset) << 2);
        }
    };
}

#endif // UNIFIED_MEMORY_LOCATION_HPP
