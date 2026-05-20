#include "addr_table.h"
#include "import.h"
#include "addr_allocator.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/select.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>
#include <thread>
#include <unordered_map>
#include <cstdio>
#include <cstdlib>
#include <libobmm_client.h>

static int g_socket_fd = -1;
static volatile bool g_server_running = true;

// Local mapping for mem_id -> addr (per node) - for export
static std::unordered_map<mem_id, uint64_t> g_mem_id_to_addr;

// Import info structure
struct import_info {
    uint64_t addr;           // Global address
    int remote_node_id;      // Remote node ID
    mem_id remote_mem_id;   // Remote mem_id
    uint64_t length;         // Memory length
};

// Local mapping for local_mem_id -> import_info (per node) - for import
static std::unordered_map<mem_id, import_info> g_import_mem_id_to_info;

// Handle client request
static void handle_client_request(const int client_fd,const int rank) {
    printf("[Node %d] Received client connection\n", rank);
    auto req = client_request();
    const ssize_t n = recv(client_fd, &req, sizeof(req), 0);
    
    if (n != sizeof(req)) {
        if (n < 0) {
            fprintf(stderr, "[Node %d] recv failed: %s\n", rank, strerror(errno));
        }
        close(client_fd);
        return;
    }
    
    auto resp = client_response();
    memset(&resp, 0, sizeof(resp));
    
    if (req.msg_type == CLIENT_MSG_EXPORT) {
        // Export request
        uint64_t length = req.desc_length;
        if (length == 0) {
            length = req.length[0]; // Use first NUMA node size
        }
        
        if (length == 0) {
            resp.success = -1;
            resp.id = 0; // OBMM_INVALID_MEM_ID
            fprintf(stderr, "[Node %d] Invalid length: 0\n", rank);
        } else {
            // Allocate address from allocator
            const uint64_t addr = addr_allocator_alloc(length);
            if (addr == 0) {
                resp.success = -1;
                resp.id = 0; // OBMM_INVALID_MEM_ID
                resp.addr = 0;
                resp.length = 0;
                fprintf(stderr, "[Node %d] Failed to allocate address for size %lu\n", rank, length);
            } else {
                // Generate local mem_id (atomic increment using shared counter)
                const int64_t mem_id = g_local_mem_id.fetch_add(1) + 1;
                
                // Add to address table
                const int ret = addr_table_add(addr, rank, mem_id, length);
                if (ret == 0) {
                    resp.success = 0;
                    resp.id = mem_id;
                    resp.addr = addr;
                    resp.length = length;
                    g_mem_id_to_addr[mem_id] = addr;
                    printf("[Node %d] Client export: addr=0x%lx, length=%lu, mem_id=%ld\n", 
                           rank, addr, length, mem_id);
                } else {
                    // Allocation failed, free the address
                    addr_allocator_free(addr, length);
                    resp.success = -1;
                    resp.id = 0; // OBMM_INVALID_MEM_ID
                    resp.addr = 0;
                    resp.length = 0;
                    fprintf(stderr, "[Node %d] Failed to add to address table\n", rank);
                }
            }
        }
        
    } else if (req.msg_type == CLIENT_MSG_IMPORT) {
        // Import request - query address table and create symlink if needed
        const uint64_t addr = req.addr;
        
        // Query address table to get node_id and mem_id
        addr_table_entry entry;
        const int query_ret = addr_table_query(addr, &entry);
        if (query_ret != 0) {
            resp.success = -1;
            resp.id = 0; // OBMM_INVALID_MEM_ID
            resp.addr = 0;
            resp.length = 0;
            fprintf(stderr, "[Node %d] IMPORT: address 0x%lx not found in address table\n", rank, addr);
        } else {
            // Check if memory is on this node
            if (entry.node_id == rank) {
                // Memory is on this node, no need to import
                resp.success = 0;
                resp.id = entry._mem_id;
                resp.addr = addr;
                resp.length = entry.length;
                printf("[Node %d] IMPORT: address 0x%lx is already on this node (node_id=%d), no import needed\n",
                       rank, addr, entry.node_id);
            } else {
                // Memory is on remote node, create symlink with local mem_id
                // Generate local mem_id (atomic increment using shared counter)
                const int64_t local_mem_id = g_local_mem_id.fetch_add(1) + 1;
                
                // Create symlink using local mem_id
                const int import_ret = obmm_import_shm(rank,
                    local_mem_id, entry.node_id, entry._mem_id);
                if (import_ret == 0) {
                    // Store import info
                    const auto info = import_info({addr, entry.node_id, entry._mem_id, entry.length});
                    g_import_mem_id_to_info[local_mem_id] = info;
                    resp.success = 0;
                    resp.id = local_mem_id;  // Return local mem_id
                    resp.addr = addr;
                    resp.length = entry.length;
                    printf("[Node %d] IMPORT: successfully imported from node %d, "
                           "local_mem_id=%ld, remote_mem_id=%ld\n",
                           rank, entry.node_id, local_mem_id, entry._mem_id);
                } else {
                    resp.success = -1;
                    resp.id = 0; // OBMM_INVALID_MEM_ID
                    resp.addr = 0;
                    resp.length = 0;
                    fprintf(stderr, "[Node %d] IMPORT: failed to create symlink\n", rank);
                }
            }
        }
        
    } else if (req.msg_type == CLIENT_MSG_UNIMPORT) {
        // Unimport request - remove symlink using local mem_id
        const mem_id local_mem_id = req.id;
        
        // Find import info by local mem_id
        const auto it = g_import_mem_id_to_info.find(local_mem_id);
        if (it == g_import_mem_id_to_info.end()) {
            resp.success = -1;
            fprintf(stderr, "[Node %d] UNIMPORT: "
                            "local_mem_id %ld not found in import records\n", rank, local_mem_id);
        } else {
            const import_info &info = it->second;
            
            // Remove symlink
            const int unimport_ret = obmm_unimport_shm(rank, local_mem_id);
            if (unimport_ret == 0) {
                // Remove from import records
                g_import_mem_id_to_info.erase(it);
                resp.success = 0;
                printf("[Node %d] UNIMPORT: successfully removed symlink for local_mem_id=%ld (addr=0x%lx)\n",
                       rank, local_mem_id, info.addr);
            } else {
                resp.success = -1;
                fprintf(stderr, "[Node %d] UNIMPORT: failed to remove symlink\n", rank);
            }
        }
        
    } else if (req.msg_type == CLIENT_MSG_UNEXPORT) {
        // Unexport request - find entry by mem_id and remove
        const auto it = g_mem_id_to_addr.find(req.id);
        if (it != g_mem_id_to_addr.end()) {
            const uint64_t addr = it->second;
            
            // Query to get the length
            struct addr_table_entry entry;
            const int query_ret = addr_table_query(addr, &entry);
            if (query_ret == 0) {
                // Remove from address table
                resp.success = addr_table_remove(addr);
                if (resp.success == 0) {
                    // Free the address
                    addr_allocator_free(addr, entry.length);
                    g_mem_id_to_addr.erase(it);
                }
            } else {
                resp.success = -1;
                fprintf(stderr, "[Node %d] UNEXPORT: entry not found in address table\n", rank);
            }
        } else {
            resp.success = -1;
            fprintf(stderr, "[Node %d] UNEXPORT: mem_id %ld not found\n", rank, req.id);
        }
        
    } else if (req.msg_type == CLIENT_MSG_FINISH) {
        // Finish request - stop the simulator
        printf("[Node %d] Received finish message from client\n", rank);
        resp.success = 0;
        
        // Send response before exiting
        if (send(client_fd, &resp, sizeof(resp), 0) != sizeof(resp)) {
            fprintf(stderr, "[Node %d] send failed: %s\n", rank, strerror(errno));
        }
        close(client_fd);
        
        // Stop the message queue (only rank0 has it)
        if (rank == 0) {
            addr_table_stop_message_queue();
        }
        
        // Stop socket server
        g_server_running = false;
        
        // Exit the process (this will terminate the entire MPI process)
        // Note: In MPI, we should coordinate with other processes, but for simplicity
        // we'll just exit. The main loop will also need to check a flag.
        printf("[Node %d] Exiting simulator...\n", rank);
        fflush(stdout);
        
        // Cleanup before exit
        addr_table_finalize();
        exit(0);
    }
    
    // Send response (if not already sent in FINISH case)
    if (req.msg_type != CLIENT_MSG_FINISH) {
        if (send(client_fd, &resp, sizeof(resp), 0) != sizeof(resp)) {
            fprintf(stderr, "[Node %d] send failed: %s\n", rank, strerror(errno));
        }
        close(client_fd);
    }
}

