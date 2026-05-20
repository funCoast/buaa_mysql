#ifndef LIBOBMM_H
#define LIBOBMM_H

#include <stdint.h>
#include <stddef.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define OBMM_MAX_LOCAL_NUMA_NODES 2
#define OBMM_EXPORT_FLAG_ALLOW_MMAP 0x1
#define OBMM_EXPORT_FLAG_FAST 0x2

#define OBMM_INVALID_MEMID 0
#define MAX_PATH_LEN 256

typedef uint64_t mem_id;

struct obmm_mem_desc {
    uint64_t addr;
    uint64_t length;
    /* 128bit eid, ordered by little-endian */
    uint8_t seid[16];     // UB Controller info
    uint8_t deid[16];     // Ignored
    uint32_t tokenid;     // Ignored
    uint32_t scna;        // UB Controller info
    uint32_t dcna;        // Ignored
    uint16_t priv_len;    // Sysfs info
    uint8_t  priv[];      // Sysfs info
};

mem_id obmm_export(const size_t length[OBMM_MAX_LOCAL_NUMA_NODES], unsigned long flags, struct obmm_mem_desc *desc);
int obmm_unexport(mem_id id, unsigned long flags);
mem_id obmm_import(const struct obmm_mem_desc *desc, unsigned long flags, int base_dist, int *numa);
int obmm_unimport(mem_id id, unsigned long flags);

// Stop all simulator processes
int obmm_simulator_finish(void);



/*
 * Set the ownership (reader, writer, none) of a range of OBMM virtual address space.
 * @fd: The file descriptor of an OBMM memory device.
 * @start: The start virtual address.
 * @end: The end virtual address.
 * @prot: The ownership expressed as memory protection bits (PROT_NONE, PROT_READ, PROT_WRITE).
 *        NOTE: PROT_WRITE implies PROT_READ.
 */
int obmm_set_ownership(int fd, void *start, void *end, int prot);

#if defined(__cplusplus)
}
#endif

#endif