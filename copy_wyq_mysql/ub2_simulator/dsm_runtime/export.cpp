#include <iostream>
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
#include "dsm_config.h"

static size_t export_bytes_per_node() {
  const char *v = getenv("DSM_CACHE_BYTES_PER_NODE");
  if (!(v && *v)) {
    v = getenv("DSM_BRIDGE_BYTES_PER_NODE");
  }
  if (!(v && *v)) {
    return ARRAY_SIZE * sizeof(int);
  }
  char *end = nullptr;
  errno = 0;
  const auto parsed = strtoull(v, &end, 10);
  if (errno != 0 || end == v || (end != nullptr && *end != '\0')) {
    return ARRAY_SIZE * sizeof(int);
  }
  return static_cast<size_t>(parsed);
}

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

  if (mpi_rank == 0) {
    setenv("OBMM_TARGET_NODE", "0", 1);
  } else if (mpi_rank == 1) {
    setenv("OBMM_TARGET_NODE", "1", 1);
  } else if (mpi_rank == 2) {
    setenv("OBMM_TARGET_NODE", "2", 1);
  } else if (mpi_rank == 3) {
    setenv("OBMM_TARGET_NODE", "3", 1);
  } else if (mpi_rank == 4) {
    setenv("OBMM_TARGET_NODE", "4", 1);
  } else if (mpi_rank == 5) {
    setenv("OBMM_TARGET_NODE", "5", 1);
  }
  else {
    fprintf(stderr, "This program requires at least 2 User Processes\n");
    MPI_Finalize();
    return 1;
  }

  printf("[User Process %d] Starting...\n", mpi_rank);

  if (mpi_rank == 0) {
    std::cout << "mpi_size=" << mpi_size << std::endl; 
    uint64_t *addr_from_remote = new uint64_t[mpi_size - 1];
    for (int i = 1; i < mpi_size; i++) {
      // Receive address from process i
      uint64_t received_addr;
      MPI_Recv(&received_addr, 1, MPI_UINT64_T, i, 0, MPI_COMM_WORLD,
               MPI_STATUS_IGNORE);
      addr_from_remote[i - 1] = received_addr;
      printf(
          "[User Process 0] Received exported address 0x%lx from process %d\n",
          received_addr, i);

      struct obmm_mem_desc import_desc;
      memset(&import_desc, 0, sizeof(import_desc));
      import_desc.addr = received_addr;
      import_desc.length = export_bytes_per_node();

      mem_id import_memid =
          obmm_import(&import_desc, OBMM_EXPORT_FLAG_ALLOW_MMAP, 0, NULL);

      if (import_memid == OBMM_INVALID_MEMID) {
        fprintf(stderr, "[User Process %d] Failed to import memory\n", mpi_rank);
        MPI_Finalize();
        return 1;
      }
      char shm_path[256];
      snprintf(shm_path, sizeof(shm_path),
               "/dev/shm/virtual_node%d/obmm_shmdev%ld",mpi_rank, import_memid);

      printf("[User Process %d] Opening shared memory file: %s\n",mpi_rank, shm_path);
      int fd = open(shm_path, O_RDWR);
      if (fd < 0) {
        fprintf(stderr, "[User Process %d] Failed to open %s: %s\n",mpi_rank, shm_path,
                strerror(errno));
        MPI_Finalize();
        return 1;
      }
      close(fd);
    }
    delete[] addr_from_remote;
  } else {
    const int target_node = strtol(getenv("OBMM_TARGET_NODE"), nullptr, 10);
    std::cout << "[User Process "<< mpi_rank << "] Connecting to simulator node " << target_node
              << std::endl;

    // Prepare export parameters
    size_t length[OBMM_MAX_LOCAL_NUMA_NODES] = {export_bytes_per_node(), 0};
    struct obmm_mem_desc desc;
    memset(&desc, 0, sizeof(desc));
    desc.addr = 0; // Address will be allocated by server
    desc.length = 0;

    printf("[User Process %d] Exporting %zu bytes...\n", mpi_rank, length[0]);
    mem_id memid = obmm_export(length, OBMM_EXPORT_FLAG_ALLOW_MMAP, &desc);

    if (memid == OBMM_INVALID_MEMID) {
      fprintf(stderr, "[User Process 0] Failed to export memory\n");
      MPI_Finalize();
      return 1;
    }

    printf("[User Process %d] Successfully exported memory:\n", mpi_rank);
    printf("  mem_id = %ld\n", memid);
    printf("  address = 0x%lx\n", desc.addr);
    printf("  length = %lu bytes\n", desc.length);

    // Send address to process 0
    uint64_t exported_addr = desc.addr;
    MPI_Send(&exported_addr, 1, MPI_UINT64_T, 0, 0, MPI_COMM_WORLD);
  }

  MPI_Finalize();
  return 0;
}
