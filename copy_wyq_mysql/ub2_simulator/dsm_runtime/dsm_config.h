#ifndef DSM_CONFIG_H
#define DSM_CONFIG_H

// 共享内存数组大小配置
#define ARRAY_SIZE 4194304 // 4194304 integers = 16MB (可容纳4个4MB的extent)

// DSM 内存管理配置
#define EXTENT_SIZE (4 * 1024 * 1024)  // 4MB per extent
#define PAGE_SIZE (16 * 1024)          // 16KB per page
#define PAGES_PER_EXTENT (EXTENT_SIZE / PAGE_SIZE)  // 当前配置: 256 pages per extent (最大支持 640 pages for 10MB extent)

#endif // DSM_CONFIG_H
