#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#include "dsm_types.h"
#include "index.h"

namespace hw_dsm_runtime {

namespace {

using test_index_t = page_index<page_id_t, extent_location_t, 32>;
class global_lock_index_t {
public:
    void insert(const page_id_t& key, const extent_location_t& value) {
        std::lock_guard<std::mutex> lock(mu_);
        data_[key] = value;
    }

    bool find(const page_id_t& key, extent_location_t& value) const {
        std::lock_guard<std::mutex> lock(mu_);
        auto it = data_.find(key);
        if (it == data_.end()) {
            return false;
        }
        value = it->second;
        return true;
    }

    void update(const page_id_t& key, const extent_location_t& value) {
        insert(key, value);
    }

    size_t size() const {
        std::lock_guard<std::mutex> lock(mu_);
        return data_.size();
    }

private:
    mutable std::mutex mu_;
    std::unordered_map<page_id_t, extent_location_t> data_;
};

constexpr uint32_t kSpaceId = 7;
constexpr uint32_t kKeysPerWriter = 2000;
constexpr uint32_t kWriterRounds = 20;

page_id_t make_page_id(uint32_t key_num) {
    return page_id_t(kSpaceId, key_num);
}

extent_location_t expected_value_for(uint32_t key_num, uint32_t writer_id) {
    return extent_location_t(
        static_cast<uint8_t>((writer_id % 3) + 1),
        key_num,
        static_cast<uint16_t>(kWriterRounds - 1));
}

bool same_location(const extent_location_t& a, const extent_location_t& b) {
    return a.node_id == b.node_id && a.extent_id == b.extent_id &&
           a.page_offset == b.page_offset;
}

struct run_result_t {
    long elapsed_ms;
    uint64_t reader_hits;
    uint64_t reader_misses;
    uint64_t mismatches;
    size_t index_size;
};

template <typename IndexT>
run_result_t run_rw_benchmark(const char* tag,
                              uint32_t writer_threads,
                              uint32_t reader_threads,
                              uint32_t total_keys) {
    IndexT index;
    for (uint32_t key = 0; key < total_keys; ++key) {
        index.insert(make_page_id(key), extent_location_t(1, key, 0));
    }

    std::atomic<bool> stop_readers(false);
    std::atomic<uint64_t> reader_hits(0);
    std::atomic<uint64_t> reader_misses(0);
    std::vector<std::thread> readers;
    readers.reserve(reader_threads);
    for (uint32_t r = 0; r < reader_threads; ++r) {
        readers.emplace_back([&index, &stop_readers, &reader_hits, &reader_misses,
                              r, total_keys]() {
            uint32_t cursor = r % total_keys;
            extent_location_t out;
            while (!stop_readers.load(std::memory_order_relaxed)) {
                const page_id_t pid = make_page_id(cursor);
                if (index.find(pid, out)) {
                    reader_hits.fetch_add(1, std::memory_order_relaxed);
                } else {
                    reader_misses.fetch_add(1, std::memory_order_relaxed);
                }
                cursor = (cursor + 1) % total_keys;
            }
        });
    }

    auto t0 = std::chrono::steady_clock::now();
    std::vector<std::thread> writers;
    writers.reserve(writer_threads);
    for (uint32_t w = 0; w < writer_threads; ++w) {
        writers.emplace_back([&index, w]() {
            const uint32_t base = w * kKeysPerWriter;
            for (uint32_t round = 0; round < kWriterRounds; ++round) {
                for (uint32_t i = 0; i < kKeysPerWriter; ++i) {
                    const uint32_t key_num = base + i;
                    const page_id_t pid = make_page_id(key_num);
                    const extent_location_t loc(
                        static_cast<uint8_t>((w % 3) + 1), key_num,
                        static_cast<uint16_t>(round));
                    index.update(pid, loc);
                }
            }
        });
    }
    for (auto& t : writers) {
        t.join();
    }
    stop_readers.store(true, std::memory_order_relaxed);
    for (auto& t : readers) {
        t.join();
    }
    auto t1 = std::chrono::steady_clock::now();

    uint64_t mismatch = 0;
    for (uint32_t w = 0; w < writer_threads; ++w) {
        const uint32_t base = w * kKeysPerWriter;
        for (uint32_t i = 0; i < kKeysPerWriter; ++i) {
            const uint32_t key_num = base + i;
            const page_id_t pid = make_page_id(key_num);
            extent_location_t got;
            if (!index.find(pid, got)) {
                ++mismatch;
                continue;
            }
            const extent_location_t expected = expected_value_for(key_num, w);
            if (!same_location(got, expected)) {
                ++mismatch;
            }
        }
    }

    run_result_t result;
    result.elapsed_ms =
        std::chrono::duration_cast<std::chrono::milliseconds>(t1 - t0).count();
    result.reader_hits = reader_hits.load(std::memory_order_relaxed);
    result.reader_misses = reader_misses.load(std::memory_order_relaxed);
    result.mismatches = mismatch;
    result.index_size = index.size();

    std::cout << "[" << tag << "] elapsed_ms=" << result.elapsed_ms
              << ", reader_hits=" << result.reader_hits
              << ", reader_misses=" << result.reader_misses
              << ", mismatches=" << result.mismatches << "\n";
    return result;
}

}  // namespace

}  // namespace hw_dsm_runtime

int main() {
    using namespace hw_dsm_runtime;

    const uint32_t writer_threads =
        std::max(2u, std::thread::hardware_concurrency() / 2);
    const uint32_t reader_threads = writer_threads;
    const uint32_t total_keys = writer_threads * kKeysPerWriter;

    std::cout << "[Test] concurrent_index_test start\n";
    std::cout << "[Test] writers=" << writer_threads
              << ", readers=" << reader_threads
              << ", keys=" << total_keys
              << ", rounds=" << kWriterRounds << "\n";

    const run_result_t concurrent_result =
        run_rw_benchmark<test_index_t>("concurrent", writer_threads,
                                       reader_threads, total_keys);
    const run_result_t baseline_result =
        run_rw_benchmark<global_lock_index_t>("baseline_global_lock",
                                              writer_threads, reader_threads,
                                              total_keys);

    const uint64_t concurrent_reads =
        concurrent_result.reader_hits + concurrent_result.reader_misses;
    const uint64_t baseline_reads =
        baseline_result.reader_hits + baseline_result.reader_misses;
    const double read_gain =
        baseline_reads == 0
            ? 0.0
            : static_cast<double>(concurrent_reads) /
                  static_cast<double>(baseline_reads);
    const double time_gain =
        concurrent_result.elapsed_ms == 0
            ? 0.0
            : static_cast<double>(baseline_result.elapsed_ms) /
                  static_cast<double>(concurrent_result.elapsed_ms);

    std::cout << std::fixed << std::setprecision(2);
    std::cout << "[Compare] read_throughput_gain_x=" << read_gain
              << ", time_speedup_x=" << time_gain << "\n";

    if (concurrent_result.mismatches == 0 && baseline_result.mismatches == 0 &&
        concurrent_result.index_size == total_keys &&
        baseline_result.index_size == total_keys && concurrent_reads > 0 &&
        baseline_reads > 0) {
        std::cout << "[PASS] concurrent vs baseline comparison succeeded\n";
        return 0;
    }

    std::cerr << "[FAIL] benchmark consistency check failed\n";
    return 1;
}
