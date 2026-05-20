#include "import.h"
#include "addr_table.h"
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <unistd.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "libobmm.h"

// Recursively create directory
static int create_dir_recursive(const char *path) {
    char tmp[MAX_PATH_LEN];
    char *p = nullptr;
    
    snprintf(tmp, sizeof(tmp), "%s", path);
    const size_t len = strlen(tmp);
    
    // Remove trailing slash
    if (len > 0 && tmp[len - 1] == '/') {
        tmp[len - 1] = 0;
    }
    
    // Create parent directories
    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                fprintf(stderr, "Failed to create directory %s: %s\n", tmp, strerror(errno));
                return -1;
            }
            *p = '/';
        }
    }
    
    // Create final directory
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "Failed to create directory %s: %s\n", tmp, strerror(errno));
        return -1;
    }
    
    return 0;
}

// Get path for local import directory
static int get_import_dir_path(const int local_node_id, char *path) {
    int ret = snprintf(path, MAX_PATH_LEN, "/dev/shm/virtual_node%d", local_node_id);
    return (ret < 0 || static_cast<size_t>(ret) >= MAX_PATH_LEN) ? -1 : 0;
}

// Get path for remote export file
static int get_remote_export_path(const int remote_node_id, const mem_id remote_mem_id, char *path) {
    const int ret = snprintf(path, MAX_PATH_LEN, "/dev/shm/virtual_node%d/obmm_shmdev%ld",
                       remote_node_id, remote_mem_id);
    return (ret < 0 || static_cast<size_t>(ret) >= MAX_PATH_LEN) ? -1 : 0;
}

// Get path for local import symlink
static int get_import_symlink_path(int local_node_id, const mem_id local_mem_id, char *path) {
    const int ret = snprintf(path, MAX_PATH_LEN, "/dev/shm/virtual_node%d/obmm_shmdev%ld",
                       local_node_id, local_mem_id);
    return (ret < 0 || static_cast<size_t>(ret) >= MAX_PATH_LEN) ? -1 : 0;
}

int obmm_import_shm(const int local_node_id, const mem_id local_mem_id,
    const int remote_node_id, const mem_id remote_mem_id) {
    // Get paths
    char import_dir[MAX_PATH_LEN];
    if (get_import_dir_path(local_node_id, import_dir) != 0) {
        fprintf(stderr, "Path too long for import directory\n");
        return -1;
    }
    
    char remote_path[MAX_PATH_LEN];
    if (get_remote_export_path(remote_node_id, remote_mem_id, remote_path) != 0) {
        fprintf(stderr, "Path too long for remote export path\n");
        return -1;
    }
    
    char symlink_path[MAX_PATH_LEN];
    if (get_import_symlink_path(local_node_id, local_mem_id, symlink_path) != 0) {
        fprintf(stderr, "Path too long for symlink path\n");
        return -1;
    }
    
    // Check if remote file exists
    struct stat st{};
    if (stat(remote_path, &st) != 0) {
        fprintf(stderr, "Remote shared memory file does not exist: %s\n", remote_path);
        return -1;
    }
    
    // Create directory recursively
    if (create_dir_recursive(import_dir) != 0) {
        return -1;
    }
    
    // Check if symlink already exists
    if (lstat(symlink_path, &st) == 0) {
        // Check if it's already a symlink to the correct target
        char link_target[256];
        const ssize_t len = readlink(symlink_path, link_target, sizeof(link_target) - 1);
        if (len >= 0) {
            link_target[len] = '\0';
            if (strcmp(link_target, remote_path) == 0) {
                // Already linked correctly
                printf("[Node %d] Import symlink already exists: %s -> %s\n", 
                       local_node_id, symlink_path, remote_path);
                return 0;
            }
        }
        // Remove existing file/symlink
        if (unlink(symlink_path) != 0) {
            fprintf(stderr, "Failed to remove existing symlink: %s\n", symlink_path);
            return -1;
        }
    }
    
    // Create symlink
    if (symlink(remote_path, symlink_path) != 0) {
        fprintf(stderr, "Failed to create symlink %s -> %s: %s\n", 
                symlink_path, remote_path, strerror(errno));
        return -1;
    }
    
    printf("[Node %d] Imported shared memory: %s -> %s (local_mem_id=%ld, remote_mem_id=%ld)\n", 
           local_node_id, symlink_path, remote_path, local_mem_id, remote_mem_id);
    
    return 0;
}

int obmm_unimport_shm(const int local_node_id,const mem_id local_mem_id) {
    char symlink_path[MAX_PATH_LEN];
    if (get_import_symlink_path(local_node_id, local_mem_id, symlink_path) != 0) {
        return -1;
    }
    
    // Check if symlink exists
    struct stat st{};
    if (lstat(symlink_path, &st) != 0) {
        if (errno == ENOENT) {
            // Already removed, that's fine
            return 0;
        }
        fprintf(stderr, "Failed to stat symlink %s: %s\n", symlink_path, strerror(errno));
        return -1;
    }
    
    // Remove symlink
    if (unlink(symlink_path) != 0) {
        fprintf(stderr, "Failed to remove symlink %s: %s\n", symlink_path, strerror(errno));
        return -1;
    }
    
    printf("[Node %d] Unimported shared memory: %s\n", local_node_id, symlink_path);

    return 0;
}

