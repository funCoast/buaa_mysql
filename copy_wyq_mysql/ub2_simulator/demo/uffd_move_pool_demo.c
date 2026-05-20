#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    int uffd;

    // backing store: /dev/shm file mapping (true data)
    int shm_fd;
    uint8_t *shm;
    size_t len;
    size_t pagesz;
    size_t region_pages;

    // user-visible region (same size as shm)
    uint8_t *region;

    // buffer pool (fixed #pages)
    uint8_t *pool;
    size_t pool_pages;

    // metadata
    // vpage -> slot, -1 = not resident
    int *vpage_to_slot;
    // slot -> vpage, -1 = free slot (never allocated a frame yet)
    int *slot_to_vpage;

    pthread_mutex_t mu;
} ctx_t;

static void die(const char *msg) {
    perror(msg);
    exit(1);
}

static int uffd_open(int flags) {
    return (int)syscall(__NR_userfaultfd, flags);
}

static inline void* page_align(void *p, size_t pagesz) {
    return (void *)((uintptr_t)p & ~(pagesz - 1));
}

static int in_range(void *addr, void *base, size_t len) {
    uintptr_t a = (uintptr_t)addr, b = (uintptr_t)base;
    return a >= b && a < (b + len);
}

static void uffd_copy(int uffd, void *dst_page, void *src_page, size_t pagesz) {
    struct uffdio_copy cp;
    memset(&cp, 0, sizeof(cp));
    cp.dst  = (unsigned long)dst_page;
    cp.src  = (unsigned long)src_page;
    cp.len  = pagesz;
    cp.mode = 0;
    if (ioctl(uffd, UFFDIO_COPY, &cp) == -1) die("UFFDIO_COPY");
}

static void uffd_move(int uffd, void *dst_page, void *src_page, size_t pagesz, uint64_t mode) {
    struct uffdio_move mv;
    memset(&mv, 0, sizeof(mv));
    mv.dst  = (unsigned long)dst_page;
    mv.src  = (unsigned long)src_page;
    mv.len  = pagesz;
    mv.mode = mode;
    if (ioctl(uffd, UFFDIO_MOVE, &mv) == -1) die("UFFDIO_MOVE");
}

static int find_free_slot(ctx_t *c) {
    for (size_t i = 0; i < c->pool_pages; i++) {
        if (c->slot_to_vpage[i] == -1) return (int)i;
    }
    return -1;
}

static int pick_victim_slot_random(ctx_t *c) {
    // pool 满时：随机逐出一个 slot
    return (int)(rand() % c->pool_pages);
}

// writeback: region[victim] -> shm[victim]
static void writeback_to_shm(ctx_t *c, int victim_vpage) {
    uint8_t *src = c->region + (size_t)victim_vpage * c->pagesz;
    uint8_t *dst = c->shm    + (size_t)victim_vpage * c->pagesz;
    memcpy(dst, src, c->pagesz);
    // tmpfs 通常不需要 msync；如果你想更像“落盘”，可以打开
    // msync(dst, c->pagesz, MS_SYNC);
}

