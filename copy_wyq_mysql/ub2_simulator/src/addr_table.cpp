#include "addr_table.h"
#include "export.h"
#include <mpi.h>
#include <unordered_map>
#include <map>
#include <thread>
#include <atomic>
#include <chrono>
#include <cstring>
#include <cstdio>

// Globals
static int g_rank = -1;
static int g_size = -1;
static std::unordered_map<uint64_t, addr_table_entry> *g_table = nullptr;
static std::map<uint64_t, exported_mem_info> *g_exported_mem = nullptr; // addr -> export info
static std::atomic<bool> g_running(false);
static std::thread *g_service_thread = nullptr;
// Shared atomic counter for local memory IDs (used by both export and import)
std::atomic<int64_t> g_local_mem_id(0);

// Rank0: handle add
static int handle_add_request(uint64_t addr, int node_id, mem_id mem_id, uint64_t length) {
    if (!g_table) {
        return -1;
    }
    const auto entry = addr_table_entry{addr, node_id, mem_id, length};
    (*g_table)[addr] = entry;
    printf("[Node 0] Added entry: addr=0x%lx, node_id=%d, mem_id=%ld, length=%lu\n",
           addr, node_id, mem_id, length);
    return 0;
}

/**
 * Rank 0 remove exported entry
 * @param addr to remove
 * @return 0 success else -1
 */
static int handle_remove_request(uint64_t addr) {
    if (!g_table) {
        return -1;
    }

    const auto it = g_table->find(addr);
    if (it == g_table->end()) {
        printf("[Node 0] Remove failed: addr=0x%lx not found\n", addr);
        return -1;
    }

    g_table->erase(it);
    printf("[Node 0] Removed entry: addr=0x%lx\n", addr);
    return 0;
}

/**
 * Rank 0 query addr
 * @param addr to query
 * @param entry data will be copied to it
 * @return 0 success else -1
 */
static int handle_query_request(uint64_t addr, addr_table_entry *entry) {
    if (!g_table) {
        return -1;
    }

    auto it = g_table->find(addr);
    if (it == g_table->end()) {
        printf("[Node 0] Query failed: addr=0x%lx not found\n", addr);
        return -1;
    }

    *entry = it->second;
    printf("[Node 0] Query success: addr=0x%lx, node_id=%d, mem_id=%ld\n",
           addr, entry->node_id, entry->_mem_id);
    return 0;
}

/**
 * Rank0: service thread function
 * Continuously process messages
 */
