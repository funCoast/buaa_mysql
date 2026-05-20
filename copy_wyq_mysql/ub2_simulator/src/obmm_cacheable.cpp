//
// OBMM Cacheable Memory Management Library
// Userfaultfd-based page fault handling with buffer pool
//
#define _GNU_SOURCE
#include "libobmm_cacheable.hpp"
#include <cerrno>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <poll.h>
#include <pthread.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <random>
#include <stdexcept>
#include <algorithm>

namespace {
    [[noreturn]] void die(const char *msg) {
        perror(msg);
        throw std::runtime_error(msg);
    }
}

namespace {
    int uffd_open(const int flags) {
        return static_cast<int>(syscall(__NR_userfaultfd, flags));
    }
}

namespace {
    void* page_align(void *p, const size_t pagesz) {
        return reinterpret_cast<void *>(reinterpret_cast<uintptr_t>(p) & ~(pagesz - 1));
    }

    bool in_range(void *addr, void *base, const size_t len) {
        const auto a = reinterpret_cast<uintptr_t>(addr);
        const auto b = reinterpret_cast<uintptr_t>(base);
        return a >= b && a < (b + len);
    }

    void uffd_copy(const int uffd, void *dst_page, void *src_page, const size_t pagesz) {
        uffdio_copy cp{};
        std::memset(&cp, 0, sizeof(cp));
        cp.dst = reinterpret_cast<unsigned long>(dst_page);
        cp.src = reinterpret_cast<unsigned long>(src_page);  // 修复：应该是 src 而不是 dst
        cp.len = pagesz;
        cp.mode = 0;
        if (ioctl(uffd, UFFDIO_COPY, &cp) == -1) {
            die("UFFDIO_COPY");
        }
    }

    void uffd_move(const int uffd, void *dst_page, void *src_page, 
                   const size_t pagesz, const uint64_t mode) {
        uffdio_move mv{
            reinterpret_cast<unsigned long>(dst_page),
            reinterpret_cast<unsigned long>(src_page),
            pagesz,
            mode
        };
        if (ioctl(uffd, UFFDIO_MOVE, &mv) == -1) {
            die("UFFDIO_MOVE");
        }
    }

    int find_free_slot(const obmm_ctx_t *c) {
        for (size_t i = 0; i < c->pool_pages; ++i) {
            if (c->slot_to_vpage[i] == -1) {
                return static_cast<int>(i);
            }
        }
        return -1;
    }

    int pick_victim_slot_random(obmm_ctx_t *c) {
        // pool full: random evict
        return c->victim_chooser(c->rng);
    }

    // writeback: region[victim] -> shm[victim]
    void writeback_to_shm(const obmm_ctx_t *c, const int victim_vpage) {
        const uint8_t *src = c->region + victim_vpage * c->pagesz;
        uint8_t *dst = c->shm + victim_vpage * c->pagesz;
        std::memcpy(dst, src, c->pagesz);
    }
}

