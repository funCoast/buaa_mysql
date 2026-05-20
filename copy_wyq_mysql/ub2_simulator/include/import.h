#ifndef IMPORT_H
#define IMPORT_H

#include <stdint.h>
#include <stddef.h>

#include "libobmm.h"

#ifdef __cplusplus
extern "C" {
#endif

// Import shared memory from remote node
// Creates directory structure and symlink to remote node's shared memory file
// local_node_id: current node ID
// local_mem_id: local memory ID (for symlink name)
// remote_node_id: node ID where the memory is exported
// remote_mem_id: remote memory ID (for source file)
// Returns 0 on success, -1 on failure
int obmm_import_shm(int local_node_id, mem_id local_mem_id, int remote_node_id, mem_id remote_mem_id);

// Unimport shared memory (remove symlink and directory if empty)
// local_node_id: current node ID
// local_mem_id: local memory ID (for symlink name)
// Returns 0 on success, -1 on failure
int obmm_unimport_shm(int local_node_id, mem_id local_mem_id);

#ifdef __cplusplus
}
#endif

#endif // IMPORT_H

