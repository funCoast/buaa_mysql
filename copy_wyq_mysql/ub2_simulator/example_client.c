#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <stddef.h>
#include "libobmm.h"

int main(int argc, char *argv[]) {
    printf("OBMM Client Example\n");
    printf("==================\n\n");
    
    // Check if target node is specified
    const char *target_node = getenv("OBMM_TARGET_NODE");
    if (target_node) {
        printf("Target node: %s\n", target_node);
    } else {
        printf("Target node: 0 (default, set OBMM_TARGET_NODE to change)\n");
    }
    printf("\n");
    
    // Prepare export parameters
    size_t length[OBMM_MAX_LOCAL_NUMA_NODES] = {1024 * 1024, 0}; // 1MB from NUMA node 0
    struct obmm_mem_desc desc;
    memset(&desc, 0, sizeof(desc));
    desc.addr = 0;  // Address will be allocated by server
    desc.length = 0; // Will be set from length[0]
    
    printf("Step 1: Exporting memory (size: %zu bytes)...\n", length[0]);
    mem_id memid = obmm_export(length, OBMM_EXPORT_FLAG_ALLOW_MMAP, &desc);
    
    if (memid == OBMM_INVALID_MEMID) {
        fprintf(stderr, "Failed to export memory\n");
        return 1;
    }
    
    printf("  Success! mem_id = %ld\n", memid);
    printf("  Address: 0x%lx\n", desc.addr);
    printf("  Length: %lu\n", desc.length);
    printf("\n");
    
    // Wait a bit to demonstrate the export is working
    printf("Step 2: Memory exported, waiting 2 seconds...\n");
    sleep(2);
    printf("\n");
    
    // Export another memory region
    printf("Step 3: Exporting another memory region (size: %zu bytes)...\n", length[0] * 2);
    size_t length2[OBMM_MAX_LOCAL_NUMA_NODES] = {length[0] * 2, 0};
    struct obmm_mem_desc desc2;
    memset(&desc2, 0, sizeof(desc2));
    desc2.addr = 0;
    desc2.length = 0;
    
    mem_id memid2 = obmm_export(length2, OBMM_EXPORT_FLAG_ALLOW_MMAP, &desc2);
    
    if (memid2 == OBMM_INVALID_MEMID) {
        fprintf(stderr, "Failed to export second memory region\n");
    } else {
        printf("  Success! mem_id = %ld\n", memid2);
        printf("  Address: 0x%lx\n", desc2.addr);
        printf("  Length: %lu\n", desc2.length);
    }
    printf("\n");
    
    // Test import from another node (if we have multiple nodes)
    printf("Step 4: Testing import...\n");
    const char *import_target_node = getenv("OBMM_IMPORT_TARGET_NODE");
    if (import_target_node) {
        int import_node = atoi(import_target_node);
        printf("  Attempting to import from node %d\n", import_node);
        
        // Try to import the first exported memory (desc.addr)
        struct obmm_mem_desc import_desc;
        memset(&import_desc, 0, sizeof(import_desc));
        import_desc.addr = desc.addr;  // Use address from first export
        import_desc.length = desc.length;
        
        // Temporarily set target node for import
        char old_target[32] = {0};
        const char *old_target_env = getenv("OBMM_TARGET_NODE");
        if (old_target_env) {
            strncpy(old_target, old_target_env, sizeof(old_target) - 1);
        }
        setenv("OBMM_TARGET_NODE", import_target_node, 1);
        
        mem_id import_memid = obmm_import(&import_desc, OBMM_EXPORT_FLAG_ALLOW_MMAP, 0, NULL);
        
        // Restore original target node
        if (old_target[0] != '\0') {
            setenv("OBMM_TARGET_NODE", old_target, 1);
        } else {
            unsetenv("OBMM_TARGET_NODE");
        }
        
        if (import_memid == OBMM_INVALID_MEMID) {
            fprintf(stderr, "  Failed to import memory (this is expected if node %d doesn't exist or address not found)\n", import_node);
        } else {
            printf("  Success! Imported mem_id = %ld\n", import_memid);
            printf("  Address: 0x%lx\n", import_desc.addr);
            printf("  Length: %lu\n", import_desc.length);
            
            // Wait a bit
            sleep(1);
            
            // Test unimport
            printf("\n  Testing unimport...\n");
            int import_ret = obmm_unimport(import_memid, 0);
            if (import_ret == 0) {
                printf("  Successfully unimported\n");
            } else {
                fprintf(stderr, "  Failed to unimport\n");
            }
        }
    } else {
        printf("  Skipping import test (set OBMM_IMPORT_TARGET_NODE to test import)\n");
        printf("  Example: OBMM_IMPORT_TARGET_NODE=1 OBMM_TARGET_NODE=0 ./example_client\n");
    }
    printf("\n");
    
    // Unexport the first memory
    printf("Step 5: Unexporting first memory region (mem_id = %ld)...\n", memid);
    int ret = obmm_unexport(memid, 0);
    if (ret == 0) {
        printf("  Successfully unexported\n");
    } else {
        fprintf(stderr, "  Failed to unexport\n");
    }
    printf("\n");
    
    // Wait a bit
    printf("Step 6: Waiting 1 second before finishing...\n");
    sleep(1);
    printf("\n");
    
    // Unexport the second memory
    printf("Step 7: Unexporting second memory region (mem_id = %ld)...\n", memid2);
    ret = obmm_unexport(memid2, 0);
    if (ret == 0) {
        printf("  Successfully unexported\n");
    } else {
        fprintf(stderr, "  Failed to unexport\n");
    }
    printf("\n");
    
    // Finish simulator
    printf("Step 8: Stopping simulator...\n");
    ret = obmm_simulator_finish();
    if (ret == 0) {
        printf("  Successfully sent finish message to simulator nodes\n");
    } else {
        fprintf(stderr, "  Failed to stop simulator\n");
    }
    
    printf("\nExample completed!\n");
    return 0;
}

