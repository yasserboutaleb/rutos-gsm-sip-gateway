/*
 * TEST ONLY (QEMU bench): qemu-user does not translate TIOCGEXCL/TIOCEXCL for MIPS and
 * returns ENOSYS. The real 5.4 kernel of the RUT360 implements them: this shim is never
 * installed on the router.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdarg.h>
#include <sys/ioctl.h>

int ioctl(int fd, int req, ...)
{
    static int (*real_ioctl)(int, int, ...);
    va_list ap;
    va_start(ap, req);
    void* arg = va_arg(ap, void*);
    va_end(ap);
    if (!real_ioctl) {
        real_ioctl = (int (*)(int, int, ...))dlsym(RTLD_NEXT, "ioctl");
    }
    const int r = real_ioctl(fd, req, arg);
    if (r < 0 && (errno == ENOSYS || errno == ENOTTY || errno == EINVAL)) {
        if ((unsigned)req == (unsigned)TIOCGEXCL) {
            if (arg) {
                *(int*)arg = 0;
            }
            return 0;
        }
        if ((unsigned)req == (unsigned)TIOCEXCL || (unsigned)req == (unsigned)TIOCNXCL) {
            return 0;
        }
    }
    return r;
}
