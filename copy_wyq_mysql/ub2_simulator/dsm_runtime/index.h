#ifndef INDEX_H
#define INDEX_H

#include <unordered_map>
#include <array>
#include <cstdint>
#include <shared_mutex>
#include <mutex>

namespace hw_dsm_runtime {

// 索引系统：通用键值映射
// K: 键类型（如 page_id_t）
// V: 值类型（如 extent_location_t）
//
// 未来参考 DashMap：
// 1. 添加并发支持：在实现内部添加分片锁（shard locks）
//    - 按 hash(key) % num_shards 选择 shard
//    - 每个 shard 使用独立的锁（std::shared_mutex）
//    - 读操作使用共享锁，写操作使用独占锁
// 2. 保持接口不变：只需替换实现，外部代码无需修改
template <typename K, typename V, size_t NUM_SHARDS = 32>
class page_index {
    static_assert(NUM_SHARDS > 0 && (NUM_SHARDS & (NUM_SHARDS - 1)) == 0,
                  "NUM_SHARDS must be a power of 2");

public:
    page_index() = default;
    ~page_index() = default;

    // 插入索引：给定键，存储对应的值
    void insert(const K& key, const V& value) {
        const size_t shard_idx = get_shard(key);
        std::unique_lock<std::shared_timed_mutex> lock(shards_[shard_idx].mutex);
        shards_[shard_idx].data[key] = value;
    }

    // 查找索引：给定键，返回对应的值
    bool find(const K& key, V& value) const {
        const size_t shard_idx = get_shard(key);
        std::shared_lock<std::shared_timed_mutex> lock(shards_[shard_idx].mutex);
        auto it = shards_[shard_idx].data.find(key);
        if (it != shards_[shard_idx].data.end()) {
            value = it->second;
            return true;
        }
        return false;
    }

    // 删除索引
    void erase(const K& key) {
        const size_t shard_idx = get_shard(key);
        std::unique_lock<std::shared_timed_mutex> lock(shards_[shard_idx].mutex);
        shards_[shard_idx].data.erase(key);
    }

    // 更新索引
    void update(const K& key, const V& value) {
        insert(key, value);
    }

    // 检查是否存在
    bool exists(const K& key) const {
        const size_t shard_idx = get_shard(key);
        std::shared_lock<std::shared_timed_mutex> lock(shards_[shard_idx].mutex);
        return shards_[shard_idx].data.find(key) != shards_[shard_idx].data.end();
    }

    // 获取索引数量
    size_t size() const {
        size_t total = 0;
        for (const auto& shard : shards_) {
            std::shared_lock<std::shared_timed_mutex> lock(shard.mutex);
            total += shard.data.size();
        }
        return total;
    }

    // 清空索引
    void clear() {
        for (auto& shard : shards_) {
            std::unique_lock<std::shared_timed_mutex> lock(shard.mutex);
            shard.data.clear();
        }
    }

private:
    struct shard_t {
        mutable std::shared_timed_mutex mutex;
        std::unordered_map<K, V> data;
    };

    std::array<shard_t, NUM_SHARDS> shards_;

    size_t get_shard(const K& key) const {
        std::hash<K> hasher;
        return hasher(key) & (NUM_SHARDS - 1);
    }
};

} // namespace hw_dsm_runtime

#endif // INDEX_H
