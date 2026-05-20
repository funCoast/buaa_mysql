#include "libobmm.h"
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include "libobmm_client.h"


/** Get socket path for a specific node */
static int get_socket_path(const int node_id, char *path) {
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir) {
        tmpdir = "/tmp";
    }
    
    const int ret = snprintf(path,
        SOCKET_PATH_LENGTH, "%s/obmm_simulator_node%d.sock", tmpdir, node_id);
    return ret < 0 || static_cast<size_t>(ret) >= SOCKET_PATH_LENGTH ? -1 : 0;
}

/** Connect to simulator node */
static int connect_to_node(const int node_id) {
    char socket_path[SOCKET_PATH_LENGTH];
    if (get_socket_path(node_id, socket_path) != 0) {
        return -1;
    }
    
    const int sock_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock_fd < 0) {
        fprintf(stderr, "socket failed: %s\n", strerror(errno));
        return -1;
    }
    
    auto addr = sockaddr_un();
    memset(&addr, 0, sizeof(sockaddr_un));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, socket_path, sizeof(addr.sun_path) - 1);
    
    if (connect(sock_fd, reinterpret_cast<sockaddr *>(&addr), sizeof(sockaddr_un)) < 0) {
        fprintf(stderr, "connect to %s failed: %s\n", socket_path, strerror(errno));
        close(sock_fd);
        return -1;
    }
    
    return sock_fd;
}

/** Get target node_id from environment or use default */
static int get_target_node_id() {
    const char *node_id_str = getenv("OBMM_TARGET_NODE");
    if (node_id_str) {
        return static_cast<int>(strtol(node_id_str, nullptr, 10));
    }
    return 0; // Default to node 0
}

mem_id obmm_export(const size_t length[OBMM_MAX_LOCAL_NUMA_NODES], unsigned long flags, 
                   struct obmm_mem_desc *desc) {
    if (desc == nullptr) {
        return OBMM_INVALID_MEMID;
    }
    
    int node_id = get_target_node_id();
    printf("[Client] Connecting to node %d for export\n", node_id);
    const int sock_fd = connect_to_node(node_id);
    if (sock_fd < 0) {
        fprintf(stderr, "[Client] Failed to connect to node %d\n", node_id);
        return OBMM_INVALID_MEMID;
    }
    
    // Prepare request
    auto req = client_request();
    memset(&req, 0, sizeof(req));
    req.msg_type = CLIENT_MSG_EXPORT;
    req.length[0] = length[0];
    req.length[1] = 0; // Second NUMA node not used for now
    req.addr = desc->addr;
    req.desc_length = desc->length;
    
    // Send request
    if (send(sock_fd, &req, sizeof(req), 0) != sizeof(req)) {
        fprintf(stderr, "send failed: %s\n", strerror(errno));
        close(sock_fd);
        return OBMM_INVALID_MEMID;
    }
    
    // Receive response
    auto resp = client_response();
    if (recv(sock_fd, &resp, sizeof(resp), 0) != sizeof(resp)) {
        fprintf(stderr, "recv failed: %s\n", strerror(errno));
        close(sock_fd);
        return OBMM_INVALID_MEMID;
    }
    
    close(sock_fd);
    
    if (resp.success != 0) {
        return OBMM_INVALID_MEMID;
    }
    
    // Update desc with returned information (address allocated by server)
    desc->addr = resp.addr;
    desc->length = resp.length;
    
    return resp.id;
}

int obmm_unexport(mem_id id, unsigned long flags) {
    const int node_id = get_target_node_id();
    const int sock_fd = connect_to_node(node_id);
    if (sock_fd < 0) {
        return -1;
    }
    
    // Prepare request
    auto req = client_request();
    memset(&req, 0, sizeof(req));
    req.msg_type = CLIENT_MSG_UNEXPORT;
    req.id = id;
    
    // Send request
    if (send(sock_fd, &req, sizeof(req), 0) != sizeof(req)) {
        fprintf(stderr, "send failed: %s\n", strerror(errno));
        close(sock_fd);
        return -1;
    }
    
    // Receive response
    auto resp = client_response();
    if (recv(sock_fd, &resp, sizeof(resp), 0) != sizeof(resp)) {
        fprintf(stderr, "recv failed: %s\n", strerror(errno));
        close(sock_fd);
        return -1;
    }
    
    close(sock_fd);
    
    return resp.success;
}

