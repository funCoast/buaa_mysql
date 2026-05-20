/**
 * @file addr_allocator.cpp
 * @brief Buddy allocator implementation
 *
 * @note Notes:
 *   - Each node has OBMM_NODE_ADDR_SPACE_SIZE address space
 *   - Global address = node_id * OBMM_NODE_ADDR_SPACE_SIZE + offset
 *   - Addresses are allocated from offset 0 within the node's space
 */

#include "addr_allocator.h"
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <vector>


static int g_node_id = -1;
static uint64_t g_base_addr = 0;


struct free_block {
    uint64_t offset;
    free_block *next;
    free_block (const uint64_t offset, free_block *next) {
        this->offset = offset;
        this->next = next;
    }
};

std::vector<free_block*> free_lists;
static uint64_t total_allocated = 0;

/**
 * @brief Compute maximum order (2^order is the maximum block size)
 * @note OBMM_NODE_ADDR_SPACE_SIZE should be 2^max_order * OBMM_MIN_ALLOC_SIZE
 * @note Only compute once
 * @example
 *  - For 4TB = 2^42 bytes, and MIN_ALLOC_SIZE = 4MB = 2^22 bytes
 *  - MAX_ORDER = 42 - 22 = 20
 * @return Maximum order
 */
static int get_max_order() {
    static int max_order = -1;
    if (max_order < 0) {
        constexpr uint64_t space_size = OBMM_NODE_ADDR_SPACE_SIZE;
        constexpr uint64_t min_size = OBMM_MIN_ALLOC_SIZE;
        int order = 0;
        uint64_t size = min_size;

        while (size < space_size) {
            size <<= 1;
            order++;
        }

        if (size > space_size) {
            order--;
        }

        max_order = order;
    }
    return max_order;
}

/**
 * @brief Calculate order for a given size
 * @param size Allocated size
 * @return Block order which fixes this size.
 */
static int size_to_order(uint64_t size) {
    if (size < OBMM_MIN_ALLOC_SIZE) {
        size = OBMM_MIN_ALLOC_SIZE;
    }

    uint64_t rounded = OBMM_MIN_ALLOC_SIZE;
    int order = 0;
    const int max_order = get_max_order();
    while (rounded < size && order < max_order) {
        rounded <<= 1;
        order++;
    }

    return order;
}


/**
 * @brief Get size for an order
 * @param order Order of the block
 * @return Size for an order
 */
static uint64_t order_to_size(const int order) {
    return OBMM_MIN_ALLOC_SIZE << order;
}

/**
 * @brief Get buddy offset for a given offset and order
 * @param offset Addr offset of the block
 * @param order Order of the block
 * @return Its buddy's offset
 */
static uint64_t get_buddy_offset(const uint64_t offset,const int order) {
    const uint64_t size = order_to_size(order);
    return offset ^ size;
}

int addr_allocator_init(const int node_id) {
    g_node_id = node_id;
    g_base_addr = static_cast<uint64_t>(node_id) * OBMM_NODE_ADDR_SPACE_SIZE;

    // Initialize free list: one large block covering the entire space
    constexpr uint64_t space_size = OBMM_NODE_ADDR_SPACE_SIZE;
    const int max_order = get_max_order();
    free_lists.assign(max_order, nullptr);
    auto *block = new free_block(0, nullptr);
    free_lists[max_order] = block;
    total_allocated = 0;

    printf("[Node %d] Address allocator initialized: base=0x%lx, space_size=0x%lx, max_order=%d\n",
           node_id, g_base_addr, space_size, max_order);

    return 0;
}

void addr_allocator_finalize() {
    const int max_order = get_max_order();
    for (int i = 0; i <= max_order; i++) {
        auto block = free_lists[i];
        while (block) {
            free_block *next = block->next;
            delete block;
            block = next;
        }
        free_lists[i] = nullptr;
    }

    g_node_id = -1;
    g_base_addr = 0;
    total_allocated = 0;
}

uint64_t addr_allocator_alloc(uint64_t size) {
    if (g_node_id < 0) {
        return 0;
    }

    const int order = size_to_order(size);
    const int max_order = get_max_order();
    if (order > max_order) {
        fprintf(stderr, "[Node %d] Allocation size too large: %lu (max order=%d)\n", g_node_id, size, max_order);
        return 0;
    }

    // Find a free block of sufficient size
    int current_order = order;
    while (current_order <= max_order && free_lists[current_order] == nullptr) {
        current_order++;
    }

    if (current_order > max_order) {
        fprintf(stderr, "[Node %d] Out of address space\n", g_node_id);
        return 0;
    }

    // Split block if necessary
    while (current_order > order) {
        // Remove block from current order
        free_block *block = free_lists[current_order];
        free_lists[current_order] = block->next;

        // Split into two buddies
        const uint64_t size_half = order_to_size(current_order - 1);
        const uint64_t offset1 = block->offset;
        const uint64_t offset2 = offset1 + size_half;

        // Add first halfback
        block->offset = offset1;
        block->next = free_lists[current_order - 1];
        free_lists[current_order - 1] = block;

        // Add second half
        auto *block2 = new free_block(offset2, free_lists[current_order - 1]);
        free_lists[current_order - 1] = block2;

        current_order--;
    }

    // Allocate from current order
    const free_block *block = free_lists[order];
    free_lists[order] = block->next;

    const uint64_t offset = block->offset;
    delete block;

    const uint64_t global_addr = g_base_addr + offset;
    total_allocated += order_to_size(order);

    printf("[Node %d] Allocated address: offset=0x%lx, size=%lu (order=%d), global_addr=0x%lx\n",
           g_node_id, offset, order_to_size(order), order, global_addr);

    return global_addr;
}


int addr_allocator_free(const uint64_t addr, const uint64_t size) {
    // Check if address belongs to this node
    if (addr < g_base_addr || addr >= g_base_addr + OBMM_NODE_ADDR_SPACE_SIZE) {
        fprintf(stderr, "[Node %d] Address 0x%lx does not belong to this node (base=0x%lx)\n",
                g_node_id, addr, g_base_addr);
        return -1;
    }

    const uint64_t offset = addr - g_base_addr;
    const int order = size_to_order(size);
    const uint64_t block_size = order_to_size(order);

    // Verify offset is aligned
    if (offset % block_size != 0) {
        fprintf(stderr, "[Node %d] Address 0x%lx is not aligned to size %lu\n",
                g_node_id, addr, block_size);
        return -1;
    }

    // Try to merge with buddy
    uint64_t current_offset = offset;
    int current_order = order;
    const int max_order = get_max_order();

    while (current_order < max_order) {
        uint64_t buddy_offset = get_buddy_offset(current_offset, current_order);

        // Check if buddy is free
        bool buddy_found = false;
        free_block *prev = nullptr;
        free_block *curr = free_lists[current_order];

        while (curr) {
            if (curr->offset == buddy_offset) {
                if (prev) {
                    prev->next = curr->next;
                } else {
                    free_lists[current_order] = curr->next;
                }

                // Merge: use the lower offset
                current_offset = std::min(current_offset, buddy_offset);
                current_order++;

                delete curr;
                buddy_found = true;
                break;
            }
            prev = curr;
            curr = curr->next;
        }

        if (!buddy_found) {
            break;
        }
    }

    // Add merged block to free list
    const auto block = new free_block(current_offset, free_lists[current_order]);
    free_lists[current_order] = block;
    total_allocated -= order_to_size(order);

    printf("[Node %d] Freed address: offset=0x%lx, size=%lu (order=%d), global_addr=0x%lx\n",
           g_node_id, offset, block_size, order, addr);

    return 0;
}

