#include <iostream>
#include <vector>
#include <map>
#define _POSIX_C_SOURCE 200809L
#include "libobmm.h"
#include <cstdint>
#include <errno.h>
#include <fcntl.h>
#include <mpi.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "dsm_config.h"
#include "dsm_types.h"
#include "actor.h"
#include "index.h"
#include <memory>


static size_t init_bytes_per_node() {
    const char *v = getenv("DSM_CACHE_BYTES_PER_NODE");
    if (!(v && *v)) {
        v = getenv("DSM_BRIDGE_BYTES_PER_NODE");
    }
    if (!(v && *v)) {
        return ARRAY_SIZE * sizeof(int);
    }
    char *end = nullptr;
    errno = 0;
    const auto parsed = strtoull(v, &end, 10);
    if (errno != 0 || end == v || (end != nullptr && *end != '\0')) {
        return ARRAY_SIZE * sizeof(int);
    }
    return static_cast<size_t>(parsed);
}

namespace hw_dsm_runtime {

// 使用 uint8_t 作为基础数据类型，可以灵活存储任意字节数据
// 也可以根据需要特化为其他类型（如数据库记录结构等）
using byte_actor_t = node_actor<uint8_t>;
using page_index_t = page_index<page_id_t, extent_location_t>;

class runtime {
public:
    runtime() = default;

    // 注册内存：为每个节点创建 actor
    void register_memory(uint8_t node_id, void *mapped_addr, size_t size) {
        std::cout << "[Runtime] Registering memory for node " << static_cast<int>(node_id) 
                  << ", size: " << size << " bytes" << std::endl;
        
        // 创建并初始化 actor（使用 uint8_t 类型）
        auto actor = std::make_shared<byte_actor_t>(node_id, mapped_addr, size);
        if (actor->init()) {
            actors_[node_id] = actor;
            std::cout << "[Runtime] Actor for node " << static_cast<int>(node_id) << " initialized" << std::endl;
        } else {
            std::cerr << "[Runtime] Failed to initialize actor for node " << static_cast<int>(node_id) << std::endl;
        }
    }

    // 写入数据：给定 page_id_t，写入数据
    bool write_page(const page_id_t& page_id, const void* data, size_t size) {
        extent_location_t location;
        
        // 检查索引中是否已存在
        if (!index_.find(page_id, location)) {
            // 如果不存在，需要分配新的 page
            // 使用轮询方式选择节点 (1, 2, 3)
            uint8_t node_id = static_cast<uint8_t>((page_id.page_num % 3) + 1);
            
            if (actors_.find(node_id) == actors_.end()) {
                std::cerr << "[Runtime] Actor for node " << static_cast<int>(node_id) << " not found" << std::endl;
                return false;
            }
            
            // 在选定的节点上分配 page
            location = actors_[node_id]->allocate_page(page_id.space_id, page_id.page_num);
            
            if (location.node_id == 0) {
                std::cerr << "[Runtime] Failed to allocate page" << std::endl;
                return false;
            }
            
            // 更新索引
            index_.insert(page_id, location);
            std::cout << "[Runtime] Allocated new page: space_id=" << page_id.space_id 
                      << ", page_num=" << page_id.page_num 
                      << " -> node=" << static_cast<int>(location.node_id) 
                      << ", extent=" << location.extent_id 
                      << ", offset=" << location.page_offset << std::endl;
        }
        
        // 写入数据（使用原始字节写入接口）
        if (actors_.find(location.node_id) == actors_.end()) {
            std::cerr << "[Runtime] Actor for node " << static_cast<int>(location.node_id) << " not found" << std::endl;
            return false;
        }
        
        return actors_[location.node_id]->write_page_raw(
            location.extent_id, location.page_offset, data, size);
    }

    // 读取数据：给定 page_id_t，读取数据
    bool read_page(const page_id_t& page_id, void* data, size_t size) {
        extent_location_t location;
        
        // 从索引中查找
        if (!index_.find(page_id, location)) {
            std::cerr << "[Runtime] Page not found in index: space_id=" 
                      << page_id.space_id << ", page_num=" << page_id.page_num << std::endl;
            return false;
        }
        
        // 读取数据（使用原始字节读取接口）
        if (actors_.find(location.node_id) == actors_.end()) {
            std::cerr << "[Runtime] Actor for node " << static_cast<int>(location.node_id) << " not found" << std::endl;
            return false;
        }
        
        return actors_[location.node_id]->read_page_raw(
            location.extent_id, location.page_offset, data, size);
    }

    // 获取索引系统（用于 node 0）
    page_index_t& get_index() {
        return index_;
    }