static void *fault_handler(void *arg) {
    ctx_t *c = (ctx_t*)arg;
    struct pollfd pfd = {.fd = c->uffd, .events = POLLIN};

    void *pagebuf = NULL;
    if (posix_memalign(&pagebuf, c->pagesz, c->pagesz) != 0) die("posix_memalign");

    for (;;) {
        if (poll(&pfd, 1, -1) < 0) die("poll");

        struct uffd_msg msg;
        ssize_t r = read(c->uffd, &msg, sizeof(msg));
        if (r < 0) {
            if (errno == EAGAIN) continue;
            die("read(uffd)");
        }
        if (msg.event != UFFD_EVENT_PAGEFAULT) continue;

        void *fault_addr = (void*)(uintptr_t)msg.arg.pagefault.address;
        void *page = page_align(fault_addr, c->pagesz);
        unsigned int flags = msg.arg.pagefault.flags;
        int is_write = !!(flags & UFFD_PAGEFAULT_FLAG_WRITE);

        // region fault
        if (!in_range(page, c->region, c->len)) {
            fprintf(stderr, "[FAULT] unexpected fault at %p (write=%d), not in region. "
                            "Filling zeros to avoid hang.\n", page, is_write);
            memset(pagebuf, 0, c->pagesz);
            uffd_copy(c->uffd, page, pagebuf, c->pagesz);
            continue;
        }

        int vpage = (int)(((uint8_t*)page - c->region) / c->pagesz);

        pthread_mutex_lock(&c->mu);

        // 正常情况下：resident 页不会 fault；这里仅做健壮性提示
        if (c->vpage_to_slot[vpage] != -1) {
            fprintf(stderr, "[WARN] fault on supposedly resident vpage=%d slot=%d\n",
                    vpage, c->vpage_to_slot[vpage]);
        }

        int slot = find_free_slot(c);

        if (slot >= 0) {
            // ======= pool 未满：cold-load into pool (COPY)，再 MOVE 给 region =======
            uint8_t *shm_src = c->shm + (size_t)vpage * c->pagesz;
            memcpy(pagebuf, shm_src, c->pagesz);

            void *pool_slot = c->pool + (size_t)slot * c->pagesz;

            fprintf(stderr, "[MISS] vpage=%d access=%s | free slot=%d | "
                            "COPY shm->pool then MOVE pool->region\n",
                    vpage, is_write ? "WRITE" : "READ", slot);

            // 1) shm -> pool(slot)（用 UFFDIO_COPY 往“洞”里填一页）
            uffd_copy(c->uffd, pool_slot, pagebuf, c->pagesz);

            // 2) pool(slot) -> region(vpage)（把页框交给 region）
            //    目标 region(vpage) 正在 fault，必然是 unmapped，因此 MOVE 成功
            uffd_move(c->uffd, page, pool_slot, c->pagesz, 0);

            // 3) 记录该 slot 的“页框”现在归 vpage 驻留使用
            c->slot_to_vpage[slot] = vpage;
            c->vpage_to_slot[vpage] = slot;

            pthread_mutex_unlock(&c->mu);
            continue;
        }

        // ======= pool 已满：随机逐出一个 slot（writeback + recycle frame）=======
        int victim_slot = pick_victim_slot_random(c);
        int victim_vpage = c->slot_to_vpage[victim_slot];
        if (victim_vpage < 0) {
            // 理论上 pool 满时不会发生；防御
            fprintf(stderr, "[BUG] picked free victim_slot=%d while pool is full?\n", victim_slot);
            pthread_mutex_unlock(&c->mu);
            // fallback：直接 cold-copy 到 region
            uint8_t *shm_src = c->shm + (size_t)vpage * c->pagesz;
            memcpy(pagebuf, shm_src, c->pagesz);
            uffd_copy(c->uffd, page, pagebuf, c->pagesz);
            continue;
        }

        fprintf(stderr, "[EVICT] pool full | victim_slot=%d victim_vpage=%d | writeback then recycle\n",
                victim_slot, victim_vpage);

        // 1) victim 写回 shm
        writeback_to_shm(c, victim_vpage);

        // 2) 把 victim 的页框 MOVE 回 victim_slot（回收页框到 pool）
        //    目标 pool_slot 必须是“洞”（unmapped）；它是洞，因为这个 slot 的页框一直在 region 里用。
        void *pool_slot = c->pool + (size_t)victim_slot * c->pagesz;
        void *victim_region_page = c->region + (size_t)victim_vpage * c->pagesz;

        // 对 victim 没有 faulting thread 在等，DONTWAKE 更合适
        uffd_move(c->uffd, pool_slot, victim_region_page, c->pagesz, UFFDIO_MOVE_MODE_DONTWAKE);

        // victim 现在不 resident 了（region 上该页变回 missing）
        c->vpage_to_slot[victim_vpage] = -1;

        // 3) 把要访问的 shm 页内容写入这个“回收来的页框”（现在映射在 pool_slot 上）
        uint8_t *shm_src = c->shm + (size_t)vpage * c->pagesz;
        memcpy(pool_slot, shm_src, c->pagesz);

        // 4) 把该页框 MOVE 到 faulting 的 region 页（让用户线程继续）
        uffd_move(c->uffd, page, pool_slot, c->pagesz, 0);

        // 5) 更新 slot <-> vpage 映射：这个 slot 现在服务于新 vpage
        c->slot_to_vpage[victim_slot] = vpage;
        c->vpage_to_slot[vpage] = victim_slot;

        pthread_mutex_unlock(&c->mu);
    }
    return NULL;
}

