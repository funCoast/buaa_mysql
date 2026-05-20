#ifndef EXPORT_H
#define EXPORT_H

#ifdef __cplusplus

#include <cstdint>
#include <cstddef>

/**
 * Export shared memory for a memory region
 * /dev/shm/virtual_node{i}/obmm_shmdev{mem_id}
 * @param size
 * @param node_id
 * @param mem_id
 * @param path output parameter, will be filled with the created path
 * @param path_size size of path buffer
 * @param mapped_addr
 * @return file descriptor on success, -1 on failure
 */
int obmm_export_shm(uint64_t size, int node_id, int64_t mem_id,
                    char *path, size_t path_size, void **mapped_addr);

/**
 * Unexport shared memory
 * @param path
 * @param mapped_addr
 * @param size
 * @return 0 on success, -1 on failure
 */
int obmm_unexport_shm(const char *path, void *mapped_addr, uint64_t size);

#endif

#endif // EXPORT_H