namespace {
    void *fault_handler(void *arg) {
        auto *c = static_cast<obmm_ctx_t*>(arg);
        pollfd pfd{.fd = c->uffd, .events = POLLIN};

        void *pagebuf = nullptr;
        if (posix_memalign(&pagebuf, c->pagesz, c->pagesz) != 0) {
            die("posix_memalign");
        }

        for (;;) {
            // Use infinite timeout to avoid polling - thread will be woken up by:
            // 1. Page fault events (normal operation)
            // 2. Closing uffd (during shutdown)
            // 3. Signals (EINTR)
            const int poll_result = poll(&pfd, 1, -1);
            
            // Check if we should stop (after poll returns, which could be due to uffd closure)
            pthread_mutex_lock(&c->mu);
            const bool stop = c->should_stop;
            pthread_mutex_unlock(&c->mu);
            if (stop) {
                fprintf(stderr, "[FAULT_HANDLER] Received stop signal, exiting...\n");
                break;
            }
            
            if (poll_result < 0) {
                if (errno == EINTR) {
                    // Interrupted by signal, check stop flag again
                    continue;
                }
                if (errno == EBADF) {
                    // uffd was closed, check stop flag and exit
                    pthread_mutex_lock(&c->mu);
                    const bool stop = c->should_stop;
                    pthread_mutex_unlock(&c->mu);
                    if (stop) {
                        fprintf(stderr, "[FAULT_HANDLER] uffd closed, exiting...\n");
                        break;
                    }
                }
                // Other errors: log and check stop flag
                fprintf(stderr, "[FAULT_HANDLER] poll error: %s (errno=%d)\n", strerror(errno), errno);
                pthread_mutex_lock(&c->mu);
                const bool stop = c->should_stop;
                pthread_mutex_unlock(&c->mu);
                if (stop) {
                    break;
                }
                // If not stopping, continue (might be transient error)
                continue;
            }
            
            // poll_result > 0 means we have events to process
            // No timeout case (poll_result == 0) since we use infinite timeout

            uffd_msg msg{};
            const ssize_t r = read(c->uffd, &msg, sizeof(msg));
            if (r < 0) {
                if (errno == EAGAIN) continue;
                if (errno == EBADF) {
                    // uffd was closed, check stop flag and exit
                    pthread_mutex_lock(&c->mu);
                    const bool stop = c->should_stop;
                    pthread_mutex_unlock(&c->mu);
                    if (stop) {
                        fprintf(stderr, "[FAULT_HANDLER] uffd closed during read, exiting...\n");
                        break;
                    }
                }
                // Other errors: log and check stop flag
                fprintf(stderr, "[FAULT_HANDLER] read error: %s (errno=%d)\n", strerror(errno), errno);
                pthread_mutex_lock(&c->mu);
                const bool stop = c->should_stop;
                pthread_mutex_unlock(&c->mu);
                if (stop) {
                    break;
                }
                // If not stopping, might be transient error, but be cautious
                continue;
            }
            if (msg.event != UFFD_EVENT_PAGEFAULT) continue;

            void *fault_addr = reinterpret_cast<void*>(
                static_cast<uintptr_t>(msg.arg.pagefault.address));
            void *page = page_align(fault_addr, c->pagesz);
            const unsigned int flags = msg.arg.pagefault.flags;
            const bool is_write = !!(flags & UFFD_PAGEFAULT_FLAG_WRITE);

            // region fault
            if (!in_range(page, c->region, c->len)) {
                fprintf(stderr, "[FAULT] unexpected fault at %p (write=%d), not in region. "
                                "Filling zeros to avoid hang.\n", page, is_write);
                std::memset(pagebuf, 0, c->pagesz);
                uffd_copy(c->uffd, page, pagebuf, c->pagesz);
                continue;
            }

            const int vpage = static_cast<int>(
                (reinterpret_cast<uint8_t*>(page) - c->region) / c->pagesz);

            pthread_mutex_lock(&c->mu);

            // 正常情况下：resident 页不会 fault；这里仅做健壮性提示
            if (c->vpage_to_slot[vpage] != -1) {
                fprintf(stderr, "[WARN] fault on supposedly resident vpage=%d slot=%d\n",
                        vpage, c->vpage_to_slot[vpage]);
            }

            const int slot = find_free_slot(c);

            if (slot >= 0) {
                // ======= pool 未满：cold-load into pool (COPY)，再 MOVE 给 region =======
                const uint8_t *shm_src = c->shm + static_cast<size_t>(vpage) * c->pagesz;
                std::memcpy(pagebuf, shm_src, c->pagesz);

                void *pool_slot = c->pool + static_cast<size_t>(slot) * c->pagesz;

                fprintf(stderr, "[MISS] vpage=%d access=%s | free slot=%d | "
                                "COPY shm->pool then MOVE pool->region\n",
                        vpage, is_write ? "WRITE" : "READ", slot);

                // 1) shm -> pool(slot)（用 UFFDIO_COPY 往"洞"里填一页）
                uffd_copy(c->uffd, pool_slot, pagebuf, c->pagesz);

                // 2) pool(slot) -> region(vpage)（把页框交给 region）
                //    目标 region(vpage) 正在 fault，必然是 unmapped，因此 MOVE 成功
                uffd_move(c->uffd, page, pool_slot, c->pagesz, 0);

                // 3) 记录该 slot 的"页框"现在归 vpage 驻留使用
                c->slot_to_vpage[slot] = vpage;
                c->vpage_to_slot[vpage] = slot;
                // 如果是写操作，标记为 dirty；否则为 clean
                c->slot_dirty[slot] = is_write;

                pthread_mutex_unlock(&c->mu);
                continue;
            }

            // ======= pool 已满：随机逐出一个 slot（writeback + recycle frame）=======
            const int victim_slot = pick_victim_slot_random(c);
            const int victim_vpage = c->slot_to_vpage[victim_slot];
            if (victim_vpage < 0) {
                // 理论上 pool 满时不会发生；防御
                fprintf(stderr, "[BUG] picked free victim_slot=%d while pool is full?\n", victim_slot);
                pthread_mutex_unlock(&c->mu);
                // fallback：直接 cold-copy 到 region
                const uint8_t *shm_src = c->shm + static_cast<size_t>(vpage) * c->pagesz;
                std::memcpy(pagebuf, shm_src, c->pagesz);
                uffd_copy(c->uffd, page, pagebuf, c->pagesz);
                continue;
            }

            fprintf(stderr, "[EVICT] pool full | victim_slot=%d victim_vpage=%d | ",
                    victim_slot, victim_vpage);

            // 1) victim 写回 shm（只有 dirty 才写回）
            if (c->slot_dirty[victim_slot]) {
                writeback_to_shm(c, victim_vpage);
                c->slot_dirty[victim_slot] = false;  // 写回后清除 dirty 标志
                fprintf(stderr, "writeback then recycle\n");
            } else {
                fprintf(stderr, "discard (clean) then recycle\n");
            }

            // 2) 把 victim 的页框 MOVE 回 victim_slot（回收页框到 pool）
            //    目标 pool_slot 必须是"洞"（unmapped）；它是洞，因为这个 slot 的页框一直在 region 里用。
            void *pool_slot = c->pool + static_cast<size_t>(victim_slot) * c->pagesz;
            void *victim_region_page = c->region + static_cast<size_t>(victim_vpage) * c->pagesz;

            // 对 victim 没有 faulting thread 在等，DONTWAKE 更合适
            uffd_move(c->uffd, pool_slot, victim_region_page, c->pagesz, UFFDIO_MOVE_MODE_DONTWAKE);

            // victim 现在不 resident 了（region 上该页变回 missing）
            c->vpage_to_slot[victim_vpage] = -1;

            // 3) 把要访问的 shm 页内容写入这个"回收来的页框"（现在映射在 pool_slot 上）
            const uint8_t *shm_src = c->shm + static_cast<size_t>(vpage) * c->pagesz;
            std::memcpy(pool_slot, shm_src, c->pagesz);

            // 4) 把该页框 MOVE 到 faulting 的 region 页（让用户线程继续）
            uffd_move(c->uffd, page, pool_slot, c->pagesz, 0);

            // 5) 更新 slot <-> vpage 映射：这个 slot 现在服务于新 vpage
            c->slot_to_vpage[victim_slot] = vpage;
            c->vpage_to_slot[vpage] = victim_slot;
            // 如果是写操作，标记为 dirty；否则为 clean
            c->slot_dirty[victim_slot] = is_write;

            pthread_mutex_unlock(&c->mu);
        }
        
        // Cleanup: free pagebuf
        if (pagebuf != nullptr) {
            std::free(pagebuf);
        }
        
        fprintf(stderr, "[FAULT_HANDLER] Thread exited\n");
        return nullptr;
    }
}


