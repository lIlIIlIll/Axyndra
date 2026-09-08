#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
int rename(const char *from, const char *to) {
    static int fired;
    const char *target = getenv("AXYNDRA_FAIL_RENAME_SUFFIX");
    size_t n = strlen(to), m = target ? strlen(target) : 0;
    if (!fired && m && n >= m && !strcmp(to + n - m, target)) {
        fired = 1;
        errno = EACCES;
        return -1;
    }
    return ((int (*)(const char *, const char *))dlsym(RTLD_NEXT, "rename"))(from,to);
}