static void node0_service_thread_func() {
    using namespace InnerServer;
    printf("[Node 0] Service thread started and waiting for messages...\n");
    fflush(stdout);
    while (true) {
        MPI_Status status;
        int msg_type;
        // Blocking receive message
        MPI_Recv(&msg_type, 1, MPI_INT, MPI_ANY_SOURCE, MPI_ANY_TAG,
                 MPI_COMM_WORLD, &status);

        // Check for stop message
        if (msg_type == MSG_STOP) {
            printf("[Node 0] Service thread received message type %d from node %d\n",
                   msg_type, status.MPI_SOURCE);
            printf("[Node 0] Service thread received STOP message, exiting...\n");
            fflush(stdout);
            break;
        } else if (msg_type == MSG_ADD) {
            // Receive add request
            const int source = status.MPI_SOURCE;
            uint64_t addr;
            int node_id;
            mem_id mem_id;
            uint64_t length;
            MPI_Recv(&addr, 1, MPI_UINT64_T, source, MSG_ADD,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            MPI_Recv(&node_id, 1, MPI_INT, source, MSG_ADD,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            MPI_Recv(&mem_id, 1, MPI_INT64_T, source, MSG_ADD,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            MPI_Recv(&length, 1, MPI_UINT64_T, source, MSG_ADD,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            const int success = handle_add_request(addr, node_id, mem_id, length);
            const auto response = new mpi_response(success);

            MPI_Send(response, sizeof(mpi_response), MPI_BYTE, source,
                     MSG_RESPONSE, MPI_COMM_WORLD);
            printf("[Node 0] Service thread sent response for ADD to node %d\n",
                   source);
            fflush(stdout);
        } else if (msg_type == MSG_REMOVE) {
            // Receive remove request
            const int source = status.MPI_SOURCE;
            uint64_t addr;
            MPI_Recv(&addr, 1, MPI_UINT64_T, source, MSG_REMOVE,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);

            const int success = handle_remove_request(addr);
            // Unexport shared memory if it was exported by this node
            if (success == 0 && g_exported_mem != nullptr) {
                const auto it = g_exported_mem->find(addr);
                if (it != g_exported_mem->end()) {
                    const exported_mem_info &info = it->second;
                    obmm_unexport_shm(info.path, info.mapped_addr, info.size);
                    g_exported_mem->erase(it);
                }
            }
            const auto response = new mpi_response(success);
            MPI_Send(response, sizeof(mpi_response), MPI_BYTE, source,
                     MSG_RESPONSE, MPI_COMM_WORLD);
            printf("[Node 0] Service thread sent response for REMOVE to node %d\n",
                   source);
            fflush(stdout);
        } else if (msg_type == MSG_QUERY) {
            const int source = status.MPI_SOURCE;
            uint64_t addr;
            MPI_Recv(&addr, 1, MPI_UINT64_T, source, MSG_QUERY,
                     MPI_COMM_WORLD, MPI_STATUS_IGNORE);

            const auto response = new mpi_response(0);
            const int success = handle_query_request(addr, &response->entry);
            response->success = success;

            MPI_Send(response, sizeof(mpi_response), MPI_BYTE, source,
                     MSG_RESPONSE, MPI_COMM_WORLD);
            printf("[Node 0] Service thread sent response for QUERY to node %d\n",
                   source);
            fflush(stdout);
        }
    }
    printf("[Node 0] Service thread exited\n");
    fflush(stdout);
}

int addr_table_init(int *rank, int *size) {
    // Initialize MPI with thread support (required for service thread)
    int provided;
    int ret = MPI_Init_thread(nullptr, nullptr, MPI_THREAD_MULTIPLE, &provided);
    if (ret != MPI_SUCCESS) {
        fprintf(stderr, "MPI_Init_thread failed\n");
        return -1;
    }
    if (provided < MPI_THREAD_MULTIPLE) {
        fprintf(stderr, "Warning: MPI_THREAD_MULTIPLE not supported, got %d\n", provided);
    }

    ret = MPI_Comm_rank(MPI_COMM_WORLD, rank);
    if (ret != MPI_SUCCESS) {
        fprintf(stderr, "MPI_Comm_rank failed\n");
        MPI_Finalize();
        return -1;
    }

    ret = MPI_Comm_size(MPI_COMM_WORLD, size);
    if (ret != MPI_SUCCESS) {
        fprintf(stderr, "MPI_Comm_size failed\n");
        MPI_Finalize();
        return -1;
    }

    g_rank = *rank;
    g_size = *size;

    // Rank0 owns the table and starts service thread
    if (g_rank == 0) {
        g_table = new std::unordered_map<uint64_t, struct addr_table_entry>();
        g_running.store(true);
        g_service_thread = new std::thread(node0_service_thread_func);
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        printf("[Node 0] Address table initialized, service thread started\n");
    }

    return 0;
}

void addr_table_finalize() {
    if (g_rank == 0) {
        // Stop service thread (should already be stopped by stop_message_queue)
        if (g_service_thread) {
            if (g_service_thread->joinable()) {
                g_service_thread->join();
            }
            delete g_service_thread;
            g_service_thread = nullptr;
        }

        // Unexport all remaining shared memory
        if (g_exported_mem) {
            for (const auto &pair: *g_exported_mem) {
                obmm_unexport_shm(pair.second.path, pair.second.mapped_addr, pair.second.size);
            }
            delete g_exported_mem;
            g_exported_mem = nullptr;
        }

        if (g_table) {
            delete g_table;
            g_table = nullptr;
        }
    } else {
        // Non-rank0: unexport local shared memory
        if (g_exported_mem) {
            for (const auto &pair: *g_exported_mem) {
                obmm_unexport_shm(pair.second.path, pair.second.mapped_addr, pair.second.size);
            }
            delete g_exported_mem;
            g_exported_mem = nullptr;
        }
    }
    MPI_Finalize();
}

int addr_table_add(const uint64_t addr, const int node_id, mem_id mem_id, const uint64_t length) {
    using namespace InnerServer;
    if (g_rank < 0) {
        return -1;
    }

    // Export shared memory locally (on the sender side)
    char shm_path[256];
    void *mapped_addr = nullptr;

    // Use local mem_id counter for this process (atomic increment)
    const int64_t local_mem_id = mem_id;

    if (obmm_export_shm(length, g_rank, local_mem_id, shm_path, sizeof(shm_path), &mapped_addr) != 0) {
        fprintf(stderr, "[Node %d] Failed to export shared memory\n", g_rank);
        return -1;
    }

    if (!g_exported_mem) {
        g_exported_mem = new std::map<uint64_t, exported_mem_info>();
    }
    const exported_mem_info info(shm_path, mapped_addr, length);
    (*g_exported_mem)[addr] = info;
    if (g_rank == 0) {
        return handle_add_request(addr, node_id, mem_id, length);
    }

    // Other ranks send request to rank0
    printf("[Node %d] Sending ADD request: addr=0x%lx, length=%lu\n", g_rank, addr, length);
    fflush(stdout);

    constexpr int msg_type = MSG_ADD;
    MPI_Send(&msg_type, 1, MPI_INT, 0, MSG_ADD, MPI_COMM_WORLD);
    MPI_Send(&addr, 1, MPI_UINT64_T, 0, MSG_ADD, MPI_COMM_WORLD);
    MPI_Send(&node_id, 1, MPI_INT, 0, MSG_ADD, MPI_COMM_WORLD);
    MPI_Send(&mem_id, 1, MPI_INT64_T, 0, MSG_ADD, MPI_COMM_WORLD);
    MPI_Send(&length, 1, MPI_UINT64_T, 0, MSG_ADD, MPI_COMM_WORLD);

    printf("[Node %d] Waiting for ADD response...\n", g_rank);
    fflush(stdout);

    auto response = new mpi_response(0);
    MPI_Recv(response, sizeof(mpi_response), MPI_BYTE, 0, MSG_RESPONSE,
             MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    printf("[Node %d] Received ADD response: success=%d\n", g_rank, response->success);
    fflush(stdout);

    return response->success;
}

int addr_table_remove(const uint64_t addr) {
    using namespace InnerServer;
    if (g_rank < 0) {
        return -1;
    }

    if (g_rank == 0) {
        const int ret = handle_remove_request(addr);

        // Unexport shared memory if it was exported by this node
        if (ret == 0 && g_exported_mem && g_exported_mem->find(addr) != g_exported_mem->end()) {
            const exported_mem_info &info = (*g_exported_mem)[addr];
            obmm_unexport_shm(info.path, info.mapped_addr, info.size);
            g_exported_mem->erase(addr);
        }

        return ret;
    }

    constexpr int msg_type = MSG_REMOVE;
    MPI_Send(&msg_type, 1, MPI_INT, 0, MSG_REMOVE, MPI_COMM_WORLD);
    MPI_Send(&addr, 1, MPI_UINT64_T, 0, MSG_REMOVE, MPI_COMM_WORLD);
    auto response = new mpi_response(0);
    MPI_Recv(response, sizeof(mpi_response), MPI_BYTE, 0, MSG_RESPONSE,
             MPI_COMM_WORLD, MPI_STATUS_IGNORE);

    // Unexport local shared memory
    if (response->success == 0 && g_exported_mem && g_exported_mem->find(addr) != g_exported_mem->end()) {
        const exported_mem_info &info = (*g_exported_mem)[addr];
        obmm_unexport_shm(info.path, info.mapped_addr, info.size);
        g_exported_mem->erase(addr);
    }

    return response->success;
}

int addr_table_query(const uint64_t addr, addr_table_entry *entry) {
    using namespace InnerServer;
    if (g_rank < 0 || entry == nullptr) {
        return -1;
    }
    if (g_rank == 0) {
        return handle_query_request(addr, entry);
    }

    constexpr int msg_type = MSG_QUERY;
    MPI_Send(&msg_type, 1, MPI_INT, 0, MSG_QUERY, MPI_COMM_WORLD);
    MPI_Send(&addr, 1, MPI_UINT64_T, 0, MSG_QUERY, MPI_COMM_WORLD);
    auto response = new mpi_response(0);
    MPI_Recv(response, sizeof(mpi_response), MPI_BYTE, 0, MSG_RESPONSE,
             MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    if (response->success == 0) {
        *entry = response->entry;
    }
    return response->success;
}

void addr_table_stop_message_queue() {
    using namespace InnerServer;
    if (g_rank == 0) {
        // Send stop message to service thread
        constexpr int msg_type = MSG_STOP;
        MPI_Send(&msg_type, 1, MPI_INT, 0, MSG_STOP, MPI_COMM_WORLD);
        printf("[Node 0] Sent STOP message to service thread\n");
        fflush(stdout);
    }
}

