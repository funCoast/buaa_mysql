#ifndef ADDR_ALLOCATOR_H
#define ADDR_ALLOCATOR_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/**
 * @brief Size of address space per node
 * @warning Change this should also change OBMM_MAX_ORDER_FIXED
 * @note Now it's fixed to 2GB
 */
#define OBMM_NODE_ADDR_SPACE_SIZE (2ULL * 1024ULL * 1024ULL * 1024ULL)

/**
 * @brief Minimum allocation size (must be power of 2)
 * @warning Don't change it unless OBMM standard changed
 * @note Now it's fixed to 2MB
 */
#define OBMM_MIN_ALLOC_SIZE (2ULL * 1024ULL * 1024ULL)

/**
 * @brief Initialize address allocator for a node
 * @param node_id Virtual node ID
 * @return 0 on success, -1 on failure
 */
int addr_allocator_init(int node_id);

/** @brief Cleanup address allocator */
void addr_allocator_finalize();

/**
 * @brief Allocate an address range
 * @param size Size to allocate (will be rounded up to power of 2)
 * @return node_id * OBMM_NODE_ADDR_SPACE_SIZE + offset
 */
uint64_t addr_allocator_alloc(uint64_t size);

/**
 * @brief Free an address range
 * @param addr address to free (must be the base address returned by alloc)
 * @param size size to free (must match the size used in alloc)
 * @return 0 on success, -1 on failure
 */
int addr_allocator_free(uint64_t addr, uint64_t size);

#ifdef __cplusplus
}
#endif

#endif // ADDR_ALLOCATOR_H

