//
// OBMM Cacheable Memory Management Library Header
//
#ifndef OBMM_SIMULATOR_LIBOBMM_CACHEABLE_H
#define OBMM_SIMULATOR_LIBOBMM_CACHEABLE_H

#include <fcntl.h>
#include <cstdint>
#include <cstdlib>
#include <pthread.h>

#ifdef __cplusplus
#include <random>
extern "C" {
#endif

#define PAGE_SIZE 4096
#define POOL_PAGES (32 * (2 << 10))
#define POOL_SIZE (POOL_PAGES * PAGE_SIZE)

#ifdef __cplusplus
typedef struct obmm_ctx_t {
    int uffd{};
    // backing store: /dev/shm file mapping (true data)
    int shm_fd{};
    uint8_t *shm{};
    size_t len{};
    size_t pagesz{};
    size_t region_pages{};

    // user-visible region (same size as shm)
    uint8_t *region{};

    // buffer pool (fixed #pages)
    uint8_t *pool{};
    size_t pool_pages{};

    // metadata
    // vpage -> slot, -1 = not resident
    int *vpage_to_slot{};
    // slot -> vpage, -1 = free slot (never allocated a frame yet)
    int *slot_to_vpage{};
    // slot -> dirty flag, 1 = dirty (modified), 0 = clean
    bool *slot_dirty{};

    // temp: select victim page, will be replaced by lru
    std::mt19937 rng;
    std::uniform_int_distribution<int> victim_chooser;

    pthread_mutex_t mu{};
    pthread_t fault_handler_thread{};
    bool should_stop{};  // Flag to signal fault handler thread to stop
} obmm_ctx_t;
#else
typedef struct obmm_ctx_t obmm_ctx_t;
#endif

/**
 * Initialize OBMM Cacheable Management
 * @param path path of shared memory file
 * @param shm_size size of shared memory (must be aligned to PAGE_SIZE)
 * @return context pointer on success, nullptr on failure
 */
obmm_ctx_t* init_obmm_cacheable_manager(const char* path, size_t shm_size);

/**
 * Destroy OBMM Cacheable Management context
 * @param c context pointer (can be nullptr)
 */
void destroy_obmm_cacheable_manager(obmm_ctx_t *c);

/**
 * Manual writeback: if vpage is resident (in pool), write current content to shm
 * @param c context pointer
 * @param vpage virtual page number
 * @return 0 on success, 1 if not resident, -1 on error
 */
int manual_writeback_vpage(obmm_ctx_t *c, int vpage);

/**
 * Manual invalidate: if vpage is resident, discard cache and make region[vpage] missing
 * @param c context pointer
 * @param vpage virtual page number
 * @return 0 on success, 1 if not resident, -1 on error
 */
int manual_invalidate_vpage(obmm_ctx_t *c, int vpage);

#ifdef __cplusplus
}
#endif

#endif // OBMM_SIMULATOR_LIBOBMM_CACHEABLE_H