// 手动写回：若 vpage resident（在 pool 中），把当前内容写回 shm 对应位置；不逐出
// 返回：0=成功；1=不在池中(已逐出/未驻留)；-1=错误
int manual_writeback_vpage(obmm_ctx_t *c, int vpage) {
    if (c == nullptr || vpage < 0 || static_cast<size_t>(vpage) >= c->region_pages) {
        return -1;
    }

    pthread_mutex_lock(&c->mu);
    const int slot = c->vpage_to_slot[vpage];
    if (slot < 0) {
        pthread_mutex_unlock(&c->mu);
        return 1; // already evicted / not resident
    }

    // 只有 dirty 的页才需要写回
    if (c->slot_dirty[slot]) {
        // 注意：resident 页框挂在 region[vpage] 上，不在 pool_slot 上
        const uint8_t *src = c->region + static_cast<size_t>(vpage) * c->pagesz;
        uint8_t *dst = c->shm + static_cast<size_t>(vpage) * c->pagesz;
        std::memcpy(dst, src, c->pagesz);
        c->slot_dirty[slot] = false;  // 写回后清除 dirty 标志
        pthread_mutex_unlock(&c->mu);
        fprintf(stderr, "[MANUAL_WB] vpage=%d slot=%d -> shm written (was dirty)\n", vpage, slot);
    } else {
        pthread_mutex_unlock(&c->mu);
        fprintf(stderr, "[MANUAL_WB] vpage=%d slot=%d -> skipped (clean, no writeback needed)\n", vpage, slot);
    }

    return 0;
}

