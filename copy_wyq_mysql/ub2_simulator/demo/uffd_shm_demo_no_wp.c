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
    int fd;                // /dev/shm file fd
    uint8_t *base;
    size_t len;
    size_t pagesz;
    // 计时相关
    pthread_mutex_t time_mutex;
    struct timespec trigger_time;      // 触发异常的时间
    struct timespec handler_entry_time; // 进入 handler 的时间
    struct timespec handler_exit_time;  // 离开 handler 的时间
    struct timespec resume_time;        // 主线程恢复的时间
    int timing_active;                  // 是否正在计时
} ctx_t;

static int uffd_open(int flags) {
    return (int)syscall(__NR_userfaultfd, flags);
}

static void die(const char *msg) {
    perror(msg);
    exit(1);
}

static inline void* page_align(void *p, size_t pagesz) {
    return (void *)((uintptr_t)p & ~(pagesz - 1));
}

static double timespec_diff_ns(const struct timespec *start, const struct timespec *end) {
    return (end->tv_sec - start->tv_sec) * 1e9 + (end->tv_nsec - start->tv_nsec);
}

static void continue_minor(int uffd, void *addr, size_t len) {
    struct uffdio_continue c;
    memset(&c, 0, sizeof(c));
    c.range.start = (unsigned long)addr;
    c.range.len   = len;
    if (ioctl(uffd, UFFDIO_CONTINUE, &c) == -1) die("UFFDIO_CONTINUE");
}

static void copy_page(int uffd, void *dst_page, void *src_page, size_t pagesz) {
    struct uffdio_copy cp;
    memset(&cp, 0, sizeof(cp));
    cp.src = (unsigned long)src_page;
    cp.dst = (unsigned long)dst_page;
    cp.len = pagesz;
    if (ioctl(uffd, UFFDIO_COPY, &cp) == -1) die("UFFDIO_COPY");
}

/************ 你的“劫持函数”位置（这里 demo 只打印） ************/
// 首次触页（缺页 MISSING）时：我们这里用 pread 从 /dev/shm 文件把该页数据读出来（新文件通常全 0）
static void hook_first_read_missing(ctx_t *c, void *page_addr, int is_write_fault, void *pagebuf) {
    size_t off = (size_t)((uint8_t*)page_addr - c->base);
    ssize_t n = pread(c->fd, pagebuf, c->pagesz, (off_t)off);
    if (n < 0) die("pread");
    if ((size_t)n < c->pagesz) memset((uint8_t*)pagebuf + n, 0, c->pagesz - (size_t)n);

    fprintf(stderr, "[MISSING] page=%p access=%s\n", page_addr, is_write_fault ? "WRITE" : "READ");
    fflush(stderr);
}

// invalidate 后再次访问触发 MINOR fault（读/写都会先来这里）
static void hook_again_minor(void *page_addr, int is_write_fault) {
    fprintf(stderr, "[MINOR]   page=%p access=%s (after invalidate)\n",
            page_addr, is_write_fault ? "WRITE" : "READ");
    fflush(stderr);
}
/*****************************************************************/

static void *fault_handler(void *arg) {
    ctx_t *c = (ctx_t*)arg;

    // handler 线程不要去读写 c->base 那段内存，否则可能自陷 fault
    struct pollfd pfd = {.fd = c->uffd, .events = POLLIN};

    // 用一个普通页缓冲来搬运数据
    void *pagebuf = NULL;
    if (posix_memalign(&pagebuf, c->pagesz, c->pagesz) != 0) die("posix_memalign");

    for (;;) {
        int n = poll(&pfd, 1, -1);
        if (n < 0) die("poll");

        struct uffd_msg msg;
        ssize_t r = read(c->uffd, &msg, sizeof(msg));
        if (r < 0) {
            if (errno == EAGAIN) continue;
            die("read(uffd)");
        }
        if (msg.event != UFFD_EVENT_PAGEFAULT) continue;

        // 记录进入 handler 的时间（总是记录，确保时间戳完整）
        pthread_mutex_lock(&c->time_mutex);
        clock_gettime(CLOCK_MONOTONIC, &c->handler_entry_time);
        pthread_mutex_unlock(&c->time_mutex);

        unsigned int flags = msg.arg.pagefault.flags;
        void *fault_addr = (void*)(uintptr_t)msg.arg.pagefault.address;
        void *page_addr  = page_align(fault_addr, c->pagesz);
        int is_write = !!(flags & UFFD_PAGEFAULT_FLAG_WRITE);

        // 1) MINOR fault：invalidate 后再次访问（页在 page cache，PTE 不在）
        if (flags & UFFD_PAGEFAULT_FLAG_MINOR) {
            hook_again_minor(page_addr, is_write);
            // 继续让内核安装 PTE（并继续执行触发 fault 的那条指令）
            continue_minor(c->uffd, page_addr, c->pagesz);
            
            // 记录离开 handler 的时间（总是记录）
            pthread_mutex_lock(&c->time_mutex);
            clock_gettime(CLOCK_MONOTONIC, &c->handler_exit_time);
            pthread_mutex_unlock(&c->time_mutex);
            continue;
        }

        // 2) MISSING fault：首次触页（读/写都可能）
        hook_first_read_missing(c, page_addr, is_write, pagebuf);
        copy_page(c->uffd, page_addr, pagebuf, c->pagesz);
        
        // 记录离开 handler 的时间（总是记录）
        pthread_mutex_lock(&c->time_mutex);
        clock_gettime(CLOCK_MONOTONIC, &c->handler_exit_time);
        pthread_mutex_unlock(&c->time_mutex);
    }
    return NULL;
}

