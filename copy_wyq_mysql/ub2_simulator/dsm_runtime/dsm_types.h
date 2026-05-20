#ifndef DSM_TYPES_H
#define DSM_TYPES_H

#include <cstdint>
#include "dsm_config.h"

namespace hw_dsm_runtime {

// Page ID 结构：由 space_id 和 page_num 组成
struct page_id_t {
    uint32_t space_id;   // 空间 ID
    uint32_t page_num;   // 页面编号
    
    page_id_t(uint32_t sid = 0, uint32_t pnum = 0) 
        : space_id(sid), page_num(pnum) {}
    
    bool operator==(const page_id_t& other) const {
        return space_id == other.space_id && page_num == other.page_num;
    }
    
    bool operator<(const page_id_t& other) const {
        if (space_id != other.space_id) {
            return space_id < other.space_id;
        }
        return page_num < other.page_num;
    }
};

// Extent 定位信息
struct extent_location_t {
    uint8_t node_id;       // 节点 ID (max 16)
    uint32_t extent_id;    // Extent ID (1TB / 1MB extent)
    uint16_t page_offset;  // 在 extent 中的 page 偏移量 (10MB extent / 16K page)
    
    extent_location_t(uint8_t nid = 0, uint32_t eid = 0, uint16_t offset = 0)
        : node_id(nid), extent_id(eid), page_offset(offset) {}
};

} // namespace hw_dsm_runtime

// 为 std::hash 提供特化，以便 page_id_t 可以作为 unordered_map 的 key
namespace std {
    template<>
    struct hash<hw_dsm_runtime::page_id_t> {
        size_t operator()(const hw_dsm_runtime::page_id_t& pid) const {
            return std::hash<uint32_t>()(pid.space_id) ^ 
                   (std::hash<uint32_t>()(pid.page_num) << 1);
        }
    };
}

#endif // DSM_TYPES_H
