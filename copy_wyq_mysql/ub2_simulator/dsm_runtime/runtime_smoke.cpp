// dsm_runtime_smoke: 在没有 simulator 的情况下，直接用本地 malloc 做假的
// "远端内存"来验证 runtime 类的基本功能。用于排查 MySQL 集成时的问题。
//
// 用法：
//   cd build && make dsm_runtime_smoke && ./dsm_runtime_smoke
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

#include "dsm_config.h"
#include "dsm_types.h"
#include "runtime.h"

int main() {
  using namespace hw_dsm_runtime;

  runtime rt;
  // 模拟 3 个远端节点，每个节点 16MB
  const size_t per_node = static_cast<size_t>(ARRAY_SIZE) * sizeof(int);
  std::vector<uint8_t *> buffers;
  for (int i = 1; i <= 3; ++i) {
    uint8_t *buf = static_cast<uint8_t *>(std::calloc(1, per_node));
    rt.register_memory(static_cast<uint8_t>(i), buf, per_node);
    buffers.push_back(buf);
  }

  // 写若干 page
  const uint32_t SPACE = 42;
  char page[PAGE_SIZE];
  for (uint32_t i = 0; i < 10; ++i) {
    std::memset(page, 'A' + (i % 26), PAGE_SIZE);
    if (!rt.write_page({SPACE, i}, page, PAGE_SIZE)) {
      std::cerr << "write_page failed: " << i << "\n";
      return 1;
    }
  }

  // 读回验证
  for (uint32_t i = 0; i < 10; ++i) {
    char got[PAGE_SIZE];
    if (!rt.read_page({SPACE, i}, got, PAGE_SIZE)) {
      std::cerr << "read_page miss: " << i << "\n";
      return 2;
    }
    char expect = 'A' + (i % 26);
    if (got[0] != expect || got[PAGE_SIZE - 1] != expect) {
      std::cerr << "content mismatch on page " << i << "\n";
      return 3;
    }
  }

  // erase -> re-read -> miss
  rt.erase_page({SPACE, 5});
  char tmp[PAGE_SIZE];
  if (rt.read_page({SPACE, 5}, tmp, PAGE_SIZE)) {
    std::cerr << "expected miss after erase\n";
    return 4;
  }

  std::cout << "[PASS] dsm_runtime_smoke: " << rt.index_size()
            << " pages indexed, nodes=" << rt.node_count() << "\n";

  for (auto *p : buffers) std::free(p);
  return 0;
}