// 手动写回：若 vpage resident（在 pool 中），把当前内容写回 shm 对应位置；不逐出
// 返回：0=成功；1=不在池中(已逐出/未驻留)；-1=错误
static int manual_writeback_vpage(ctx_t *c, int vpage) {
    if (vpage < 0 || (size_t)vpage >= c->region_pages) return -1;

    pthread_mutex_lock(&c->mu);
    int slot = c->vpage_to_slot[vpage];
    if (slot < 0) {
        pthread_mutex_unlock(&c->mu);
        return 1; // already evicted / not resident
    }

    // 注意：resident 页框挂在 region[vpage] 上，不在 pool_slot 上
    uint8_t *src = c->region + (size_t)vpage * c->pagesz;
    uint8_t *dst = c->shm    + (size_t)vpage * c->pagesz;
    memcpy(dst, src, c->pagesz);

    pthread_mutex_unlock(&c->mu);

    fprintf(stderr, "[MANUAL_WB] vpage=%d slot=%d -> shm written\n", vpage, slot);
    return 0;
}

// 手动无效化：若 vpage resident，则丢弃其缓存内容并让 region[vpage] 变回 missing
// 返回：0=成功；1=不在池中(已逐出/未驻留)；-1=错误
static int manual_invalidate_vpage(ctx_t *c, int vpage) {
    if (vpage < 0 || (size_t)vpage >= c->region_pages) return -1;

    pthread_mutex_lock(&c->mu);
    int slot = c->vpage_to_slot[vpage];
    if (slot < 0) {
        pthread_mutex_unlock(&c->mu);
        return 1; // already evicted / not resident
    }

    void *region_page = c->region + (size_t)vpage * c->pagesz;
    void *pool_slot   = c->pool   + (size_t)slot  * c->pagesz;

    // 1) 回收页框：MOVE region->pool_slot
    //    victim 没有线程在等，DONTWAKE 更合适
    uffd_move(c->uffd, pool_slot, region_page, c->pagesz, UFFDIO_MOVE_MODE_DONTWAKE);

    // 2) 丢弃 pool_slot 中的页内容，并把它变回“洞”
    //    这样后续还能当 UFFDIO_MOVE 的 dst
    if (madvise(pool_slot, c->pagesz, MADV_DONTNEED) == -1) {
        pthread_mutex_unlock(&c->mu);
        die("madvise(pool_slot, DONTNEED)");
    }

    // 3) 清元数据：slot 变空闲，vpage 变非驻留
    c->vpage_to_slot[vpage] = -1;
    c->slot_to_vpage[slot]  = -1;

    pthread_mutex_unlock(&c->mu);

    fprintf(stderr, "[MANUAL_INV] vpage=%d slot=%d discarded (region becomes MISSING)\n", vpage, slot);
    return 0;
}


