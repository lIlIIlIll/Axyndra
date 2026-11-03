/* Test-only instrumentation. Includes the exact production translation unit;
 * wrappers record opens and pause at a real fd boundary, never mock file IO. */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <linux/openat2.h>
#include <string.h>
#include <time.h>
static _Atomic int test_content_opens, test_nonregular_opens;
static _Atomic int test_pause, test_entered, test_released;
static void test_pause_at_reopen(void) {
    if (!atomic_load(&test_pause)) return;
    atomic_store(&test_entered, 1);
    struct timespec delay={0,1000000};
    for (int n=0;n<3000 && !atomic_load(&test_released);n++) nanosleep(&delay,NULL);
}
static void test_observe_path(const char *path, unsigned long flags) {
    if (flags & O_PATH) return;
    atomic_fetch_add(&test_content_opens,1);
    struct stat st;
    if (stat(path,&st)==0 && !S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode))
        atomic_fetch_add(&test_nonregular_opens,1);
}
static int test_open(const char *path,int flags,...) {
    mode_t mode=0;
    if (flags & O_CREAT) { va_list ap;va_start(ap,flags);mode=(mode_t)va_arg(ap,int);va_end(ap); }
    if (strncmp(path,"/proc/self/fd/",14)==0) test_pause_at_reopen();
    test_observe_path(path,(unsigned long)flags);
    return (int)syscall(SYS_openat,AT_FDCWD,path,flags,mode);
}
static long test_syscall(long number,...) {
    va_list ap;va_start(ap,number);long result;
    if (number==SYS_openat2) {
        int fd=va_arg(ap,int);const char *path=va_arg(ap,const char *);
        struct open_how *how=va_arg(ap,struct open_how *);size_t size=va_arg(ap,size_t);
        if (!(how->flags & O_PATH)) {
            atomic_fetch_add(&test_content_opens,1);
            struct stat st;
            if (fstatat(fd,path,&st,0)==0 && !S_ISREG(st.st_mode) && !S_ISDIR(st.st_mode))
                atomic_fetch_add(&test_nonregular_opens,1);
        }
        result=syscall(number,fd,path,how,size);
    } else if (number==SYS_renameat2) {
        int a=va_arg(ap,int);const char *b=va_arg(ap,const char *);
        int c=va_arg(ap,int);const char *d=va_arg(ap,const char *);unsigned flags=va_arg(ap,unsigned);
        result=syscall(number,a,b,c,d,flags);
    } else if (number==SYS_close_range) {
        unsigned first=va_arg(ap,unsigned),last=va_arg(ap,unsigned);int flags=va_arg(ap,int);
        result=syscall(number,first,last,flags);
    } else {errno=ENOSYS;result=-1;}
    va_end(ap);return result;
}
#define open test_open
#define syscall test_syscall
#include AXYNDRA_READ_VIEW_SOURCE
#undef open
#undef syscall
void read_view_test_reset(int pause) {
    atomic_store(&test_content_opens,0);atomic_store(&test_nonregular_opens,0);
    atomic_store(&test_entered,0);atomic_store(&test_released,0);atomic_store(&test_pause,pause);
}
int read_view_test_entered(void) {return atomic_load(&test_entered);}
void read_view_test_release(void) {atomic_store(&test_released,1);}
int read_view_test_content_opens(void) {return atomic_load(&test_content_opens);}
int read_view_test_nonregular_opens(void) {return atomic_load(&test_nonregular_opens);}
