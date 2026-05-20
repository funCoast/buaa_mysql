#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include "addr_table.h"
#include "addr_allocator.h"
#include <stdio.h>
#include <unistd.h>
#include <mpi.h>

int main(int argc, char *argv[]) {
    int rank, size;
    
    if (addr_table_init(&rank, &size) != 0) {
        fprintf(stderr, "Failed to initialize address table\n");
        return 1;
    }
    
    // Initialize address allocator
    if (addr_allocator_init(rank) != 0) {
        fprintf(stderr, "[Node %d] Failed to initialize address allocator\n", rank);
        addr_table_finalize();
        return 1;
    }
    
    printf("[Node %d] Simulator started (total %d nodes)\n", rank, size);
    
    // Start socket server for client communication
    obmm_simulator_start_server(rank);
    
    MPI_Barrier(MPI_COMM_WORLD);
    
    // Rank0: service thread is running in background
    // Main thread can continue with other tasks
    if (rank == 0) {
        printf("[Node 0] Service thread running, main thread continues...\n");
        printf("[Node 0] Waiting for client connections...\n");
    } else {
        printf("[Node %d] Waiting for client connections...\n", rank);
    }
    
    // Main loop: keep running until stopped by client
    // The socket server thread handles client requests
    // When client sends FINISH message, the server thread will call exit(0)
    while (1) {
        sleep(1); // Sleep and check periodically
        // The server thread will exit the process when receiving FINISH message
    }
    return 0;
}