// 手动无效化：若 vpage resident，则丢弃其缓存内容并让 region[vpage] 变回 missing
// 返回：0=成功；1=不在池中(已逐出/未驻留)；-1=错误
int manual_invalidate_vpage(obmm_ctx_t *c, int vpage) {
    if (c == nullptr || vpage < 0 || static_cast<size_t>(vpage) >= c->region_pages) {
        return -1;
    }

    pthread_mutex_lock(&c->mu);
    const int slot = c->vpage_to_slot[vpage];
    if (slot < 0) {
        pthread_mutex_unlock(&c->mu);
        return 1; // already evicted / not resident
    }

    void *region_page = c->region + static_cast<size_t>(vpage) * c->pagesz;
    void *pool_slot = c->pool + static_cast<size_t>(slot) * c->pagesz;

    // 1) 回收页框：MOVE region->pool_slot
    //    victim 没有线程在等，DONTWAKE 更合适
    uffd_move(c->uffd, pool_slot, region_page, c->pagesz, UFFDIO_MOVE_MODE_DONTWAKE);

    // 2) 丢弃 pool_slot 中的页内容，并把它变回"洞"
    //    这样后续还能当 UFFDIO_MOVE 的 dst
    if (madvise(pool_slot, c->pagesz, MADV_DONTNEED) == -1) {
        pthread_mutex_unlock(&c->mu);
        die("madvise(pool_slot, DONTNEED)");
    }

    // 3) 清元数据：slot 变空闲，vpage 变非驻留，清除 dirty 标志
    c->vpage_to_slot[vpage] = -1;
    c->slot_to_vpage[slot] = -1;
    c->slot_dirty[slot] = false;  // 清除 dirty 标志（手动 invalidate 不检查 dirty，直接丢弃）

    pthread_mutex_unlock(&c->mu);

    fprintf(stderr, "[MANUAL_INV] vpage=%d slot=%d discarded (region becomes MISSING)\n", vpage, slot);
    return 0;
}

/**
 * Initialize OBMM Cacheable Management
 * @param path path of shared memory file
 * @param shm_size size of shared memory (must be aligned to PAGE_SIZE)
 * @return context pointer on success, nullptr on failure
 * @throws std::runtime_error on initialization failure
 */
