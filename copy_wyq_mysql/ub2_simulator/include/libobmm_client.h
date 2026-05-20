//
// Created by root on 2026/1/14.
//

#ifndef OBMM_SIMULATOR_LIBOBMM_CLIENT_H
#define OBMM_SIMULATOR_LIBOBMM_CLIENT_H

#define SOCKET_PATH_LENGTH 256

/**
 * Protocol message types
 */
enum client_msg_type {
    CLIENT_MSG_EXPORT = 1,
    CLIENT_MSG_UNEXPORT = 2,
    CLIENT_MSG_IMPORT = 3,
    CLIENT_MSG_UNIMPORT = 4,
    CLIENT_MSG_FINISH = 5
};

/**
 * Request structure
 * @note obmm_mem_desc has flexible array member, so we use a fixed-size buffer
 */
struct client_request {
    int msg_type;
    uint64_t id;
    size_t length[OBMM_MAX_LOCAL_NUMA_NODES];
    uint64_t addr;
    uint64_t desc_length;
    // Other fields of obmm_mem_desc are not needed for now
};

/**
 * Response structure
 */
struct client_response {
    int success;  // 0 success, -1 failure
    uint64_t id;
    uint64_t addr;  // Allocated address
    uint64_t length; // Allocated length
};



#endif //OBMM_SIMULATOR_LIBOBMM_CLIENT_H