#ifndef ADDR_TABLE_H
#define ADDR_TABLE_H
#include "string.h"

#include "libobmm.h"

#include <stdint.h>
#ifdef __cplusplus
#include <atomic>
#endif

#ifdef __cplusplus
// C++ definitions with constructors
/**
 * Entry mapping: addr -> (node_id, mem_id, length)
 */
struct addr_table_entry {
    uint64_t addr;
    int node_id;
    mem_id _mem_id;
    uint64_t length;

    addr_table_entry(const uint64_t addr = 0, const int node_id = 0,
                     mem_id mem_id = 0, const uint64_t length = 0)
        : addr(addr), node_id(node_id), _mem_id(mem_id), length(length) {
    }
};

namespace InnerServer {
    /**
     * MPI message types (Inner server)
     */
    enum mpi_msg_type {
        MSG_ADD = 1,
        MSG_REMOVE = 2,
        MSG_QUERY = 3,
        MSG_RESPONSE = 4,
        MSG_STOP = 5
    };

    /**
     * Response payload
     * 0 success, -1 failure
     */
    struct mpi_response {
        int success;
        addr_table_entry entry;

        mpi_response(const int success, addr_table_entry entry = {})
            : success(success), entry(entry) {
        }
    };
}

/**
 * Exported memory info (for cleanup)
 */
struct exported_mem_info {
    char path[MAX_PATH_LEN];
    void *mapped_addr;
    uint64_t size;
    exported_mem_info(char* path, void *mapped_addr, uint64_t size) :
        path(), mapped_addr(mapped_addr), size(size) {
        strcpy(this->path, path);
        this->path[sizeof(this->path) - 1] = '\0';
    }
    exported_mem_info():path(), mapped_addr(nullptr), size(0) {}
};

/**
* Init MPI and address table (rank0 owns hash map)
* @param rank MPI Rank
* @param size MPI Size
* @return 0 on success, -1 on failure
*/
int addr_table_init(int *rank, int *size);

/**
 * Release all the memory
 */
void addr_table_finalize();

/**
 * Add entry (all ranks; non-zero ranks talk to rank0)
 * @param addr
 * @param node_id
 * @param mem_id
 * @param length
 * @return 0 on success, -1 on failure
 */
int addr_table_add(uint64_t addr, int node_id, mem_id mem_id, uint64_t length);

/**
 * Remove entry (all ranks)
 * @param addr
 * @return return 0 on success, -1 if not found
 */
int addr_table_remove(uint64_t addr);

/**
 * Query entry (all ranks)
 * @param addr
 * @param entry
 * @return return 0 and fill entry on success, -1 if not found
 */
int addr_table_query(uint64_t addr, struct addr_table_entry *entry);

// Rank0: stop message service thread (called before finalize)
void addr_table_stop_message_queue();

// Start/stop socket server for client communication
void obmm_simulator_start_server(int rank);

void obmm_simulator_stop_server();

// Cleanup import records
void obmm_simulator_cleanup_imports();

#ifdef __cplusplus
// Shared atomic counter for local memory IDs (used by both export and import)
extern std::atomic<int64_t> g_local_mem_id;
#endif

#endif

#endif // ADDR_TABLE_H