    // 验证函数：读取并打印数据
    void valid(const page_id_t& page_id) {
        char buffer[PAGE_SIZE];
        if (read_page(page_id, buffer, PAGE_SIZE)) {
            std::cout << "[Runtime] Valid page: space_id=" << page_id.space_id 
                      << ", page_num=" << page_id.page_num << std::endl;
            // 打印前几个整数（如果数据是整数类型）
            int* int_data = reinterpret_cast<int*>(buffer);
            for (int i = 0; i < 10 && i < PAGE_SIZE / sizeof(int); i++) {
                std::cout << "  [" << i << "] = " << int_data[i] << std::endl;
            }
        } else {
            std::cerr << "[Runtime] Failed to read page: space_id=" 
                      << page_id.space_id << ", page_num=" << page_id.page_num << std::endl;
        }
    }

private:
    std::map<uint8_t, std::shared_ptr<byte_actor_t>> actors_;  // node_id -> actor
    page_index_t index_;  // 索引系统（在 node 0 上）
};

} // namespace hw_dsm_runtime

static hw_dsm_runtime::runtime dsm_runtime_instance;

int main(int argc, char *argv[]) {
    // Initialize MPI
    int mpi_rank, mpi_size;
    if (MPI_Init(&argc, &argv) != MPI_SUCCESS) {
        std::cerr << "MPI_Init failed" << std::endl;
        return 1;
    }
    
    MPI_Comm_rank(MPI_COMM_WORLD, &mpi_rank);
    MPI_Comm_size(MPI_COMM_WORLD, &mpi_size);
    
    // 只有 rank 0 执行测试代码
    if (mpi_rank != 0) {
        // 其他进程等待或执行其他任务
        MPI_Finalize();
        return 0;
    }
    
    // 节点 1, 2, 3 用于存储 extent 和 page
    std::vector<uint8_t> imported_nodes = {1, 2, 3};

    std::cout << "[User Process 0] Initializing DSM runtime..." << std::endl;

    // 为每个节点导入内存并初始化 actor
    for (auto node : imported_nodes) {
        std::cout << "[User Process 0] Importing from simulator node " << node
                  << std::endl;

        char shm_path[256];
        snprintf(shm_path, sizeof(shm_path),
                 "/dev/shm/virtual_node%d/obmm_shmdev%d", 0, node);
        int fd = open(shm_path, O_RDWR);
        if (fd < 0) {
            std::cerr << "[User Process 0] Error opening shm file " << shm_path 
                      << ": " << strerror(errno) << std::endl;
            return 1;
        }

        // 映射内存（使用 ARRAY_SIZE，但实际可以用更大的值）
        // 这里假设每个节点有足够的内存来存储多个 extent
        size_t mapped_size = init_bytes_per_node();
        void *array = (void *)mmap(NULL, mapped_size,
                                   PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (array == MAP_FAILED) {
            std::cerr << "[User Process 0] mmap failed: " << strerror(errno) << std::endl;
            close(fd);
            return 2;
        }
        close(fd);

        // 注册内存并初始化 actor
        dsm_runtime_instance.register_memory(node, array, mapped_size);
    }

    // 测试：写入和读取数据
    std::cout << "\n=== Testing DSM Runtime ===" << std::endl;
    
    // 写入一些测试数据
    hw_dsm_runtime::page_id_t page1(1, 0);  // space_id=1, page_num=0
    int test_data[PAGE_SIZE / sizeof(int)];
    for (int i = 0; i < PAGE_SIZE / sizeof(int); i++) {
        test_data[i] = 1000 + i;
    }
    
    std::cout << "\n[Test] Writing page (space_id=1, page_num=0)..." << std::endl;
    if (dsm_runtime_instance.write_page(page1, test_data, PAGE_SIZE)) {
        std::cout << "[Test] Write successful" << std::endl;
    } else {
        std::cerr << "[Test] Write failed" << std::endl;
    }

    // 读取数据
    std::cout << "\n[Test] Reading page (space_id=1, page_num=0)..." << std::endl;
    dsm_runtime_instance.valid(page1);

    // 测试第二个 page
    hw_dsm_runtime::page_id_t page2(1, 1);  // space_id=1, page_num=1
    for (int i = 0; i < PAGE_SIZE / sizeof(int); i++) {
        test_data[i] = 2000 + i;
    }
    
    std::cout << "\n[Test] Writing page (space_id=1, page_num=1)..." << std::endl;
    if (dsm_runtime_instance.write_page(page2, test_data, PAGE_SIZE)) {
        std::cout << "[Test] Write successful" << std::endl;
    }
    
    std::cout << "\n[Test] Reading page (space_id=1, page_num=1)..." << std::endl;
    dsm_runtime_instance.valid(page2);

    // 显示索引统计
    std::cout << "\n[Runtime] Index contains " << dsm_runtime_instance.get_index().size() 
              << " entries" << std::endl;

    MPI_Finalize();
    return 0;
}
