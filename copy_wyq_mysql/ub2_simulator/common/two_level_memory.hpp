#ifndef UNIFIED_TWO_LEVEL_MEMORY_HPP
#define UNIFIED_TWO_LEVEL_MEMORY_HPP

#include <cstdint>
#include <cstddef>
#include <vector>
#include <cstring>
#include "memory_location.hpp"

namespace unified_memory {

/**
 * @brief 两级内存抽象配置
 * 
 * 这是 dsm_runtime 的核心优势，可以改进 Midas
 * - Chunk (Extent/Region): 大块内存，如 4MB
 * - Page: 小块内存，如 16KB
 */
struct TwoLevelConfig {
    size_t chunk_size;      // Extent/Region 大小（如 4MB）
    size_t page_size;       // Page 大小（如 16KB）
    size_t pages_per_chunk; // 每个 chunk 包含的 page 数
    
    TwoLevelConfig(size_t cs = 4 * 1024 * 1024, 
                   size_t ps = 16 * 1024)
        : chunk_size(cs), page_size(ps), 
          pages_per_chunk(cs / ps) {
        // 确保配置合理
        if (chunk_size % page_size != 0) {
            throw std::runtime_error("chunk_size must be multiple of page_size");
        }
    }
};

/**
 * @brief Chunk 元数据
 */
struct ChunkMetadata {
    uint32_t space_id;          // 空间 ID（用于隔离不同应用）
    uint32_t start_page_num;    // 起始逻辑页号
    uint32_t used_count;         // 已使用的 page 数量
    uint32_t free_count;         // 空闲的 page 数量
    
    ChunkMetadata() 
        : space_id(0), start_page_num(0), used_count(0), free_count(0) {}
    
    bool is_free() const {
        return used_count == 0;
    }
    
    bool is_full() const {
        return free_count == 0;
    }
};

/**
 * @brief 两级内存管理器
 * 
 * 这是 dsm_runtime 可以提供给 Midas 的核心抽象
 * 优势：
 * 1. 更细粒度的内存管理（16KB vs 可能更大的 Region）
 * 2. 减少内存碎片
 * 3. 更好的内存利用率
 */
template<typename T = uint8_t>
class TwoLevelMemoryManager {
public:
    TwoLevelMemoryManager(void* base_addr, size_t total_size, 
                          const TwoLevelConfig& config)
        : base_addr_(static_cast<uint8_t*>(base_addr))
        , total_size_(total_size)
        , config_(config) {
        // 计算可以容纳多少个 chunk
        max_chunks_ = total_size_ / config_.chunk_size;
        allocated_chunks_ = 0;
        
        // 初始化 chunk 元数据
        chunk_metas_ = std::vector<ChunkMetadata>(max_chunks_);
    }
    
    /**
     * @brief 分配一个 page
     * @param space_id 空间 ID
     * @param page_num 逻辑页号
     * @return 内存位置，如果失败则返回无效位置
     */
    MemoryLocation allocate_page(uint32_t space_id, uint32_t page_num) {
        // 步骤1: 查找是否有 chunk 包含这个 page
        for (uint32_t i = 0; i < allocated_chunks_; i++) {
            ChunkMetadata& meta = chunk_metas_[i];
            
            if (meta.space_id != space_id) continue;
            
            // 计算 chunk 的结束页号
            uint32_t end_page_num = meta.start_page_num + config_.pages_per_chunk - 1;
            
            // 检查当前页是否在这个 chunk 的范围内
            if (meta.start_page_num <= page_num && page_num <= end_page_num) {
                uint32_t page_offset = page_num - meta.start_page_num;
                
                // 检查这个 page 是否已经被分配
                if (page_offset == meta.used_count) {
                    meta.used_count++;
                    meta.free_count--;
                    
                    return MemoryLocation(0, i, page_offset, space_id, 0, 0);
                } else if (page_offset < meta.used_count) {
                    // Page 已经被分配
                    return MemoryLocation(0, i, page_offset, space_id, 0, 0);
                }
            }
        }
        
        // 步骤2: 找一个空闲的 chunk
        for (uint32_t i = 0; i < allocated_chunks_; i++) {
            if (chunk_metas_[i].is_free()) {
                ChunkMetadata& meta = chunk_metas_[i];
                meta.space_id = space_id;
                meta.start_page_num = page_num;
                meta.used_count = 1;
                meta.free_count = config_.pages_per_chunk - 1;
                
                return MemoryLocation(0, i, 0, space_id, 0, 0);
            }
        }
        
        // 步骤3: 分配一个新的 chunk
        if (allocated_chunks_ < max_chunks_) {
            uint32_t chunk_id = allocated_chunks_;
            allocated_chunks_++;
            
            ChunkMetadata& meta = chunk_metas_[chunk_id];
            meta.space_id = space_id;
            meta.start_page_num = page_num;
            meta.used_count = 1;
            meta.free_count = config_.pages_per_chunk - 1;
            
            return MemoryLocation(0, chunk_id, 0, space_id, 0, 0);
        }
        
        // 内存已满
        return MemoryLocation(0, 0, 0);  // 无效位置
    }
    
