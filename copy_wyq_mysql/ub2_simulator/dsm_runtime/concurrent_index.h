#ifndef CONCURRENT_INDEX_H
#define CONCURRENT_INDEX_H

#include <unordered_map>
#include <shared_mutex>
#include <array>
#include <cstddef>
#include <algorithm>
#include <limits>
#include "dsm_types.h"

namespace hw_dsm_runtime {

// 并发安全的页面索引
// 参考 Midas SyncHashMap 的分片锁设计
// 改进：使用 shared_mutex 支持多读并发（类似 DashMap）
// 
// 设计特点：
// 1. 分片锁：将哈希表分成多个分片，每个分片独立加锁
// 2. 多读并发：使用 shared_mutex，读操作可以并发执行
// 3. 写操作保护：写操作使用独占锁，保证数据一致性
// 4. 性能优化：分片数量为 2 的幂，使用位运算替代取模
template <typename K, typename V, size_t NUM_SHARDS = 32>
class ConcurrentPageIndex {
    static_assert(NUM_SHARDS > 0 && (NUM_SHARDS & (NUM_SHARDS - 1)) == 0,
                  "NUM_SHARDS must be a power of 2");

private:
    // 每个分片的数据和锁
    struct Shard {
        mutable std::shared_mutex mutex;  // 使用共享锁，支持多读
        std::unordered_map<K, V> data;
        
        Shard() = default;
        // 禁止拷贝和移动（锁不可拷贝）
        Shard(const Shard&) = delete;
        Shard& operator=(const Shard&) = delete;
        Shard(Shard&&) = delete;
        Shard& operator=(Shard&&) = delete;
    };
    
    std::array<Shard, NUM_SHARDS> shards_;
    
    // 根据 key 选择分片（使用位运算，因为 NUM_SHARDS 是 2 的幂）
    size_t get_shard(const K& key) const {
        std::hash<K> hasher;
        return hasher(key) & (NUM_SHARDS - 1);  // 位运算替代取模，性能更好
    }

public:
    ConcurrentPageIndex() = default;
    ~ConcurrentPageIndex() = default;
    
    // 禁止拷贝和移动
    ConcurrentPageIndex(const ConcurrentPageIndex&) = delete;
    ConcurrentPageIndex& operator=(const ConcurrentPageIndex&) = delete;
    ConcurrentPageIndex(ConcurrentPageIndex&&) = delete;
    ConcurrentPageIndex& operator=(ConcurrentPageIndex&&) = delete;
    
    // 查找（读操作，使用共享锁，支持多读并发）
    bool find(const K& key, V& value) const {
        size_t shard_idx = get_shard(key);
        std::shared_lock<std::shared_mutex> lock(shards_[shard_idx].mutex);
        auto it = shards_[shard_idx].data.find(key);
        if (it != shards_[shard_idx].data.end()) {
            value = it->second;
            return true;
        }
        return false;
    }
    
    // 插入（写操作，使用独占锁）
    void insert(const K& key, const V& value) {
        size_t shard_idx = get_shard(key);
        std::unique_lock<std::shared_mutex> lock(shards_[shard_idx].mutex);
        shards_[shard_idx].data[key] = value;
    }
    
    // 更新（写操作，与 insert 逻辑相同）
    void update(const K& key, const V& value) {
        insert(key, value);
    }
    
    // 删除（写操作）
    bool erase(const K& key) {
        size_t shard_idx = get_shard(key);
        std::unique_lock<std::shared_mutex> lock(shards_[shard_idx].mutex);
        return shards_[shard_idx].data.erase(key) > 0;
    }
    
    // 检查是否存在（读操作）
    bool exists(const K& key) const {
        size_t shard_idx = get_shard(key);
        std::shared_lock<std::shared_mutex> lock(shards_[shard_idx].mutex);
        return shards_[shard_idx].data.find(key) != shards_[shard_idx].data.end();
    }
    
    // 获取大小（需要锁定所有分片）
    size_t size() const {
        size_t total = 0;
        for (const auto& shard : shards_) {
            std::shared_lock<std::shared_mutex> lock(shard.mutex);
            total += shard.data.size();
        }
        return total;
    }
    
    // 清空（需要锁定所有分片）
    void clear() {
        for (auto& shard : shards_) {
            std::unique_lock<std::shared_mutex> lock(shard.mutex);
            shard.data.clear();
        }
    }
    
    // 获取统计信息（用于性能分析和调试）
    struct Stats {
        size_t total_size;
        std::array<size_t, NUM_SHARDS> shard_sizes;
        size_t max_shard_size;
        size_t min_shard_size;
        double avg_shard_size;
        double load_factor;  // 平均负载因子
        
        Stats() : total_size(0), max_shard_size(0), 
                 min_shard_size(std::numeric_limits<size_t>::max()),
                 avg_shard_size(0.0), load_factor(0.0) {}
    };
    
    Stats get_stats() const {
        Stats stats;
        stats.total_size = 0;
        stats.max_shard_size = 0;
        stats.min_shard_size = std::numeric_limits<size_t>::max();
        
        for (size_t i = 0; i < NUM_SHARDS; ++i) {
            std::shared_lock<std::shared_mutex> lock(shards_[i].mutex);
            size_t shard_size = shards_[i].data.size();
            stats.shard_sizes[i] = shard_size;
            stats.total_size += shard_size;
            stats.max_shard_size = std::max(stats.max_shard_size, shard_size);
            stats.min_shard_size = std::min(stats.min_shard_size, shard_size);
        }
        
        if (NUM_SHARDS > 0) {
            stats.avg_shard_size = static_cast<double>(stats.total_size) / NUM_SHARDS;
            // 计算负载因子：最大分片大小 / 平均大小
            if (stats.avg_shard_size > 0) {
                stats.load_factor = static_cast<double>(stats.max_shard_size) / stats.avg_shard_size;
            }
        }
        
        return stats;
    }
    
    // 尝试插入（如果不存在则插入，返回是否成功插入）
    bool try_insert(const K& key, const V& value) {
        size_t shard_idx = get_shard(key);
        std::unique_lock<std::shared_mutex> lock(shards_[shard_idx].mutex);
        auto& data = shards_[shard_idx].data;
        if (data.find(key) == data.end()) {
            data[key] = value;
            return true;
        }
        return false;
    }
    
    // 获取或插入（如果不存在则插入默认值）
    V& get_or_insert(const K& key, const V& default_value) {
        size_t shard_idx = get_shard(key);
        std::unique_lock<std::shared_mutex> lock(shards_[shard_idx].mutex);
        auto& data = shards_[shard_idx].data;
        auto it = data.find(key);
        if (it == data.end()) {
            data[key] = default_value;
            return data[key];
        }
        return it->second;
    }
};

// 类型别名，方便使用
using ConcurrentPageIndexType = ConcurrentPageIndex<page_id_t, extent_location_t, 32>;

} // namespace hw_dsm_runtime

#endif // CONCURRENT_INDEX_H
