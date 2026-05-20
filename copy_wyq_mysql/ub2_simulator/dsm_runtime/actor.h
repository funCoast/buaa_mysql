#ifndef ACTOR_H
#define ACTOR_H

#include <cstdint>
#include <vector>
#include "dsm_config.h"
#include "dsm_types.h"

namespace hw_dsm_runtime {

// 每个 actor 维护一个节点上的内存，两级抽象：extent(4MB) 和 page(16KB)
template <typename T>
class node_actor {
public:
    node_actor(uint8_t node_id, void *base_addr, size_t total_size);
    
    // 初始化 actor
    bool init();
    
    // 分配一个 page，返回 extent 位置信息
    extent_location_t allocate_page(uint32_t space_id, uint32_t page_num);
    
    // 根据 extent_id 和 page_offset 获取 page 地址（返回 T* 类型指针）
    T* get_page_address(uint32_t extent_id, uint16_t page_offset);
    
    // 根据 extent_id 和 page_offset 获取原始字节地址
    void* get_page_address_raw(uint32_t extent_id, uint16_t page_offset);
    
    // 写入 page 数据（写入 T 类型数组）
    bool write_page(uint32_t extent_id, uint16_t page_offset, const T* data, size_t count);
    
    // 写入 page 数据（原始字节版本）
    bool write_page_raw(uint32_t extent_id, uint16_t page_offset, const void* data, size_t size);
    
    // 读取 page 数据（读取到 T 类型数组）
    bool read_page(uint32_t extent_id, uint16_t page_offset, T* data, size_t count);
    
    // 读取 page 数据（原始字节版本）
    bool read_page_raw(uint32_t extent_id, uint16_t page_offset, void* data, size_t size);
    
    uint8_t get_node_id() const;
    uint32_t get_allocated_extents() const;

private:
    // Extent 元数据：记录每个 extent 存储的逻辑页范围
    struct extent_metadata {
        uint32_t space_id;          // 存储的 space_id
        uint32_t start_page_num;    // 起始逻辑页号
        uint32_t used_count;        // 已使用的 page 数量
        
        extent_metadata() : space_id(0), start_page_num(0), used_count(0) {}
    };
    
    uint8_t node_id_;               // 节点 ID (最大16)
    uint8_t* base_addr_;            // 基地址
    size_t total_size_;             // 总大小
    uint32_t max_extents_;          // 最大 extent 数量
    uint32_t allocated_extents_;    // 已分配的 extent 数量
    std::vector<extent_metadata> extent_metas_;  // 每个 extent 的元数据
};

} // namespace hw_dsm_runtime

// 模板实现必须在头文件中
#include "actor_impl.h"

#endif // ACTOR_H