    /**
     * @brief 获取 page 地址（类型化）
     */
    T* get_page_address(const MemoryLocation& location) {
        void* raw = get_page_address_raw(location);
        return static_cast<T*>(raw);
    }
    
    /**
     * @brief 获取 page 地址（原始字节）
     */
    void* get_page_address_raw(const MemoryLocation& location) {
        if (location.chunk_id >= allocated_chunks_ || 
            location.offset >= config_.pages_per_chunk) {
            return nullptr;
        }
        
        uint8_t* chunk_addr = base_addr_ + (location.chunk_id * config_.chunk_size);
        uint8_t* page_addr = chunk_addr + (location.offset * config_.page_size);
        
        return page_addr;
    }
    
    /**
     * @brief 写入 page 数据
     */
    bool write_page(const MemoryLocation& location, const T* data, size_t count) {
        T* page_addr = get_page_address(location);
        if (page_addr == nullptr) return false;
        
        size_t max_count = config_.page_size / sizeof(T);
        size_t write_count = (count > max_count) ? max_count : count;
        std::memcpy(page_addr, data, write_count * sizeof(T));
        
        return true;
    }
    
    /**
     * @brief 读取 page 数据
     */
    bool read_page(const MemoryLocation& location, T* data, size_t count) {
        T* page_addr = get_page_address(location);
        if (page_addr == nullptr) return false;
        
        size_t max_count = config_.page_size / sizeof(T);
        size_t read_count = (count > max_count) ? max_count : count;
        std::memcpy(data, page_addr, read_count * sizeof(T));
        
        return true;
    }
    
    /**
     * @brief 释放 page（用于回收）
     */
    bool deallocate_page(const MemoryLocation& location) {
        if (location.chunk_id >= allocated_chunks_) return false;
        
        ChunkMetadata& meta = chunk_metas_[location.chunk_id];
        if (location.offset < meta.used_count) {
            // 简化：只减少计数，不实际清理数据
            // 实际实现可能需要更复杂的逻辑
            meta.used_count--;
            meta.free_count++;
            
            // 如果整个 chunk 都空闲了，可以标记为可重用
            if (meta.used_count == 0) {
                meta.space_id = 0;
                meta.start_page_num = 0;
            }
            
            return true;
        }
        
        return false;
    }
    
    /**
     * @brief 获取 chunk 元数据
     */
    ChunkMetadata get_chunk_metadata(uint32_t chunk_id) const {
        if (chunk_id < allocated_chunks_) {
            return chunk_metas_[chunk_id];
        }
        return ChunkMetadata();
    }
    
    /**
     * @brief 获取统计信息
     */
    struct Stats {
        size_t total_chunks;
        size_t allocated_chunks;
        size_t total_pages;
        size_t used_pages;
        size_t free_pages;
    };
    
    Stats get_stats() const {
        Stats stats = {};
        stats.total_chunks = max_chunks_;
        stats.allocated_chunks = allocated_chunks_;
        stats.total_pages = allocated_chunks_ * config_.pages_per_chunk;
        
        for (uint32_t i = 0; i < allocated_chunks_; i++) {
            stats.used_pages += chunk_metas_[i].used_count;
            stats.free_pages += chunk_metas_[i].free_count;
        }
        
        return stats;
    }
    
private:
    uint8_t* base_addr_;
    size_t total_size_;
    TwoLevelConfig config_;
    
    uint32_t max_chunks_;
    uint32_t allocated_chunks_;
    std::vector<ChunkMetadata> chunk_metas_;
};

} // namespace unified_memory

#endif // UNIFIED_TWO_LEVEL_MEMORY_HPP
