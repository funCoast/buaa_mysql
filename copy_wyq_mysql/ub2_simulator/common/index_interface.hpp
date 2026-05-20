#ifndef UNIFIED_INDEX_INTERFACE_HPP
#define UNIFIED_INDEX_INTERFACE_HPP

#include <cstddef>
#include <unordered_map>
#include <shared_mutex>
#include <array>

namespace unified_memory {

/**
 * @brief 通用的索引接口
 * 
 * 这是 dsm_runtime 和 Midas 共享的核心抽象
 * 提供 Key -> Location 的映射功能
 */
template<typename Key, typename Location>
class Index {
public:
    virtual ~Index() = default;
    
    /**
     * @brief 插入或更新索引项
     * @param key 键
     * @param location 内存位置
     */
    virtual void insert(const Key& key, const Location& location) = 0;
    
    /**
     * @brief 查找索引项
     * @param key 键
     * @param location 输出参数，找到的位置
     * @return 是否找到
     */
    virtual bool find(const Key& key, Location& location) const = 0;
    
    /**
     * @brief 删除索引项
     * @param key 键
     */
    virtual void erase(const Key& key) = 0;
    
    /**
     * @brief 检查键是否存在
     * @param key 键
     * @return 是否存在
     */
    virtual bool exists(const Key& key) const = 0;
    
    /**
     * @brief 获取索引大小
     * @return 索引项数量
     */
    virtual size_t size() const = 0;
    
    /**
     * @brief 清空索引
     */
    virtual void clear() = 0;
    
    /**
     * @brief 更新索引项
     * @param key 键
     * @param location 新的位置
     */
    virtual void update(const Key& key, const Location& location) {
        insert(key, location);  // 默认实现
    }
};

/**
 * @brief 简单的单线程索引实现（基于 std::unordered_map）
 * 
 * 适用于单线程场景或已经有外部同步的场景
 */
template<typename Key, typename Location>
class SimpleIndex : public Index<Key, Location> {
private:
    std::unordered_map<Key, Location> index_;
    
public:
    void insert(const Key& key, const Location& location) override {
        index_[key] = location;
    }
    
    bool find(const Key& key, Location& location) const override {
        auto it = index_.find(key);
        if (it != index_.end()) {
            location = it->second;
            return true;
        }
        return false;
    }
    
    void erase(const Key& key) override {
        index_.erase(key);
    }
    
    bool exists(const Key& key) const override {
        return index_.find(key) != index_.end();
    }
    
    size_t size() const override {
        return index_.size();
    }
    
    void clear() override {
        index_.clear();
    }
};

/**
 * @brief 并发安全的索引实现（使用分片锁）
 * 
 * 这是 dsm_runtime 可以改进 Midas 的地方：
 * - 使用分片锁提高并发性能
 * - 读操作使用共享锁，写操作使用独占锁
 * - 适合高并发场景
 */
template<typename Key, typename Location>
class ConcurrentIndex : public Index<Key, Location> {
private:
    static constexpr size_t NUM_SHARDS = 16;
    
    struct Shard {
        mutable std::shared_mutex mutex;
        std::unordered_map<Key, Location> map;
    };
    
    std::array<Shard, NUM_SHARDS> shards_;
    
    size_t get_shard(const Key& key) const {
        return std::hash<Key>()(key) % NUM_SHARDS;
    }
    
public:
    void insert(const Key& key, const Location& location) override {
        size_t shard = get_shard(key);
        std::unique_lock<std::shared_mutex> lock(shards_[shard].mutex);
        shards_[shard].map[key] = location;
    }
    
    bool find(const Key& key, Location& location) const override {
        size_t shard = get_shard(key);
        std::shared_lock<std::shared_mutex> lock(shards_[shard].mutex);
        auto it = shards_[shard].map.find(key);
        if (it != shards_[shard].map.end()) {
            location = it->second;
            return true;
        }
        return false;
    }
    
    void erase(const Key& key) override {
        size_t shard = get_shard(key);
        std::unique_lock<std::shared_mutex> lock(shards_[shard].mutex);
        shards_[shard].map.erase(key);
    }
    
    bool exists(const Key& key) const override {
        size_t shard = get_shard(key);
        std::shared_lock<std::shared_mutex> lock(shards_[shard].mutex);
        return shards_[shard].map.find(key) != shards_[shard].map.end();
    }
    
    size_t size() const override {
        size_t total = 0;
        for (auto& shard : shards_) {
            std::shared_lock<std::shared_mutex> lock(shard.mutex);
            total += shard.map.size();
        }
        return total;
    }
    
    void clear() override {
        for (auto& shard : shards_) {
            std::unique_lock<std::shared_mutex> lock(shard.mutex);
            shard.map.clear();
        }
    }
};

} // namespace unified_memory

#endif // UNIFIED_INDEX_INTERFACE_HPP
