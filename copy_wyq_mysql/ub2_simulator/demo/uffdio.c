#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/userfaultfd.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static int uffd_open(int flags) {
    return (int)syscall(__NR_userfaultfd, flags);
}

int main() {
    int uffd = uffd_open(O_CLOEXEC | O_NONBLOCK);
    if (uffd < 0) {
        fprintf(stderr, "userfaultfd syscall failed: %s\n", strerror(errno));
        return 1;
    }

    // 1) probe supported features: set features=0
    struct uffdio_api ua;
    memset(&ua, 0, sizeof(ua));
    ua.api = UFFD_API;
    ua.features = 0;

    if (ioctl(uffd, UFFDIO_API, &ua) == -1) {
        fprintf(stderr, "UFFDIO_API probe failed: %s\n", strerror(errno));
        return 2;
    }

    printf("kernel_supported_features=0x%llx\n",
           (unsigned long long)ua.features);

#ifdef UFFD_FEATURE_MOVE
    printf("UFFD_FEATURE_MOVE: %s\n",
           (ua.features & UFFD_FEATURE_MOVE) ? "YES" : "NO");
#else
    printf("UFFD_FEATURE_MOVE: (not in headers) -> upgrade linux headers\n");
#endif

    close(uffd);
    return 0;
}