obmm_ctx_t* init_obmm_cacheable_manager(const char* path, const size_t shm_size) {
    if (path == nullptr) {
        return nullptr;
    }
    if (shm_size % PAGE_SIZE != 0) {
        fprintf(stderr, "SIZE ERR: NOT ALIGNED TO PAGE_SIZE\n");
        return nullptr;
    }

    auto *c = new (std::nothrow) obmm_ctx_t();
    if (c == nullptr) {
        return nullptr;
    }

    try {
        c->pagesz = PAGE_SIZE;
        c->region_pages = shm_size / PAGE_SIZE;
        c->pool_pages = POOL_PAGES;
        c->len = shm_size;

        // ======== RANDOM INIT ========
        c->rng = std::mt19937(42);
        c->victim_chooser = std::uniform_int_distribution<int>(0, POOL_PAGES - 1);

        // ======== SHM INIT ========
        c->shm_fd = open(path, O_CREAT | O_RDWR, 0600);
        if (c->shm_fd == -1) {
            delete c;
            die("open(/dev/shm file)");
        }
        if (ftruncate(c->shm_fd, static_cast<off_t>(c->len)) == -1) {
            close(c->shm_fd);
            delete c;
            die("ftruncate");
        }
        c->shm = static_cast<uint8_t *>(
            mmap(nullptr, c->len, PROT_READ | PROT_WRITE, MAP_SHARED, c->shm_fd, 0));
        if (c->shm == MAP_FAILED) {
            close(c->shm_fd);
            delete c;
            die("mmap(shm)");
        }

        // ======== REGION INIT ========
        c->region = static_cast<uint8_t *>(
            mmap(nullptr, c->len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
        if (c->region == MAP_FAILED) {
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("mmap(region)");
        }

        // ======== POOL INIT ========
        const size_t pool_len = c->pool_pages * c->pagesz;
        c->pool = static_cast<uint8_t *>(
            mmap(nullptr, pool_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0));
        if (c->pool == MAP_FAILED) {
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("mmap(pool)");
        }

        // ======== METADATA INIT ========
        c->vpage_to_slot = static_cast<int*>(std::malloc(sizeof(int) * c->region_pages));
        c->slot_to_vpage = static_cast<int*>(std::malloc(sizeof(int) * c->pool_pages));
        c->slot_dirty = static_cast<bool*>(std::malloc(sizeof(bool) * c->pool_pages));
        if (!c->vpage_to_slot || !c->slot_to_vpage || !c->slot_dirty) {
            if (c->slot_dirty) std::free(c->slot_dirty);
            if (c->slot_to_vpage) std::free(c->slot_to_vpage);
            if (c->vpage_to_slot) std::free(c->vpage_to_slot);
            munmap(c->pool, pool_len);
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("malloc(meta)");
        }
        std::fill(c->vpage_to_slot, c->vpage_to_slot + c->region_pages, -1);
        std::fill(c->slot_to_vpage, c->slot_to_vpage + c->pool_pages, -1);
        std::fill(c->slot_dirty, c->slot_dirty + c->pool_pages, false);

        // ======== THREAD INIT ========
        if (pthread_mutex_init(&c->mu, nullptr) != 0) {
            std::free(c->slot_dirty);
            std::free(c->slot_to_vpage);
            std::free(c->vpage_to_slot);
            munmap(c->pool, pool_len);
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("pthread_mutex_init");
        }

        // ======== UFFD INIT ========
        c->uffd = uffd_open(O_CLOEXEC | O_NONBLOCK);
        if (c->uffd < 0) {
            pthread_mutex_destroy(&c->mu);
            std::free(c->slot_dirty);
            std::free(c->slot_to_vpage);
            std::free(c->vpage_to_slot);
            munmap(c->pool, pool_len);
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("userfaultfd");
        }

        uffdio_api ua{};
        std::memset(&ua, 0, sizeof(ua));
        ua.api = UFFD_API;
        ua.features = UFFD_FEATURE_MOVE;

        if (ioctl(c->uffd, UFFDIO_API, &ua) == -1) {
            close(c->uffd);
            pthread_mutex_destroy(&c->mu);
            std::free(c->slot_dirty);
            std::free(c->slot_to_vpage);
            std::free(c->vpage_to_slot);
            munmap(c->pool, pool_len);
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("UFFDIO_API(enable MOVE)");
        }
        if (!(ua.features & UFFD_FEATURE_MOVE)) {
            close(c->uffd);
            pthread_mutex_destroy(&c->mu);
            std::free(c->slot_dirty);
            std::free(c->slot_to_vpage);
            std::free(c->vpage_to_slot);
            munmap(c->pool, pool_len);
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("Kernel didn't enable UFFD_FEATURE_MOVE");
        }

        // Register region
        uffdio_register ur{};
        std::memset(&ur, 0, sizeof(ur));
        ur.range.start = reinterpret_cast<unsigned long>(c->region);
        ur.range.len = c->len;
        ur.mode = UFFDIO_REGISTER_MODE_MISSING;
        if (ioctl(c->uffd, UFFDIO_REGISTER, &ur) == -1) {
            close(c->uffd);
            pthread_mutex_destroy(&c->mu);
            std::free(c->slot_dirty);
            std::free(c->slot_to_vpage);
            std::free(c->vpage_to_slot);
            munmap(c->pool, pool_len);
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("UFFDIO_REGISTER(region)");
        }

        // Register pool (missing) — because UFFDIO_COPY and UFFDIO_MOVE dst must be in registered range
        std::memset(&ur, 0, sizeof(ur));
        ur.range.start = reinterpret_cast<unsigned long>(c->pool);
        ur.range.len = pool_len;
        ur.mode = UFFDIO_REGISTER_MODE_MISSING;
        if (ioctl(c->uffd, UFFDIO_REGISTER, &ur) == -1) {
            close(c->uffd);
            pthread_mutex_destroy(&c->mu);
            std::free(c->slot_dirty);
            std::free(c->slot_to_vpage);
            std::free(c->vpage_to_slot);
            munmap(c->pool, pool_len);
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("UFFDIO_REGISTER(pool)");
        }

        // ======== HANDLER INIT ========
        pthread_t th;
        if (pthread_create(&th, nullptr, fault_handler, c) != 0) {
            close(c->uffd);
            pthread_mutex_destroy(&c->mu);
            std::free(c->slot_dirty);
            std::free(c->slot_to_vpage);
            std::free(c->vpage_to_slot);
            munmap(c->pool, pool_len);
            munmap(c->region, c->len);
            munmap(c->shm, c->len);
            close(c->shm_fd);
            delete c;
            die("pthread_create");
        }
        c->fault_handler_thread = th;

        fprintf(stderr, "[OBMM] Initialized: shm=%p len=%zu | region=%p pages=%zu | "
                        "pool=%p pages=%zu | pagesz=%zu\n",
                c->shm, c->len, c->region, c->region_pages, c->pool, c->pool_pages, c->pagesz);

        return c;
    } catch (...) {
        // Cleanup on exception
        if (c->slot_dirty != nullptr) {
            std::free(c->slot_dirty);
        }
        if (c->slot_to_vpage != nullptr) {
            std::free(c->slot_to_vpage);
        }
        if (c->vpage_to_slot != nullptr) {
            std::free(c->vpage_to_slot);
        }
        if (c->pool != nullptr) {
            const size_t pool_len = c->pool_pages * c->pagesz;
            munmap(c->pool, pool_len);
        }
        if (c->region != nullptr) {
            munmap(c->region, c->len);
        }
        if (c->shm != nullptr) {
            munmap(c->shm, c->len);
        }
        if (c->shm_fd >= 0) {
            close(c->shm_fd);
        }
        delete c;
        throw;
    }
}

/**
 * Destroy OBMM Cacheable Management context
 * @param c context pointer (can be nullptr)
 */
void destroy_obmm_cacheable_manager(obmm_ctx_t *c) {
    if (c == nullptr) {
        return;
    }

    // Gracefully stop fault handler thread
    // Step 1: Set stop flag
    pthread_mutex_lock(&c->mu);
    c->should_stop = true;
    pthread_mutex_unlock(&c->mu);
    
    // Step 2: Close uffd to wake up poll() in fault handler
    // This will cause poll() to return, allowing the handler to check should_stop flag
    if (c->uffd >= 0) {
        close(c->uffd);
        c->uffd = -1;  // Mark as closed
    }
    
    // Step 3: Wait for fault handler thread to exit
    // Try to join the thread (pthread_join is safe even if thread already exited)
    fprintf(stderr, "[DESTROY] Waiting for fault handler thread to exit...\n");
    void *thread_result = nullptr;
    const int join_result = pthread_join(c->fault_handler_thread, &thread_result);
    if (join_result == 0) {
        fprintf(stderr, "[DESTROY] Fault handler thread exited successfully\n");
    } else if (join_result == ESRCH) {
        // Thread doesn't exist (wasn't created or already joined)
        fprintf(stderr, "[DESTROY] Fault handler thread not found (may not have been created)\n");
    } else {
        fprintf(stderr, "[DESTROY] Warning: pthread_join failed with error %d\n", join_result);
    }

    // Write back all dirty pages in pool before destroying
    if (c->slot_to_vpage != nullptr && c->slot_dirty != nullptr && c->region != nullptr && c->shm != nullptr) {
        pthread_mutex_lock(&c->mu);
        
        int dirty_count = 0;
        for (size_t slot = 0; slot < c->pool_pages; ++slot) {
            const int vpage = c->slot_to_vpage[slot];
            if (vpage >= 0 && c->slot_dirty[slot]) {
                // 页框在 region[vpage] 上，写回 shm
                const uint8_t *src = c->region + static_cast<size_t>(vpage) * c->pagesz;
                uint8_t *dst = c->shm + static_cast<size_t>(vpage) * c->pagesz;
                std::memcpy(dst, src, c->pagesz);
                c->slot_dirty[slot] = false;  // 清除 dirty 标志
                dirty_count++;
                fprintf(stderr, "[DESTROY] Writeback dirty vpage=%d slot=%zu\n", vpage, slot);
            }
        }
        
        if (dirty_count > 0) {
            fprintf(stderr, "[DESTROY] Wrote back %d dirty pages\n", dirty_count);
        }
        
        pthread_mutex_unlock(&c->mu);
    }

    // uffd was already closed above to wake up the fault handler thread
    // Just ensure it's closed if somehow it wasn't
    if (c->uffd >= 0) {
        close(c->uffd);
        c->uffd = -1;
    }

    pthread_mutex_destroy(&c->mu);

    if (c->slot_dirty != nullptr) {
        std::free(c->slot_dirty);
    }
    if (c->slot_to_vpage != nullptr) {
        std::free(c->slot_to_vpage);
    }
    if (c->vpage_to_slot != nullptr) {
        std::free(c->vpage_to_slot);
    }

    if (c->pool != nullptr) {
        const size_t pool_len = c->pool_pages * c->pagesz;
        munmap(c->pool, pool_len);
    }
    if (c->region != nullptr) {
        munmap(c->region, c->len);
    }
    if (c->shm != nullptr) {
        munmap(c->shm, c->len);
    }
    if (c->shm_fd >= 0) {
        close(c->shm_fd);
    }

    delete c;
}

