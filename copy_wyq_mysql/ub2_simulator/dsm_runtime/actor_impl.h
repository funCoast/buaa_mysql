#ifndef ACTOR_IMPL_H
#define ACTOR_IMPL_H

#include "actor.h"
#include <cstring>
#include <iostream>

/* 开了 DSM_ACTOR_TRACE 以后，每次 allocate/read/write 都打印一条诊断日志；
   默认关闭，避免在 mysqld 全表扫的 hot path 上把 stdout 写爆。 */
#ifndef DSM_ACTOR_TRACE
#define DSM_ACTOR_TRACE 0
#endif
#if DSM_ACTOR_TRACE
#define DSM_ACTOR_LOG(x) do { x; } while (0)
#else
#define DSM_ACTOR_LOG(x) do {} while (0)
#endif

namespace hw_dsm_runtime {

template <typename T>
node_actor<T>::node_actor(uint8_t node_id, void *base_addr, size_t total_size) 
    : node_id_(node_id), base_addr_(static_cast<uint8_t*>(base_addr)), total_size_(total_size) {
    // 计算可以容纳多少个 extent
    max_extents_ = total_size_ / EXTENT_SIZE;
    allocated_extents_ = 0;
    
    // 初始化 extent 元数据
    extent_metas_ = std::vector<extent_metadata>(max_extents_);
    
    std::cout << "[Actor Node " << static_cast<int>(node_id_) << "] Initialized with " 
              << max_extents_ << " extents (" << total_size_ << " bytes)" << std::endl;
}

template <typename T>
bool node_actor<T>::init() {
    if (base_addr_ == nullptr || total_size_ == 0) {
        std::cerr << "[Actor Node " << static_cast<int>(node_id_) << "] Invalid base address or size" << std::endl;
        return false;
    }
    
    // 内存已经通过 mmap 映射好了，这里只需要初始化数据结构
    std::cout << "[Actor Node " << static_cast<int>(node_id_) << "] Memory initialized" << std::endl;
    return true;
}

template <typename T>
extent_location_t node_actor<T>::allocate_page(uint32_t space_id, uint32_t page_num) {
    // 步骤1: 查找是否有 extent 包含这个 page
    // 条件：extent 的起始页 <= 当前页 < extent 的结束页
    for (uint32_t i = 0; i < allocated_extents_; i++) {
        extent_metadata& meta = extent_metas_[i];
        
        // 检查 space_id 是否匹配
        if (meta.space_id != space_id) {
            continue;
        }
        
        // 计算 extent 的结束页号（起始页 + extent 容量 - 1）
        uint32_t end_page_num = meta.start_page_num + PAGES_PER_EXTENT - 1;
        
        // 检查当前页是否在这个 extent 的范围内
        if (meta.start_page_num <= page_num && page_num <= end_page_num) {
            // 找到匹配的 extent，计算 page_offset
            uint32_t page_offset = page_num - meta.start_page_num;
            
            // 检查这个 page 是否已经被分配
            // 如果 used_count == 0，说明这是一个新的 extent，可以直接使用
            // 如果 page_offset < used_count，说明这个 page 已经被分配
            // 如果 page_offset == used_count，这是下一个要分配的 page
            if (page_offset == meta.used_count) {
                meta.used_count++;

                DSM_ACTOR_LOG(std::cout
                    << "[Actor Node " << static_cast<int>(node_id_)
                    << "] Allocated page (space_id=" << space_id
                    << ", page_num=" << page_num
                    << ") in existing extent " << i
                    << " at offset " << page_offset << std::endl);

                return extent_location_t(node_id_, i, static_cast<uint16_t>(page_offset));
            } else if (page_offset < meta.used_count) {
                DSM_ACTOR_LOG(std::cout
                    << "[Actor Node " << static_cast<int>(node_id_)
                    << "] Page (space_id=" << space_id
                    << ", page_num=" << page_num
                    << ") already allocated in extent " << i
                    << " at offset " << page_offset << std::endl);

                return extent_location_t(node_id_, i, static_cast<uint16_t>(page_offset));
            }
            // page_offset > used_count 的情况不应该发生，因为这是顺序分配
        }
    }
    
    // 步骤2: 如果没找到包含该 page 的 extent，找一个空闲的 extent 并分配
    // 空闲 extent: used_count == 0
    for (uint32_t i = 0; i < allocated_extents_; i++) {
        if (extent_metas_[i].used_count == 0) {
            // 找到空闲 extent，初始化它来存储这个 page
            extent_metadata& meta = extent_metas_[i];
            meta.space_id = space_id;
            meta.start_page_num = page_num;
            meta.used_count = 1;

            DSM_ACTOR_LOG(std::cout
                << "[Actor Node " << static_cast<int>(node_id_)
                << "] Allocated page (space_id=" << space_id
                << ", page_num=" << page_num
                << ") in free extent " << i
                << " (starting at offset 0)" << std::endl);

            return extent_location_t(node_id_, i, 0);
        }
    }
    
    // 步骤3: 如果没有空闲 extent，分配一个新的 extent
    if (allocated_extents_ < max_extents_) {
        uint32_t extent_id = allocated_extents_;
        allocated_extents_++;
        
        extent_metadata& meta = extent_metas_[extent_id];
        meta.space_id = space_id;
        meta.start_page_num = page_num;
        meta.used_count = 1;

        DSM_ACTOR_LOG(std::cout
            << "[Actor Node " << static_cast<int>(node_id_)
            << "] Allocated new extent " << extent_id
            << " for page (space_id=" << space_id
            << ", page_num=" << page_num << ") at offset 0" << std::endl);

        return extent_location_t(node_id_, extent_id, 0);
    }
    
    // 内存已满
    std::cerr << "[Actor Node " << static_cast<int>(node_id_) << "] No available memory" << std::endl;
    return extent_location_t(0, 0, 0); // 无效位置
}

template <typename T>
T* node_actor<T>::get_page_address(uint32_t extent_id, uint16_t page_offset) {
    void* raw_addr = get_page_address_raw(extent_id, page_offset);
    return static_cast<T*>(raw_addr);
}

template <typename T>
void* node_actor<T>::get_page_address_raw(uint32_t extent_id, uint16_t page_offset) {
    if (extent_id >= allocated_extents_ || page_offset >= PAGES_PER_EXTENT) {
        std::cerr << "[Actor Node " << static_cast<int>(node_id_) << "] Invalid extent_id or page_offset" << std::endl;
        return nullptr;
    }
    
    // 计算 page 的地址
    uint8_t* extent_addr = base_addr_ + (extent_id * EXTENT_SIZE);
    uint8_t* page_addr = extent_addr + (page_offset * PAGE_SIZE);
    
    return page_addr;
}

template <typename T>
bool node_actor<T>::write_page(uint32_t extent_id, uint16_t page_offset, const T* data, size_t count) {
    T* page_addr = get_page_address(extent_id, page_offset);
    if (page_addr == nullptr) {
        return false;
    }
    
    size_t max_count = PAGE_SIZE / sizeof(T);
    size_t write_count = (count > max_count) ? max_count : count;
    std::memcpy(page_addr, data, write_count * sizeof(T));

    DSM_ACTOR_LOG(std::cout
        << "[Actor Node " << static_cast<int>(node_id_) << "] Wrote "
        << write_count << " elements to extent " << extent_id
        << ", page " << page_offset << std::endl);

    return true;
}

template <typename T>
bool node_actor<T>::write_page_raw(uint32_t extent_id, uint16_t page_offset, const void* data, size_t size) {
    void* page_addr = get_page_address_raw(extent_id, page_offset);
    if (page_addr == nullptr) {
        return false;
    }

    size_t write_size = (size > PAGE_SIZE) ? PAGE_SIZE : size;
    std::memcpy(page_addr, data, write_size);

    DSM_ACTOR_LOG(std::cout
        << "[Actor Node " << static_cast<int>(node_id_) << "] Wrote "
        << write_size << " bytes to extent " << extent_id
        << ", page " << page_offset << std::endl);

    return true;
}

template <typename T>
bool node_actor<T>::read_page(uint32_t extent_id, uint16_t page_offset, T* data, size_t count) {
    T* page_addr = get_page_address(extent_id, page_offset);
    if (page_addr == nullptr) {
        return false;
    }
    
    size_t max_count = PAGE_SIZE / sizeof(T);
    size_t read_count = (count > max_count) ? max_count : count;
    std::memcpy(data, page_addr, read_count * sizeof(T));

    DSM_ACTOR_LOG(std::cout
        << "[Actor Node " << static_cast<int>(node_id_) << "] Read "
        << read_count << " elements from extent " << extent_id
        << ", page " << page_offset << std::endl);

    return true;
}

template <typename T>
bool node_actor<T>::read_page_raw(uint32_t extent_id, uint16_t page_offset, void* data, size_t size) {
    void* page_addr = get_page_address_raw(extent_id, page_offset);
    if (page_addr == nullptr) {
        return false;
    }

    size_t read_size = (size > PAGE_SIZE) ? PAGE_SIZE : size;
    std::memcpy(data, page_addr, read_size);

    DSM_ACTOR_LOG(std::cout
        << "[Actor Node " << static_cast<int>(node_id_) << "] Read "
        << read_size << " bytes from extent " << extent_id
        << ", page " << page_offset << std::endl);

    return true;
}

template <typename T>
uint8_t node_actor<T>::get_node_id() const {
    return node_id_;
}

template <typename T>
uint32_t node_actor<T>::get_allocated_extents() const {
    return allocated_extents_;
}

} // namespace hw_dsm_runtime

#endif // ACTOR_IMPL_H