int main() {
    ctx_t c;
    memset(&c, 0, sizeof(c));
    c.pagesz = (size_t)sysconf(_SC_PAGESIZE);

    c.region_pages = 16;     // region == shm 的页数
    c.pool_pages   = 4;      // pool 容量（越小越容易触发逐出）
    c.len = c.region_pages * c.pagesz;

    srand((unsigned)time(NULL));

    // ===== backing store: /dev/shm file =====
    const char *path = "/dev/shm/uffd_backing_store.bin";
    c.shm_fd = open(path, O_CREAT | O_RDWR, 0600);
    if (c.shm_fd == -1) die("open(/dev/shm file)");
    if (ftruncate(c.shm_fd, (off_t)c.len) == -1) die("ftruncate");

    c.shm = mmap(NULL, c.len, PROT_READ | PROT_WRITE, MAP_SHARED, c.shm_fd, 0);
    if (c.shm == MAP_FAILED) die("mmap(shm)");

    // init shm content per-page (for visibility)
    for (size_t i = 0; i < c.region_pages; i++) {
        memset(c.shm + i * c.pagesz, (int)('a' + (i % 26)), c.pagesz);
    }

    // ===== region: user-visible logical space =====
    c.region = mmap(NULL, c.len, PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (c.region == MAP_FAILED) die("mmap(region)");

    // ===== pool: page frame pool (fixed pages) =====
    size_t pool_len = c.pool_pages * c.pagesz;
    c.pool = mmap(NULL, pool_len, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (c.pool == MAP_FAILED) die("mmap(pool)");

    c.vpage_to_slot = (int*)malloc(sizeof(int) * c.region_pages);
    c.slot_to_vpage = (int*)malloc(sizeof(int) * c.pool_pages);
    if (!c.vpage_to_slot || !c.slot_to_vpage) die("malloc(meta)");

    for (size_t i = 0; i < c.region_pages; i++) c.vpage_to_slot[i] = -1;
    for (size_t i = 0; i < c.pool_pages; i++)   c.slot_to_vpage[i] = -1;

    if (pthread_mutex_init(&c.mu, NULL) != 0) die("pthread_mutex_init");

    // ===== userfaultfd: enable MOVE =====
    c.uffd = uffd_open(O_CLOEXEC | O_NONBLOCK);
    if (c.uffd < 0) die("userfaultfd");

    struct uffdio_api ua;
    memset(&ua, 0, sizeof(ua));
    ua.api = UFFD_API;
    ua.features = UFFD_FEATURE_MOVE;

    if (ioctl(c.uffd, UFFDIO_API, &ua) == -1) die("UFFDIO_API(enable MOVE)");
    if (!(ua.features & UFFD_FEATURE_MOVE)) {
        fprintf(stderr, "Kernel didn't enable UFFD_FEATURE_MOVE\n");
        return 2;
    }

    // Register region (missing)
    struct uffdio_register ur;
    memset(&ur, 0, sizeof(ur));
    ur.range.start = (unsigned long)c.region;
    ur.range.len   = c.len;
    ur.mode        = UFFDIO_REGISTER_MODE_MISSING;
    if (ioctl(c.uffd, UFFDIO_REGISTER, &ur) == -1) die("UFFDIO_REGISTER(region)");

    // Register pool (missing) — because UFFDIO_MOVE dst must be in registered range
    memset(&ur, 0, sizeof(ur));
    ur.range.start = (unsigned long)c.pool;
    ur.range.len   = pool_len;
    ur.mode        = UFFDIO_REGISTER_MODE_MISSING;
    if (ioctl(c.uffd, UFFDIO_REGISTER, &ur) == -1) die("UFFDIO_REGISTER(pool)");

    pthread_t th;
    if (pthread_create(&th, NULL, fault_handler, &c) != 0) die("pthread_create");

    fprintf(stderr, "shm(backing)=%p len=%zu | region=%p pages=%zu | pool=%p pages=%zu | pagesz=%zu\n",
            c.shm, c.len, c.region, c.region_pages, c.pool, c.pool_pages, c.pagesz);

    // ===== demo workload =====
    // 访问多个页，触发 load + eviction
    for (int i = 0; i < 10; i++) {
        volatile uint8_t *p = c.region + (size_t)i * c.pagesz;
        uint8_t v = p[0];
        fprintf(stderr, "[USER] read vpage=%d -> '%c'\n", i, (v >= 32 && v < 127) ? v : '.');
    }

    // 修改某页，触发未来被逐出时写回 shm
    int wpage = 2;
    volatile uint8_t *pw = c.region + (size_t)wpage * c.pagesz;
    pw[0] = (uint8_t)'X';
    fprintf(stderr, "[USER] write vpage=%d -> 'X'\n", wpage);

    // 手动写回：只有 resident 才会成功
    manual_writeback_vpage(&c, wpage);

    // 手动无效化：丢弃缓存并让下次访问重新 fault+load
    manual_invalidate_vpage(&c, wpage);

    // 再访问，会触发缺页：从 shm 重新装入（若你刚写回，会读到 'X'；没写回就读旧值）
    uint8_t v = pw[0];
    fprintf(stderr, "[USER] after invalidate, read vpage=%d -> '%c'\n", wpage, v);

    // 再访问更多页，促使随机逐出发生
    for (int i = 10; i < 16; i++) {
        volatile uint8_t *p = c.region + (size_t)i * c.pagesz;
        uint8_t v = p[0];
        fprintf(stderr, "[USER] read vpage=%d -> '%c'\n", i, (v >= 32 && v < 127) ? v : '.');
    }

    // 回读 backing store 中 wpage 的首字节（如果它被逐出写回了，就会看到 'X'）
    fprintf(stderr, "[CHECK] shm vpage=%d first byte = '%c' (if evicted+writeback happened)\n",
            wpage, c.shm[wpage * (int)c.pagesz]);

    fprintf(stderr, "Done. Ctrl+C to exit.\n");
    pause();
    return 0;
}