// 你要的“无效化方法”：让下一次访问该页再次打印
// 原理：madvise(DONTNEED) 让该页 PTE 被 zapped（RSS 立刻下降；共享映射释放时机由内核决定）
// 下次访问通常变成 MINOR fault（我们注册了 MINOR_SHMEM），会再次 print；写也会再次 WP（我们 re-arm）
static void invalidate_page(ctx_t *c, void *any_addr_in_page) {
    void *page = page_align(any_addr_in_page, c->pagesz);

    if (madvise(page, c->pagesz, MADV_DONTNEED) == -1) die("madvise(MADV_DONTNEED)");

    fprintf(stderr, "[INVAL]   page=%p done\n", page);
    fflush(stderr);
}

int main() {
    ctx_t c;
    c.pagesz = (size_t)sysconf(_SC_PAGESIZE);
    c.len = 4 * c.pagesz;
    c.timing_active = 0;
    if (pthread_mutex_init(&c.time_mutex, NULL) != 0) die("pthread_mutex_init");

    const char *path = "/dev/shm/uffd_shm_demo.bin";
    c.fd = open(path, O_CREAT | O_RDWR, 0600);
    if (c.fd == -1) die("open(/dev/shm file)");
    if (ftruncate(c.fd, (off_t)c.len) == -1) die("ftruncate");

    c.base = mmap(NULL, c.len, PROT_READ | PROT_WRITE, MAP_SHARED, c.fd, 0);
    if (c.base == MAP_FAILED) die("mmap");

    c.uffd = uffd_open(O_CLOEXEC | O_NONBLOCK);
    if (c.uffd == -1) die("userfaultfd");

    struct uffdio_api ua;
    memset(&ua, 0, sizeof(ua));
    ua.api = UFFD_API;

    // 请求我们需要的 feature（内核会返回实际启用的 feature 集合）
    ua.features = UFFD_FEATURE_MISSING_SHMEM |
                  UFFD_FEATURE_MINOR_SHMEM;

    if (ioctl(c.uffd, UFFDIO_API, &ua) == -1) die("UFFDIO_API");

    // 强约束：没有这些 feature，这个 demo 就达不到“invalidate 后还能再次 print”
    if (!(ua.features & UFFD_FEATURE_MISSING_SHMEM)) {
        fprintf(stderr, "Need UFFD_FEATURE_MISSING_SHMEM for /dev/shm mapping.\n");
        return 2;
    }
    if (!(ua.features & UFFD_FEATURE_MINOR_SHMEM)) {
        fprintf(stderr, "Need UFFD_FEATURE_MINOR_SHMEM to re-print after invalidate.\n");
        return 2;
    }

    struct uffdio_register ur;
    memset(&ur, 0, sizeof(ur));
    ur.range.start = (unsigned long)c.base;
    ur.range.len   = c.len;
    ur.mode = UFFDIO_REGISTER_MODE_MISSING |
              UFFDIO_REGISTER_MODE_MINOR ;

    if (ioctl(c.uffd, UFFDIO_REGISTER, &ur) == -1) die("UFFDIO_REGISTER");

    pthread_t th;
    if (pthread_create(&th, NULL, fault_handler, &c) != 0) die("pthread_create");

    fprintf(stderr, "Mapped %s at %p (len=%zu)\n", path, c.base, c.len);
    fflush(stderr);

    // ==== 选第 2 页做演示 ====
    volatile uint8_t *p = c.base + c.pagesz;  // 目标页内任意地址
    fprintf(stderr, "\n== First cycle ==\n");
    fflush(stderr);

    // 首次读：会触发 [MISSING]
    // 使用内存屏障确保 trigger_time 在主线程访问内存之前被设置
    pthread_mutex_lock(&c.time_mutex);
    c.timing_active = 1;
    clock_gettime(CLOCK_MONOTONIC, &c.trigger_time);
    pthread_mutex_unlock(&c.time_mutex);
    // 内存屏障：确保 trigger_time 的设置对 handler 线程可见
    __sync_synchronize();
    
    volatile uint8_t v = p[0];
    
    // 记录恢复时间并计算
    pthread_mutex_lock(&c.time_mutex);
    clock_gettime(CLOCK_MONOTONIC, &c.resume_time);
    if (c.timing_active) {
        double to_handler_ns = timespec_diff_ns(&c.trigger_time, &c.handler_entry_time);
        double handler_duration_ns = timespec_diff_ns(&c.handler_entry_time, &c.handler_exit_time);
        double from_handler_ns = timespec_diff_ns(&c.handler_exit_time, &c.resume_time);
        fprintf(stderr, "[TIMING] MISSING fault: trigger->handler=%.2f ns, handler_duration=%.2f ns, handler->resume=%.2f ns\n",
                to_handler_ns, handler_duration_ns, from_handler_ns);
        fflush(stderr);
        c.timing_active = 0;
    }
    pthread_mutex_unlock(&c.time_mutex);
    
    (void)v;

    // 首次写：会触发 [WP]
    pthread_mutex_lock(&c.time_mutex);
    c.timing_active = 1;
    clock_gettime(CLOCK_MONOTONIC, &c.trigger_time);
    pthread_mutex_unlock(&c.time_mutex);
    __sync_synchronize();
    
    p[0] = 0x41;
    
    // 记录恢复时间并计算
    pthread_mutex_lock(&c.time_mutex);
    clock_gettime(CLOCK_MONOTONIC, &c.resume_time);
    if (c.timing_active) {
        double to_handler_ns = timespec_diff_ns(&c.trigger_time, &c.handler_entry_time);
        double handler_duration_ns = timespec_diff_ns(&c.handler_entry_time, &c.handler_exit_time);
        double from_handler_ns = timespec_diff_ns(&c.handler_exit_time, &c.resume_time);
        fprintf(stderr, "[TIMING] WP fault: trigger->handler=%.2f ns, handler_duration=%.2f ns, handler->resume=%.2f ns\n",
                to_handler_ns, handler_duration_ns, from_handler_ns);
        fflush(stderr);
        c.timing_active = 0;
    }
    pthread_mutex_unlock(&c.time_mutex);

    fprintf(stderr, "\n== Invalidate and cycle again ==\n");
    fflush(stderr);

    invalidate_page(&c, (void*)p);

    // invalidate 后再次读：会触发 [MINOR]（或极少数情况下又是 [MISSING]，也一样会 print）
    pthread_mutex_lock(&c.time_mutex);
    c.timing_active = 1;
    clock_gettime(CLOCK_MONOTONIC, &c.trigger_time);
    pthread_mutex_unlock(&c.time_mutex);
    __sync_synchronize();
    
    v = p[0];
    
    // 记录恢复时间并计算
    pthread_mutex_lock(&c.time_mutex);
    clock_gettime(CLOCK_MONOTONIC, &c.resume_time);
    if (c.timing_active) {
        double to_handler_ns = timespec_diff_ns(&c.trigger_time, &c.handler_entry_time);
        double handler_duration_ns = timespec_diff_ns(&c.handler_entry_time, &c.handler_exit_time);
        double from_handler_ns = timespec_diff_ns(&c.handler_exit_time, &c.resume_time);
        fprintf(stderr, "[TIMING] MINOR fault: trigger->handler=%.2f ns, handler_duration=%.2f ns, handler->resume=%.2f ns\n",
                to_handler_ns, handler_duration_ns, from_handler_ns);
        fflush(stderr);
        c.timing_active = 0;
    }
    pthread_mutex_unlock(&c.time_mutex);
    
    (void)v;

    // 计时 invalidate_page 调用
    struct timespec inval_start, inval_end;
    clock_gettime(CLOCK_MONOTONIC, &inval_start);
    invalidate_page(&c, (void*)p);
    clock_gettime(CLOCK_MONOTONIC, &inval_end);
    double inval_duration_ns = timespec_diff_ns(&inval_start, &inval_end);
    fprintf(stderr, "[TIMING] invalidate_page: duration=%.2f ns (%.2f us)\n",
            inval_duration_ns, inval_duration_ns / 1000.0);
    fflush(stderr);

    // invalidate 后再次写：会再次触发 [WP]
    pthread_mutex_lock(&c.time_mutex);
    c.timing_active = 1;
    clock_gettime(CLOCK_MONOTONIC, &c.trigger_time);
    pthread_mutex_unlock(&c.time_mutex);
    __sync_synchronize();
    
    p[0] = 0x42;
    
    // 记录恢复时间并计算
    pthread_mutex_lock(&c.time_mutex);
    clock_gettime(CLOCK_MONOTONIC, &c.resume_time);
    if (c.timing_active) {
        double to_handler_ns = timespec_diff_ns(&c.trigger_time, &c.handler_entry_time);
        double handler_duration_ns = timespec_diff_ns(&c.handler_entry_time, &c.handler_exit_time);
        double from_handler_ns = timespec_diff_ns(&c.handler_exit_time, &c.resume_time);
        fprintf(stderr, "[TIMING] WP fault (after invalidate): trigger->handler=%.2f ns, handler_duration=%.2f ns, handler->resume=%.2f ns\n",
                to_handler_ns, handler_duration_ns, from_handler_ns);
        fflush(stderr);
        c.timing_active = 0;
    }
    pthread_mutex_unlock(&c.time_mutex);

    fprintf(stderr, "\nDone. (Press Ctrl+C)\n");
    fflush(stderr);

    pause();
    return 0;
}
