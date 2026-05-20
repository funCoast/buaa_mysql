#include "export.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>
#include <cstdio>
#include <cstdlib>

// Recursively create directory
static int create_dir_recursive(const char *path) {
    char tmp[1024];
    char *p = nullptr;

    snprintf(tmp, sizeof(tmp), "%s", path);
    const size_t len = strlen(tmp);
    
    // Remove trailing slash
    if (tmp[len - 1] == '/') {
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

int obmm_export_shm(const uint64_t size, const int node_id, const int64_t mem_id,
                    char *path, const size_t path_size, void **mapped_addr) {
    if (path == nullptr || mapped_addr == nullptr || path_size == 0) {
        return -1;
    }
    
    // Construct full path:
    const int ret = snprintf(path, path_size, "/dev/shm/virtual_node%d/obmm_shmdev%ld",
                       node_id, mem_id);
    if (ret < 0 || static_cast<size_t>(ret) >= path_size) {
        fprintf(stderr, "Path too long\n");
        return -1;
    }

    char dir_path[1024];
    snprintf(dir_path, sizeof(dir_path), "/dev/shm/virtual_node%d", node_id);
    if (create_dir_recursive(dir_path) != 0) {
        return -1;
    }

    const int fd = open(path, O_CREAT | O_RDWR, 0666);
    if (fd < 0) {
        fprintf(stderr, "open failed for %s: %s\n", path, strerror(errno));
        return -1;
    }
    
    // Set size
    if (ftruncate(fd, static_cast<__off_t>(size)) != 0) {
        fprintf(stderr, "ftruncate failed: %s\n", strerror(errno));
        close(fd);
        unlink(path);
        return -1;
    }
    
    // Map into memory
    void *addr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) {
        fprintf(stderr, "mmap failed: %s\n", strerror(errno));
        close(fd);
        unlink(path);
        return -1;
    }
    
    // Close fd (mmap keeps the mapping)
    close(fd);
    
    *mapped_addr = addr;
    
    printf("[Node %d] Exported shared memory: path=%s, size=%lu, addr=%p\n", 
           node_id, path, size, addr);
    
    return 0;
}

int obmm_unexport_shm(const char *path, void *mapped_addr, uint64_t size) {
    if (path == nullptr || mapped_addr == nullptr) {
        return -1;
    }
    
    // Unmap memory
    if (munmap(mapped_addr, size) != 0) {
        fprintf(stderr, "munmap failed: %s\n", strerror(errno));
        return -1;
    }
    
    // Unlink the file
    if (unlink(path) != 0) {
        fprintf(stderr, "unlink failed for %s: %s\n", path, strerror(errno));
        return -1;
    }
    
    printf("Unexported shared memory: path=%s\n", path);
    
    return 0;
}