mem_id obmm_import(const obmm_mem_desc *desc, unsigned long flags, int base_dist, int *numa) {
    if (desc == nullptr) {
        return OBMM_INVALID_MEMID;
    }
    
    if (desc->addr == 0) {
        fprintf(stderr, "Invalid address: 0\n");
        return OBMM_INVALID_MEMID;
    }
    
    const int node_id = get_target_node_id();
    printf("[Client] Connecting to node %d for import (addr=0x%lx)\n", node_id, desc->addr);
    const int sock_fd = connect_to_node(node_id);
    if (sock_fd < 0) {
        fprintf(stderr, "[Client] Failed to connect to node %d\n", node_id);
        return OBMM_INVALID_MEMID;
    }
    
    // Prepare request
    auto req = client_request();
    memset(&req, 0, sizeof(req));
    req.msg_type = CLIENT_MSG_IMPORT;
    req.addr = desc->addr;
    req.desc_length = desc->length;
    
    // Send request
    if (send(sock_fd, &req, sizeof(req), 0) != sizeof(req)) {
        fprintf(stderr, "send failed: %s\n", strerror(errno));
        close(sock_fd);
        return OBMM_INVALID_MEMID;
    }
    
    // Receive response
    auto resp = client_response();
    if (recv(sock_fd, &resp, sizeof(resp), 0) != sizeof(resp)) {
        fprintf(stderr, "recv failed: %s\n", strerror(errno));
        close(sock_fd);
        return OBMM_INVALID_MEMID;
    }
    
    close(sock_fd);
    
    if (resp.success != 0) {
        return OBMM_INVALID_MEMID;
    }
    
    // Update desc with returned information
    // Note: addr and length should already be set in desc
    // to ensure consistency
    return resp.id;
}

int obmm_unimport(mem_id id, unsigned long flags) {
    if (id == OBMM_INVALID_MEMID) {
        return -1;
    }
    
    const int node_id = get_target_node_id();
    printf("[Client] Connecting to node %d for unimport (mem_id=%ld)\n", node_id, id);
    int sock_fd = connect_to_node(node_id);
    if (sock_fd < 0) {
        fprintf(stderr, "[Client] Failed to connect to node %d\n", node_id);
        return -1;
    }
    
    // Prepare request
    auto req = client_request();
    memset(&req, 0, sizeof(req));
    req.msg_type = CLIENT_MSG_UNIMPORT;
    req.id = id;  // local mem_id
    
    // Send request
    if (send(sock_fd, &req, sizeof(req), 0) != sizeof(req)) {
        fprintf(stderr, "send failed: %s\n", strerror(errno));
        close(sock_fd);
        return -1;
    }
    
    // Receive response
    auto resp = client_response();
    if (recv(sock_fd, &resp, sizeof(resp), 0) != sizeof(resp)) {
        fprintf(stderr, "recv failed: %s\n", strerror(errno));
        close(sock_fd);
        return -1;
    }
    
    close(sock_fd);
    
    return resp.success;
}

int obmm_simulator_finish() {
    // Connect to all nodes and send finish message
    int max_nodes = 16;
    const char *max_nodes_str = getenv("OBMM_MAX_NODES");
    if (max_nodes_str) {
        max_nodes = static_cast<int>(strtol(max_nodes_str, nullptr, 10));
    }
    
    int success_count = 0;
    
    for (int i = 0; i < max_nodes; i++) {
        const int sock_fd = connect_to_node(i);
        if (sock_fd < 0) {
            continue;
        }
        
        auto req = client_request();
        memset(&req, 0, sizeof(req));
        req.msg_type = CLIENT_MSG_FINISH;
        
        if (send(sock_fd, &req, sizeof(req), 0) == sizeof(req)) {
            // Wait for response
            auto resp = client_response();
            if (recv(sock_fd, &resp, sizeof(resp), 0) == sizeof(resp)) {
                success_count++;
            }
        }
        
        close(sock_fd);
    }
    
    if (success_count > 0) {
        printf("Sent finish message to %d node(s)\n", success_count);
    } else {
        fprintf(stderr, "No simulator nodes found to stop\n");
    }
    
    return success_count > 0 ? 0 : -1;
}