// Server thread function
static void server_thread_func(int rank) {
    // Create socket
    char socket_path[256];
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir) {
        tmpdir = "/tmp";
    }
    snprintf(socket_path, sizeof(socket_path), "%s/obmm_simulator_node%d.sock", tmpdir, rank);
    
    // Remove existing socket file
    unlink(socket_path);
    
    int sock_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock_fd < 0) {
        fprintf(stderr, "[Node %d] socket failed: %s\n", rank, strerror(errno));
        return;
    }
    
    sockaddr_un addr{};
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
    
    if (bind(sock_fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) < 0) {
        fprintf(stderr, "[Node %d] bind failed: %s\n", rank, strerror(errno));
        close(sock_fd);
        return;
    }
    
    if (listen(sock_fd, 5) < 0) {
        fprintf(stderr, "[Node %d] listen failed: %s\n", rank, strerror(errno));
        close(sock_fd);
        return;
    }
    
    g_socket_fd = sock_fd;
    printf("[Node %d] Socket server listening on %s\n", rank, socket_path);
    fflush(stdout);
    
    while (g_server_running) {
        fd_set read_fds;
        timeval timeout{};
        
        FD_ZERO(&read_fds);
        FD_SET(sock_fd, &read_fds);
        
        timeout.tv_sec = 1;
        timeout.tv_usec = 0;
        
        const int ret = select(sock_fd + 1, &read_fds, nullptr, nullptr, &timeout);
        if (ret < 0) {
            if (g_server_running) {
                fprintf(stderr, "[Node %d] select failed: %s\n", rank, strerror(errno));
            }
            continue;
        }
        
        if (ret == 0) {
            // Timeout, check if we should continue
            continue;
        }
        
        if (FD_ISSET(sock_fd, &read_fds)) {
            sockaddr_un client_addr{};
            socklen_t client_len = sizeof(client_addr);
            
            int client_fd = accept(sock_fd, reinterpret_cast<struct sockaddr *>(&client_addr), &client_len);
            if (client_fd < 0) {
                if (g_server_running) {
                    fprintf(stderr, "[Node %d] accept failed: %s\n", rank, strerror(errno));
                }
                continue;
            }
            
            handle_client_request(client_fd, rank);
        }
    }
    
    close(sock_fd);
    unlink(socket_path);
    printf("[Node %d] Socket server stopped\n", rank);
}

// Global rank for import operations (set by start_server)
static int g_server_rank = -1;

// Start socket server (called from simulator)
void obmm_simulator_start_server(int rank) {
    g_server_rank = rank;
    std::thread server_thread(server_thread_func, rank);
    server_thread.detach(); 
}

// Stop socket server
void obmm_simulator_stop_server() {
    g_server_running = false;
    if (g_socket_fd >= 0) {
        close(g_socket_fd);
        g_socket_fd = -1;
    }
}

// Cleanup import records
void obmm_simulator_cleanup_imports() {
    g_import_mem_id_to_info.clear();
}
