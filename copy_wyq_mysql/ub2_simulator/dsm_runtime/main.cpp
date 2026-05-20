#include <cstdint>
#include <sys/types.h>
#define _POSIX_C_SOURCE 200809L
#include "libobmm.h"
#include <errno.h>
#include <fcntl.h>
#include <mpi.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define ARRAY_SIZE 1024 // 1024 integers = 4KB

class DSM_Runtime {
private:
  DSM_actor *actors_;
  int32_t node_num_;

public:
  DSM_Runtime(int32_t node_num, uint64_t os_page_num) {
    // Initialize DSM runtime with given parameters
  }
  void register_actor(DSM_actor *actor) {
    // Register a DSM actor
  }

  ~DSM_Runtime() {
    // Cleanup DSM runtime
  }
};

// per_node 4KB x mem
void init_dsm(int32_t node_num, uint64_t os_page_num) {}

int main(int argc, char *argv[]) {
  int mpi_rank, mpi_size;

  // Initialize MPI
  if (MPI_Init(&argc, &argv) != MPI_SUCCESS) {
    fprintf(stderr, "MPI_Init failed\n");
    return 1;
  }

  MPI_Comm_rank(MPI_COMM_WORLD, &mpi_rank);
  MPI_Comm_size(MPI_COMM_WORLD, &mpi_size);

  if (mpi_size < 2) {
    fprintf(stderr, "This program requires at least 2 User Processes\n");
    MPI_Finalize();
    return 1;
  }

  printf("[User Process %d] Starting...\n", mpi_rank);
  int32_t node_num = 48; // Total simulator nodes
  if (mpi_rank == 0) {
    uint64_t *addr_from_remote = new uint64_t[node_num];
    
    for (int32_t i = 1; i < node_num; ++i) {
      MPI_Recv(&addr_from_remote[i], 1, MPI_UINT64_T, i, i, MPI_COMM_WORLD,
               MPI_STATUS_IGNORE);
      setenv("OBMM_TARGET_NODE", "0", 0);
      struct obmm_mem_desc import_desc;
      memset(&import_desc, 0, sizeof(import_desc));
      import_desc.addr = addr;
      import_desc.length = ARRAY_SIZE * sizeof(int);
      mem_id import_memid =
          obmm_import(&import_desc, OBMM_EXPORT_FLAG_ALLOW_MMAP, 0, NULL);
      if (import_memid == OBMM_INVALID_MEMID) {
        fprintf(stderr, "[User Process 1] Failed to import memory\n");
        MPI_Finalize();
        return 1;
      }
      char shm_path[256];
      snprintf(shm_path, sizeof(shm_path),
               "/dev/shm/virtual_node1/obmm_shmdev%ld", import_memid);
      int fd = open(shm_path, O_RDWR);
      int *array = (int *)mmap(NULL, ARRAY_SIZE * sizeof(int),
                               PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
      // TODO: register array to DSM runtime obj
      close(fd);

    }

    // Process 0: Export memory on simulator node 0
    printf("[User Process 0] Connecting to simulator node 0 to export "
           "memory...\n");

    // Set target node to 0
    setenv("OBMM_TARGET_NODE", "0", 1);

    // Prepare export parameters
    size_t length[OBMM_MAX_LOCAL_NUMA_NODES] = {ARRAY_SIZE * sizeof(int), 0};
    struct obmm_mem_desc desc;
    memset(&desc, 0, sizeof(desc));
    desc.addr = 0; // Address will be allocated by server
    desc.length = 0;

    printf("[User Process 0] Exporting %zu bytes...\n", length[0]);
    mem_id memid = obmm_export(length, OBMM_EXPORT_FLAG_ALLOW_MMAP, &desc);

    if (memid == OBMM_INVALID_MEMID) {
      fprintf(stderr, "[User Process 0] Failed to export memory\n");
      MPI_Finalize();
      return 1;
    }

    printf("[User Process 0] Successfully exported memory:\n");
    printf("  mem_id = %ld\n", memid);
    printf("  address = 0x%lx\n", desc.addr);
    printf("  length = %lu bytes\n", desc.length);

    // Send address to process 1
    uint64_t exported_addr = desc.addr;
    MPI_Send(&exported_addr, 1, MPI_UINT64_T, 1, 0, MPI_COMM_WORLD);
    printf("[User Process 0] Sent address 0x%lx to process 1\n", exported_addr);

    // Wait for process 1 to finish
    int done;
    MPI_Recv(&done, 1, MPI_INT, 1, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    printf("[User Process 0] Process 1 finished, cleaning up...\n");

    // Unexport
    printf("[User Process 0] Unexporting memory (mem_id=%ld)...\n", memid);
    int ret = obmm_unexport(memid, 0);
    if (ret == 0) {
      printf("[User Process 0] Successfully unexported\n");
    } else {
      fprintf(stderr, "[User Process 0] Failed to unexport\n");
    }

  }
  // node 1~47
  else {
    // Receive address from process 0
    uint64_t addr;
    MPI_Recv(&addr, 1, MPI_UINT64_T, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
    printf("[User Process 1] Received address 0x%lx from process 0\n", addr);

    // Set target node to 1 (where we want to import)
    setenv("OBMM_TARGET_NODE", "1", 1);

    // Prepare import parameters
    struct obmm_mem_desc import_desc;
    memset(&import_desc, 0, sizeof(import_desc));
    import_desc.addr = addr;
    import_desc.length = ARRAY_SIZE * sizeof(int);

    printf("[User Process 1] Importing memory at address 0x%lx on simulator "
           "node 1...\n",
           addr);
    mem_id import_memid =
        obmm_import(&import_desc, OBMM_EXPORT_FLAG_ALLOW_MMAP, 0, NULL);

    if (import_memid == OBMM_INVALID_MEMID) {
      fprintf(stderr, "[User Process 1] Failed to import memory\n");
      MPI_Finalize();
      return 1;
    }

    printf("[User Process 1] Successfully imported memory:\n");
    printf("  local_mem_id = %ld\n", import_memid);
    printf("  address = 0x%lx\n", import_desc.addr);
    printf("  length = %lu bytes\n", import_desc.length);

    // Map the shared memory as an array
    // The symlink path should be:
    // /dev/shm/virtual_node1/obmm_shmdev{import_memid}
    char shm_path[256];
    snprintf(shm_path, sizeof(shm_path),
             "/dev/shm/virtual_node1/obmm_shmdev%ld", import_memid);

    printf("[User Process 1] Opening shared memory file: %s\n", shm_path);
    int fd = open(shm_path, O_RDWR);
    if (fd < 0) {
      fprintf(stderr, "[User Process 1] Failed to open %s: %s\n", shm_path,
              strerror(errno));
      MPI_Finalize();
      return 1;
    }

    // Map the memory
    int *array = (int *)mmap(NULL, ARRAY_SIZE * sizeof(int),
                             PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    if (array == MAP_FAILED) {
      fprintf(stderr, "[User Process 1] mmap failed: %s\n", strerror(errno));
      MPI_Finalize();
      return 1;
    }

    printf("[User Process 1] Successfully mapped memory as array at %p\n",
           array);

    // Use the array
    printf("[User Process 1] Using imported memory as an array...\n");

    // Initialize array with values
    for (int i = 0; i < ARRAY_SIZE; i++) {
      array[i] = i * 2; // Fill with even numbers
    }

    printf("[User Process 1] Array initialized. Sample values:\n");
    printf("  array[0] = %d\n", array[0]);
    printf("  array[100] = %d\n", array[100]);
    printf("  array[%d] = %d\n", ARRAY_SIZE - 1, array[ARRAY_SIZE - 1]);

    // Modify some values
    array[0] = 999;
    array[ARRAY_SIZE / 2] = 888;
    printf("[User Process 1] Modified array[0] = %d, array[%d] = %d\n",
           array[0], ARRAY_SIZE / 2, array[ARRAY_SIZE / 2]);

    // Unmap
    if (munmap(array, ARRAY_SIZE * sizeof(int)) != 0) {
      fprintf(stderr, "[User Process 1] munmap failed: %s\n", strerror(errno));
    } else {
      printf("[User Process 1] Successfully unmapped memory\n");
    }

    // Notify process 0 that we're done
    int done = 1;
    MPI_Send(&done, 1, MPI_INT, 0, 0, MPI_COMM_WORLD);
  }

  // Synchronize all processes
  MPI_Barrier(MPI_COMM_WORLD);

  // Process 0 stops the simulator
  if (mpi_rank == 0) {
    printf("[User Process 0] Stopping simulator...\n");
    int ret = obmm_simulator_finish();
    if (ret == 0) {
      printf("[User Process 0] Successfully stopped simulator\n");
    } else {
      fprintf(stderr, "[User Process 0] Failed to stop simulator\n");
    }
  }

  MPI_Finalize();
  printf("[User Process %d] Exiting\n", mpi_rank);
  return 0;
}
