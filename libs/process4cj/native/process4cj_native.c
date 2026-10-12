#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>
#include <limits.h>
#include <sys/prctl.h>
#include <sys/ioctl.h>
#include <linux/nsfs.h>
#if defined(__linux__)
#include <sys/inotify.h>
#endif

#include <linux/openat2.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/random.h>

extern char **environ;

static void p4_close_if_open(int fd) {
    if (fd >= 0) {
        while (close(fd) < 0 && errno == EINTR) {}
    }
}
static int p4_close_fd_range(unsigned int first, unsigned int last) {
    if (first > last) return 0;
#ifdef SYS_close_range
    if (syscall(SYS_close_range, first, last, 0) == 0) return 0;
    if (errno != ENOSYS && errno != EINVAL) return errno;
#endif
    struct rlimit limits;
    if (getrlimit(RLIMIT_NOFILE, &limits) < 0) return errno;
    unsigned long limit = limits.rlim_cur;
    if (limit > (unsigned long)INT_MAX + 1UL) {
        limit = (unsigned long)INT_MAX + 1UL;
    }
    for (unsigned long value = first; value < limit && value <= last; ++value) {
        p4_close_if_open((int)value);
    }
    return 0;
}

static int p4_close_all_except(const int *keep, size_t keep_count) {
    int sorted[16];
    size_t count = 0;
    for (size_t index = 0; index < keep_count; ++index) {
        int value = keep[index];
        if (value < STDERR_FILENO + 1) continue;
        if (count >= sizeof(sorted) / sizeof(sorted[0])) return E2BIG;
        size_t position = count;
        while (position > 0 && sorted[position - 1] > value) {
            sorted[position] = sorted[position - 1];
            --position;
        }
        if (position > 0 && sorted[position - 1] == value) continue;
        if (position < count && sorted[position] == value) continue;
        sorted[position] = value;
        ++count;
    }
    unsigned int first = STDERR_FILENO + 1;
    int first_error = 0;
    for (size_t index = 0; index < count; ++index) {
        unsigned int value = (unsigned int)sorted[index];
        if (first < value) {
            int error = p4_close_fd_range(first, value - 1);
            if (error != 0 && first_error == 0) first_error = error;
        }
        first = value + 1;
    }
    if (first <= UINT_MAX) {
        int error = p4_close_fd_range(first, UINT_MAX);
        if (error != 0 && first_error == 0) first_error = error;
    }
    return first_error;
}
static int p4_promote_pipe_fd(int *fd) {
    if (fd == NULL || *fd < 0 || *fd > STDERR_FILENO) return 0;
    int promoted = fcntl(*fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (promoted < 0) return errno;
    p4_close_if_open(*fd);
    *fd = promoted;
    return 0;
}

static int p4_write_spawn_error(int fd, int error_value) {
    const unsigned char *bytes = (const unsigned char *)&error_value;
    size_t offset = 0;
    while (offset < sizeof(error_value)) {
        ssize_t written = write(fd, bytes + offset, sizeof(error_value) - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return written < 0 ? errno : EPIPE;
        offset += (size_t)written;
    }
    return 0;
}

static const char *p4_environment_path(char *const envp[]) {
    char *const *values = envp == NULL ? environ : envp;
    if (values == NULL) return NULL;
    for (size_t index = 0; values[index] != NULL; ++index) {
        if (strncmp(values[index], "PATH=", 5) == 0) return values[index] + 5;
    }
    return NULL;
}

/*
 * execvpe is not async-signal-safe after fork from the multithreaded
 * Cangjie runtime.  Keep the supervisor child on the execve path and do
 * PATH lookup with fixed storage instead.
 */
static int p4_exec_with_path(
    const char *executable,
    char *const argv[],
    char *const envp[]
) {
    char *const *values = envp == NULL ? environ : envp;
    if (executable == NULL || argv == NULL) return EINVAL;
    if (strchr(executable, '/') != NULL) {
        execve(executable, argv, values);
        return errno;
    }
    const char *path = p4_environment_path(envp);
    if (path == NULL && envp != NULL) path = p4_environment_path(NULL);
    if (path == NULL) path = "/bin:/usr/bin";
    size_t executable_length = strlen(executable);
    char candidate[PATH_MAX];
    int first_error = ENOENT;
    const char *segment = path;
    for (;;) {
        const char *separator = strchr(segment, ':');
        size_t directory_length = separator == NULL
            ? strlen(segment)
            : (size_t)(separator - segment);
        size_t directory_prefix = directory_length == 0 ? 1 : directory_length;
        size_t candidate_length = directory_prefix + 1 + executable_length;
        if (candidate_length + 1 <= sizeof(candidate)) {
            size_t offset = 0;
            if (directory_length == 0) {
                candidate[offset++] = '.';
            } else {
                memcpy(candidate, segment, directory_length);
                offset = directory_length;
            }
            candidate[offset++] = '/';
            memcpy(candidate + offset, executable, executable_length);
            candidate[candidate_length] = '\0';
            execve(candidate, argv, values);
            int error = errno;
            if (error == EACCES) {
                first_error = EACCES;
            } else if (error != ENOENT && error != ENOTDIR &&
                       first_error == ENOENT) {
                first_error = error;
            }
        } else if (first_error == ENOENT) {
            first_error = ENAMETOOLONG;
        }
        if (separator == NULL) break;
        segment = separator + 1;
    }
    return first_error;
}

typedef struct {
    pid_t root_pid, payload_pid;
    uint64_t root_start, payload_start;
    /* Three exact payload namespaces plus the actual PID owning user FD. */
    int fds[4];
    /* Private copied launch mode, never a caller-supplied descriptor. */
    int defer_payload_user;
} p4_owned_namespaces;
static int p4_namespace_enter(const p4_owned_namespaces *value);
static void p4_namespace_close_fds(const p4_owned_namespaces *value);

static void p4_supervisor_exec_child(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int in_read,
    int in_write,
    int out_read,
    int out_write,
    int err_read,
    int err_write,
    int status_read,
    int status_write,
    int error_write,
    const p4_owned_namespaces *namespaces
) {
    pid_t parent_pid = getppid();
    int error = 0;
    if (parent_pid <= 1) {
        error = ESRCH;
    } else if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0) {
        error = errno;
    } else if (getppid() != parent_pid) {
        error = ESRCH;
    }
    if (error == 0 && signal(SIGTERM, SIG_DFL) == SIG_ERR) {
        error = errno;
    }
    if (error == 0) error = p4_namespace_enter(namespaces);
    if (error == 0 && working_directory != NULL &&
        working_directory[0] != '\0' && chdir(working_directory) < 0) {
        error = errno;
    }
    if (error == 0 && dup2(in_read, STDIN_FILENO) < 0) error = errno;
    if (error == 0 && dup2(out_write, STDOUT_FILENO) < 0) error = errno;
    if (error == 0 && dup2(err_write, STDERR_FILENO) < 0) error = errno;
    if (error != 0) {
        (void)p4_write_spawn_error(error_write, error);
        _exit(127);
    }
    p4_close_if_open(in_read);
    p4_close_if_open(in_write);
    p4_close_if_open(out_read);
    p4_close_if_open(out_write);
    p4_close_if_open(err_read);
    p4_close_if_open(err_write);
    p4_close_if_open(status_read);
    p4_close_if_open(status_write);
    error = p4_exec_with_path(executable, argv, envp);
    (void)p4_write_spawn_error(error_write, error);
    p4_close_if_open(error_write);
    _exit(127);
}

static void p4_supervisor_child(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int in_read,
    int in_write,
    int out_read,
    int out_write,
    int err_read,
    int err_write,
    int status_read,
    int status_write,
    int error_write,
    const p4_owned_namespaces *namespaces
) {
    if (setsid() < 0) {
        (void)p4_write_spawn_error(error_write, errno);
        _exit(127);
    }
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) < 0) {
        (void)p4_write_spawn_error(error_write, errno);
        _exit(127);
    }
    if (signal(SIGTERM, SIG_IGN) == SIG_ERR) {
        (void)p4_write_spawn_error(error_write, errno);
        _exit(127);
    }
    /*
     * A forked process inherits the broker's listener and lock descriptors.
     * Keep only the endpoints needed by this supervisor and its command;
     * otherwise an orphaned supervisor can keep a dead broker endpoint alive.
     */
    int inherited_fds[] = {
        in_read,
        in_write,
        out_read,
        out_write,
        err_read,
        err_write,
        status_read,
        status_write,
        error_write,
        namespaces == NULL ? -1 : namespaces->fds[0],
        namespaces == NULL ? -1 : namespaces->fds[1],
        namespaces == NULL ? -1 : namespaces->fds[2],
        namespaces == NULL ? -1 : namespaces->fds[3]
    };
    int close_error = p4_close_all_except(
        inherited_fds,
        sizeof(inherited_fds) / sizeof(inherited_fds[0])
    );
    if (close_error != 0) {
        (void)p4_write_spawn_error(error_write, close_error);
        _exit(127);
    }

    pid_t command_pid = fork();
    if (command_pid < 0) {
        (void)p4_write_spawn_error(error_write, errno);
        _exit(127);
    }
    if (command_pid == 0) {
        p4_supervisor_exec_child(
            executable,
            argv,
            envp,
            working_directory,
            in_read,
            in_write,
            out_read,
            out_write,
            err_read,
            err_write,
            status_read,
            status_write,
            error_write,
            namespaces
        );
        _exit(127);
    }
    p4_namespace_close_fds(namespaces);
    p4_close_if_open(in_read);
    p4_close_if_open(in_write);
    p4_close_if_open(out_read);
    p4_close_if_open(out_write);
    p4_close_if_open(err_read);
    p4_close_if_open(err_write);
    p4_close_if_open(status_read);
    p4_close_if_open(error_write);

    int command_status = 127;
    int command_reaped = 0;
    int status_sent = 0;
    for (;;) {
        int status = 0;
        pid_t waited;
        do { waited = waitpid(-1, &status, 0); }
        while (waited < 0 && errno == EINTR);
        if (waited < 0) {
            if (errno == ECHILD) break;
            _exit(127);
        }
        if (waited == command_pid) {
            command_reaped = 1;
            if (WIFEXITED(status)) {
                command_status = WEXITSTATUS(status);
            } else if (WIFSIGNALED(status)) {
                command_status = 128 + WTERMSIG(status);
            }
            (void)p4_write_spawn_error(status_write, command_status);
            p4_close_if_open(status_write);
            status_write = -1;
            status_sent = 1;
        }
    }
    if (!status_sent) p4_close_if_open(status_write);
    _exit(command_reaped ? command_status : 127);
}

static int p4_spawn_supervisor(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int in_pipe[2],
    int out_pipe[2],
    int err_pipe[2],
    int status_pipe[2],
    int error_pipe[2],
    pid_t *pid_out,
    const p4_owned_namespaces *namespaces
) {
    pid_t parent_pid = getpid();
    pid_t supervisor = fork();
    if (supervisor < 0) return errno;
    if (supervisor == 0) {
        p4_close_if_open(error_pipe[0]);
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0) {
            (void)p4_write_spawn_error(error_pipe[1], errno);
            _exit(127);
        }
        if (getppid() != parent_pid) {
            (void)p4_write_spawn_error(error_pipe[1], ESRCH);
            _exit(127);
        }
        p4_supervisor_child(
            executable,
            argv,
            envp,
            working_directory,
            in_pipe[0],
            in_pipe[1],
            out_pipe[0],
            out_pipe[1],
            err_pipe[0],
            err_pipe[1],
            status_pipe[0],
            status_pipe[1],
            error_pipe[1],
            namespaces
        );
        _exit(127);
    }
    p4_close_if_open(error_pipe[1]);
    error_pipe[1] = -1;
    unsigned char bytes[sizeof(int)];
    size_t received = 0;
    int read_error = 0;
    for (;;) {
        unsigned char buffer[sizeof(int)];
        ssize_t count = read(
            error_pipe[0],
            buffer,
            sizeof(buffer)
        );
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            read_error = errno;
            break;
        }
        if (count == 0) break;
        if (received + (size_t)count > sizeof(bytes)) {
            read_error = EPROTO;
            break;
        }
        memcpy(bytes + received, buffer, (size_t)count);
        received += (size_t)count;
    }
    p4_close_if_open(error_pipe[0]);
    error_pipe[0] = -1;
    if (read_error != 0 || received == sizeof(bytes)) {
        int error = read_error;
        if (error == 0) memcpy(&error, bytes, sizeof(error));
        (void)kill(supervisor, SIGKILL);
        (void)waitpid(supervisor, NULL, 0);
        return error == 0 ? EIO : error;
    }
    *pid_out = supervisor;
    return 0;
}

static int32_t p4_spawn_process_internal(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int32_t new_session,
    int64_t *pid_out,
    int32_t *stdin_out,
    int32_t *stdout_out,
    int32_t *stderr_out,
    int32_t *status_out,
    const p4_owned_namespaces *namespaces
) {
    int in_pipe[2] = {-1, -1};
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};
    int status_pipe[2] = {-1, -1};
    int error_pipe[2] = {-1, -1};
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int actions_ready = 0;
    int attributes_ready = 0;
    int result = 0;
    pid_t pid = -1;

    if (pipe2(in_pipe, O_CLOEXEC) < 0 || pipe2(out_pipe, O_CLOEXEC) < 0 ||
        pipe2(err_pipe, O_CLOEXEC) < 0) {
        result = errno;
        goto cleanup;
    }
    /*
     * Keep every pipe endpoint above stderr.  Otherwise a caller with a
     * closed standard descriptor can make pipe2 reuse that descriptor; the
     * later dup2 followed by addclose would then close the child's remapped
     * stdin, stdout, or stderr.
     */
    if ((result = p4_promote_pipe_fd(&in_pipe[0])) != 0 ||
        (result = p4_promote_pipe_fd(&in_pipe[1])) != 0 ||
        (result = p4_promote_pipe_fd(&out_pipe[0])) != 0 ||
        (result = p4_promote_pipe_fd(&out_pipe[1])) != 0 ||
        (result = p4_promote_pipe_fd(&err_pipe[0])) != 0 ||
        (result = p4_promote_pipe_fd(&err_pipe[1])) != 0) goto cleanup;
    if (new_session) {
        if (pipe2(status_pipe, O_CLOEXEC) < 0 ||
            pipe2(error_pipe, O_CLOEXEC) < 0) {
            result = errno;
            goto cleanup;
        }
        if ((result = p4_promote_pipe_fd(&status_pipe[0])) != 0 ||
            (result = p4_promote_pipe_fd(&status_pipe[1])) != 0 ||
            (result = p4_promote_pipe_fd(&error_pipe[0])) != 0 ||
            (result = p4_promote_pipe_fd(&error_pipe[1])) != 0) goto cleanup;
        result = p4_spawn_supervisor(
            executable,
            argv,
            envp,
            working_directory,
            in_pipe,
            out_pipe,
            err_pipe,
            status_pipe,
            error_pipe,
            &pid,
            namespaces
        );
        if (result != 0) goto cleanup;
        p4_close_if_open(in_pipe[0]); in_pipe[0] = -1;
        p4_close_if_open(out_pipe[1]); out_pipe[1] = -1;
        p4_close_if_open(err_pipe[1]); err_pipe[1] = -1;
        p4_close_if_open(status_pipe[1]); status_pipe[1] = -1;
        *pid_out = (int64_t)pid;
        *stdin_out = in_pipe[1]; in_pipe[1] = -1;
        *stdout_out = out_pipe[0]; out_pipe[0] = -1;
        *stderr_out = err_pipe[0]; err_pipe[0] = -1;
        *status_out = status_pipe[0]; status_pipe[0] = -1;
        goto cleanup;
    }
    if ((result = posix_spawn_file_actions_init(&actions)) != 0) goto cleanup;
    actions_ready = 1;
    if ((result = posix_spawn_file_actions_adddup2(&actions, in_pipe[0], STDIN_FILENO)) != 0 ||
        (result = posix_spawn_file_actions_adddup2(&actions, out_pipe[1], STDOUT_FILENO)) != 0 ||
        (result = posix_spawn_file_actions_adddup2(&actions, err_pipe[1], STDERR_FILENO)) != 0 ||
        (result = posix_spawn_file_actions_addclose(&actions, in_pipe[1])) != 0 ||
        (result = posix_spawn_file_actions_addclose(&actions, out_pipe[0])) != 0 ||
        (result = posix_spawn_file_actions_addclose(&actions, err_pipe[0])) != 0) goto cleanup;
    /* Do not let forked descendants retain the original pipe endpoints. */
    if (in_pipe[0] != STDIN_FILENO &&
        (result = posix_spawn_file_actions_addclose(&actions, in_pipe[0])) != 0) goto cleanup;
    if (out_pipe[1] != STDOUT_FILENO &&
        (result = posix_spawn_file_actions_addclose(&actions, out_pipe[1])) != 0) goto cleanup;
    if (err_pipe[1] != STDERR_FILENO &&
        (result = posix_spawn_file_actions_addclose(&actions, err_pipe[1])) != 0) goto cleanup;
    if (working_directory != NULL && working_directory[0] != '\0' &&
        (result = posix_spawn_file_actions_addchdir_np(&actions, working_directory)) != 0) goto cleanup;
    if ((result = posix_spawnattr_init(&attributes)) != 0) goto cleanup;
    attributes_ready = 1;
    result = posix_spawnp(
        &pid, executable, &actions, &attributes, argv,
        envp == NULL ? environ : envp
    );
    if (result != 0) goto cleanup;

    p4_close_if_open(in_pipe[0]); in_pipe[0] = -1;
    p4_close_if_open(out_pipe[1]); out_pipe[1] = -1;
    p4_close_if_open(err_pipe[1]); err_pipe[1] = -1;
    *pid_out = (int64_t)pid;
    *stdin_out = in_pipe[1]; in_pipe[1] = -1;
    *stdout_out = out_pipe[0]; out_pipe[0] = -1;
    *stderr_out = err_pipe[0]; err_pipe[0] = -1;
    *status_out = -1;

cleanup:
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    p4_close_if_open(in_pipe[0]); p4_close_if_open(in_pipe[1]);
    p4_close_if_open(out_pipe[0]); p4_close_if_open(out_pipe[1]);
    p4_close_if_open(err_pipe[0]); p4_close_if_open(err_pipe[1]);
    p4_close_if_open(status_pipe[0]); p4_close_if_open(status_pipe[1]);
    p4_close_if_open(error_pipe[0]); p4_close_if_open(error_pipe[1]);
    return (int32_t)result;
}

int32_t process4cj_spawn(
    const char *executable, char *const argv[], char *const envp[],
    const char *working_directory, int32_t new_session, int64_t *pid_out,
    int32_t *stdin_out, int32_t *stdout_out, int32_t *stderr_out, int32_t *status_out
) {
    return p4_spawn_process_internal(executable, argv, envp, working_directory,
        new_session, pid_out, stdin_out, stdout_out, stderr_out, status_out, NULL);
}

int64_t process4cj_read(int32_t fd, uint8_t *buffer, int64_t length) {
    ssize_t result;
    do { result = read(fd, buffer, (size_t)length); } while (result < 0 && errno == EINTR);
    return result < 0 ? -(int64_t)errno : (int64_t)result;
}

int32_t process4cj_wait_readable(int32_t fd, int32_t timeout_millis) {
    struct pollfd descriptor = {
        .fd = fd,
        .events = POLLIN | POLLHUP,
        .revents = 0,
    };
    int result;
    do { result = poll(&descriptor, 1, timeout_millis); }
    while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    if (result == 0) return 0;
    if ((descriptor.revents & POLLNVAL) != 0) return -EBADF;
    return 1;
}

int32_t process4cj_write_all(int32_t fd, const uint8_t *buffer, int64_t length) {
    sigset_t blocked;
    sigset_t previous;
    sigset_t pending;
    int previously_pending = 0;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    if (pthread_sigmask(SIG_BLOCK, &blocked, &previous) == 0) {
        if (sigpending(&pending) == 0) previously_pending = sigismember(&pending, SIGPIPE);
    }
    int64_t offset = 0;
    int32_t error = 0;
    while (offset < length) {
        ssize_t result = write(fd, buffer + offset, (size_t)(length - offset));
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) { error = (int32_t)errno; break; }
        offset += (int64_t)result;
    }
    if (error == EPIPE && !previously_pending) {
        struct timespec no_wait = {0, 0};
        (void)sigtimedwait(&blocked, NULL, &no_wait);
    }
    (void)pthread_sigmask(SIG_SETMASK, &previous, NULL);
    return error;
}

/* Exclusive borrowed pipe/socket writer. The duplicate pins the actual open
 * file description; neither cleanup nor an fd-number reuse can close/alter a
 * later fd1. O_NONBLOCK is shared, so the frontend must own all writes until
 * release restores the original flags. Regular files are explicitly unsupported
 * because nonblocking flags cannot bound filesystem I/O latency. */
int32_t process4cj_borrow_writer(int32_t fd, int32_t *original_flags) {
    if (fd < 0 || original_flags == NULL) return -EINVAL;
    struct stat info;
    if (fstat(fd, &info) < 0) return -errno;
    if (!S_ISFIFO(info.st_mode) && !S_ISSOCK(info.st_mode)) return -ENOTSUP;
    int held = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    if (held < 0) return -errno;
    int flags = fcntl(held, F_GETFL);
    if (flags < 0 || (flags & O_ACCMODE) == O_RDONLY) {
        int error = flags < 0 ? errno : EBADF; close(held); return -error;
    }
    if (fcntl(held, F_SETFL, flags | O_NONBLOCK) < 0) {
        int error = errno; close(held); return -error;
    }
    *original_flags = flags;
    return held;
}
int32_t process4cj_wait_writable(int32_t fd, int32_t timeout_millis) {
    if (fd < 0 || timeout_millis < 0 || timeout_millis > 25) return -EINVAL;
    struct pollfd descriptor = {.fd = fd, .events = POLLOUT, .revents = 0};
    int result = poll(&descriptor, 1, timeout_millis);
    if (result < 0) return errno == EINTR ? 0 : -errno;
    if (result == 0) return 0;
    if (descriptor.revents & POLLNVAL) return -EBADF;
    if (descriptor.revents & (POLLERR | POLLHUP)) return -EPIPE;
    return (descriptor.revents & POLLOUT) ? 1 : 0;
}
int64_t process4cj_try_write(int32_t fd, const uint8_t *buffer, int64_t length) {
    if (fd < 0 || buffer == NULL || length < 1 || length > 4096) return -EINVAL;
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return -errno;
    if (!(flags & O_NONBLOCK)) return -EINVAL;
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked); sigaddset(&blocked, SIGPIPE);
    int masked = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (masked != 0) return -masked;
    int previously_pending = sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE);
    ssize_t written = write(fd, buffer, (size_t)length);
    int error = written < 0 ? errno : 0;
    if (error == EPIPE && !previously_pending) {
        struct timespec no_wait = {0, 0}; (void)sigtimedwait(&blocked, NULL, &no_wait);
    }
    (void)pthread_sigmask(SIG_SETMASK, &previous, NULL);
    if (error == EAGAIN || error == EWOULDBLOCK || error == EINTR) return 0;
    return error ? -(int64_t)error : (int64_t)written;
}
int32_t process4cj_release_writer(int32_t held_fd, int32_t original_flags) {
    if (held_fd < 0) return EINVAL;
    if (fcntl(held_fd, F_SETFL, original_flags) < 0) return errno;
    /* Linux closes the descriptor even on EINTR. Do not retry a reused number. */
    if (close(held_fd) < 0 && errno != EINTR) return errno;
    return 0;
}

int32_t process4cj_close(int32_t fd) {
    int result;
    do { result = close(fd); } while (result < 0 && errno == EINTR);
    return result == 0 ? 0 : (int32_t)errno;
}

/* Keep the exited leader reserved until the owner closes the process. This
 * pins the session/process-group ID while inherited output is still draining. */
int64_t process4cj_wait_owned(int64_t pid_value) {
    siginfo_t info = {0};
    int result;
    do { result = waitid(P_PID, (id_t)pid_value, &info, WEXITED | WNOWAIT); }
    while (result < 0 && errno == EINTR);
    if (result < 0) return -(int64_t)errno;
    return info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
}
int64_t process4cj_wait_status(int32_t fd) {
    if (fd < 0) return -EBADF;
    int32_t status = 0;
    unsigned char *bytes = (unsigned char *)&status;
    size_t offset = 0;
    while (offset < sizeof(status)) {
        ssize_t count = read(fd, bytes + offset, sizeof(status) - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) {
            int error = errno;
            p4_close_if_open(fd);
            return -(int64_t)error;
        }
        if (count == 0) {
            p4_close_if_open(fd);
            return -EPIPE;
        }
        offset += (size_t)count;
    }
    p4_close_if_open(fd);
    return (int64_t)status;
}

int64_t process4cj_wait(int64_t pid_value) {
    int status = 0;
    pid_t result;
    do { result = waitpid((pid_t)pid_value, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return -(int64_t)errno;
    if (WIFEXITED(status)) return (int64_t)WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return (int64_t)(128 + WTERMSIG(status));
    return 255;
}

/* Descendants may enter a different session (bubblewrap does this with
 * --new-session), so a process-group signal alone is not a complete owned
 * process-tree termination. Collect the direct-child tree before signalling
 * the root; reverse order avoids leaving descendants behind during teardown. */
#define P4_MAX_DESCENDANTS 4096
static int p4_parse_pid_name(const char *name, pid_t *pid_out) {
    if (name == NULL || pid_out == NULL || name[0] == '\0') return 0;
    char *end = NULL;
    errno = 0;
    long value = strtol(name, &end, 10);
    if (errno != 0 || end == name || *end != '\0' || value <= 0) return 0;
    pid_t pid = (pid_t)value;
    if ((long)pid != value) return 0;
    *pid_out = pid;
    return 1;
}


typedef struct {
    pid_t pid;
    uint64_t start_time;
    int valid;
} p4_process_target;

static int p4_read_process_stat(
    pid_t pid,
    pid_t *parent_pid,
    uint64_t *start_time,
    char *state
);
static void p4_sleep_millis(int32_t millis);
static p4_process_target p4_capture_target(pid_t pid);
static int p4_capture_child_target(
    pid_t child_pid,
    pid_t process_pid,
    pid_t thread_pid,
    p4_process_target *target_out
);
static int p4_target_matches(const p4_process_target *target);
static int p4_signal_target(const p4_process_target *target, int signal_value);
static int p4_stop_target(const p4_process_target *target);
static int p4_contains_target(
    const p4_process_target *targets,
    size_t count,
    const p4_process_target *candidate
);
static int p4_freeze_tree(
    const p4_process_target *root,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count
);
static int p4_continue_captured_tree(
    const p4_process_target *root,
    const p4_process_target *descendants,
    size_t count
);
static int p4_contains_target(
    const p4_process_target *targets,
    size_t count,
    const p4_process_target *candidate
) {
    if (targets == NULL || candidate == NULL || !candidate->valid) return 0;
    for (size_t index = 0; index < count; ++index) {
        if (targets[index].valid &&
            targets[index].pid == candidate->pid &&
            targets[index].start_time == candidate->start_time) {
            return 1;
        }
    }
    return 0;
}

static void p4_collect_descendants(
    pid_t pid,
    const p4_process_target *expected_target,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count,
    int *overflow,
    int depth
);
static void p4_collect_child_token(
    const char *token,
    pid_t process_pid,
    pid_t thread_pid,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count,
    int *overflow,
    int depth
) {
    if (token == NULL || token[0] == '\0') return;
    pid_t child = 0;
    if (!p4_parse_pid_name(token, &child)) return;
    p4_process_target child_target;
    if (!p4_capture_child_target(
            child, process_pid, thread_pid, &child_target)) {
        return;
    }
    if (p4_contains_target(descendants, *count, &child_target)) {
        p4_collect_descendants(
            child,
            &child_target,
            descendants,
            capacity,
            count,
            overflow,
            depth + 1
        );
        return;
    }
    if (*count >= capacity) {
        if (overflow != NULL) *overflow = 1;
        return;
    }
    descendants[(*count)++] = child_target;
    p4_collect_descendants(
        child,
        &child_target,
        descendants,
        capacity,
        count,
        overflow,
        depth + 1
    );
}

static void p4_collect_children_from_thread(
    pid_t process_pid,
    pid_t thread_pid,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count,
    int *overflow,
    int depth
) {
    if (process_pid <= 0 || thread_pid <= 0) return;
    char path[128];
    int length = snprintf(
        path, sizeof(path), "/proc/%ld/task/%ld/children",
        (long)process_pid, (long)thread_pid
    );
    if (length <= 0 || (size_t)length >= sizeof(path)) return;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    char buffer[4096];
    char token[32];
    size_t token_length = 0;
    int token_overflow = 0;
    for (;;) {
        ssize_t bytes;
        do { bytes = read(fd, buffer, sizeof(buffer)); }
        while (bytes < 0 && errno == EINTR);
        if (bytes <= 0) break;
        for (ssize_t index = 0; index < bytes; ++index) {
            char byte = buffer[index];
            if (byte >= '0' && byte <= '9') {
                if (!token_overflow) {
                    if (token_length + 1 >= sizeof(token)) {
                        token_overflow = 1;
                    } else {
                        token[token_length++] = byte;
                    }
                }
                continue;
            }
            if (token_length > 0 || token_overflow) {
                if (!token_overflow) {
                    token[token_length] = '\0';
                    p4_collect_child_token(
                        token,
                        process_pid,
                        thread_pid,
                        descendants,
                        capacity,
                        count,
                        overflow,
                        depth
                    );
                }
                token_length = 0;
                token_overflow = 0;
            }
        }
    }
    if (token_length > 0 || token_overflow) {
        if (!token_overflow) {
            token[token_length] = '\0';
            p4_collect_child_token(
                token,
                process_pid,
                thread_pid,
                descendants,
                capacity,
                count,
                overflow,
                depth
            );
        }
    }
    p4_close_if_open(fd);
}


static void p4_collect_descendants(
    pid_t pid,
    const p4_process_target *expected_target,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count,
    int *overflow,
    int depth
) {
    if (pid <= 0) return;
    if (depth < 0 || (size_t)depth > capacity) {
        if (overflow != NULL) *overflow = 1;
        return;
    }
    if (expected_target != NULL && !p4_target_matches(expected_target)) return;
    char path[96];
    int length = snprintf(path, sizeof(path), "/proc/%ld/task", (long)pid);
    if (length <= 0 || (size_t)length >= sizeof(path)) return;
    DIR *tasks = opendir(path);
    if (tasks == NULL) return;
    struct dirent *entry;
    while ((entry = readdir(tasks)) != NULL) {
        pid_t thread_pid = 0;
        if (!p4_parse_pid_name(entry->d_name, &thread_pid)) continue;
        p4_collect_children_from_thread(
            pid, thread_pid, descendants, capacity, count, overflow, depth
        );
    }
    closedir(tasks);
}


static int p4_signal_one(pid_t pid, int signal_value) {
    if (pid <= 0) return EINVAL;
    if (kill(pid, signal_value) == 0 || errno == ESRCH) return 0;
    return errno;
}

int32_t process4cj_kill(int64_t pid_value, int32_t force, int32_t process_group) {
    pid_t pid = (pid_t)pid_value;
    int signal_value = force ? SIGKILL : SIGTERM;
    if (pid <= 0) return EINVAL;
    if (!process_group) return (int32_t)p4_signal_one(pid, signal_value);
    p4_process_target *descendants = calloc(
        P4_MAX_DESCENDANTS,
        sizeof(*descendants)
    );
    if (descendants == NULL) return ENOMEM;
    size_t count = 0;
    int overflow = 0;
    p4_collect_descendants(
        pid,
        NULL,
        descendants,
        P4_MAX_DESCENDANTS,
        &count,
        &overflow,
        0
    );
    int first_error = overflow ? EOVERFLOW : 0;
    for (size_t index = count; index > 0; --index) {
        int result = p4_signal_target(&descendants[index - 1], signal_value);
        if (result != 0 && first_error == 0) first_error = result;
    }
    int result = kill(-pid, signal_value);
    if (result < 0 && errno != ESRCH && first_error == 0) first_error = errno;
    result = p4_signal_one(pid, signal_value);
    if (result != 0 && first_error == 0) first_error = result;
    free(descendants);
    return (int32_t)first_error;
}

static int p4_read_process_stat(
    pid_t pid,
    pid_t *parent_pid,
    uint64_t *start_time,
    char *state
) {
    if (pid <= 0 ||
        (parent_pid == NULL && start_time == NULL && state == NULL)) {
        return 0;
    }
    char path[96];
    int length = snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
    if (length <= 0 || (size_t)length >= sizeof(path)) return 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    char buffer[4096];
    ssize_t bytes;
    do { bytes = read(fd, buffer, sizeof(buffer) - 1); }
    while (bytes < 0 && errno == EINTR);
    p4_close_if_open(fd);
    if (bytes <= 0) return 0;
    buffer[bytes] = '\0';
    char *closing_name = strrchr(buffer, ')');
    if (closing_name == NULL || closing_name[1] != ' ') return 0;
    char *cursor = closing_name + 2;
    int parent_found = parent_pid == NULL;
    int start_found = start_time == NULL;
    int state_found = state == NULL;
    for (int field = 3; field <= 22; ++field) {
        while (*cursor == ' ') cursor++;
        if (*cursor == '\0' || *cursor == '\n') return 0;
        char *end = cursor;
        while (*end != '\0' && *end != ' ' && *end != '\n') end++;
        if (field == 3 && state != NULL) {
            if (end - cursor != 1) return 0;
            *state = *cursor;
            state_found = 1;
        }
        if (field == 4 && parent_pid != NULL) {
            errno = 0;
            char *parsed_end = NULL;
            long value = strtol(cursor, &parsed_end, 10);
            if (errno != 0 || parsed_end != end || value <= 0) return 0;
            pid_t parsed_parent = (pid_t)value;
            if ((long)parsed_parent != value) return 0;
            *parent_pid = parsed_parent;
            parent_found = 1;
        }
        if (field == 22 && start_time != NULL) {
            uint64_t value = 0;
            for (char *digit = cursor; digit < end; ++digit) {
                if (*digit < '0' || *digit > '9') return 0;
                uint64_t next = value * 10 + (uint64_t)(*digit - '0');
                if (next < value) return 0;
                value = next;
            }
            *start_time = value;
            start_found = 1;
        }
        cursor = end;
    }
    return parent_found && start_found && state_found;
}

static int p4_read_start_time(pid_t pid, uint64_t *start_time) {
    return p4_read_process_stat(pid, NULL, start_time, NULL);
}

int64_t process4cj_start_time(int64_t pid_value) {
    uint64_t start_time = 0;
    if (!p4_read_start_time((pid_t)pid_value, &start_time) || start_time == 0) {
        return 0;
    }
    return (int64_t)start_time;
}

static p4_process_target p4_capture_target(pid_t pid) {
    p4_process_target target = {pid, 0, 0};
    target.valid = p4_read_start_time(pid, &target.start_time);
    return target;
}
static int p4_capture_child_target(
    pid_t child_pid,
    pid_t process_pid,
    pid_t thread_pid,
    p4_process_target *target_out
) {
    if (child_pid <= 0 || process_pid <= 0 || thread_pid <= 0 ||
        target_out == NULL) {
        return 0;
    }
    pid_t parent_pid = 0;
    uint64_t start_time = 0;
    if (!p4_read_process_stat(child_pid, &parent_pid, &start_time, NULL) ||
        start_time == 0) {
        return 0;
    }
    if (parent_pid != process_pid && parent_pid != thread_pid) return 0;
    target_out->pid = child_pid;
    target_out->start_time = start_time;
    target_out->valid = 1;
    return 1;
}


static int p4_target_matches(const p4_process_target *target) {
    if (target == NULL || !target->valid) return 0;
    uint64_t start_time = 0;
    return p4_read_start_time(target->pid, &start_time) &&
        start_time == target->start_time;
}

static int p4_signal_target(const p4_process_target *target, int signal_value) {
    if (!p4_target_matches(target)) return 0;
    return p4_signal_one(target->pid, signal_value);
}
static int p4_stop_target(const p4_process_target *target) {
    if (!p4_target_matches(target)) return 0;
    if (kill(target->pid, SIGSTOP) < 0) {
        return errno == ESRCH ? 0 : errno;
    }
    for (int attempt = 0; attempt < 100; ++attempt) {
        uint64_t start_time = 0;
        char state = '\0';
        if (!p4_read_process_stat(
                target->pid, NULL, &start_time, &state)) {
            return 0;
        }
        if (start_time != target->start_time) return 0;
        if (state == 'T' || state == 't' || state == 'Z' || state == 'X') {
            return 0;
        }
        p4_sleep_millis(1);
    }
    return ETIMEDOUT;
}

static int p4_freeze_tree(
    const p4_process_target *root,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count
) {
    int first_error = p4_stop_target(root);
    if (first_error != 0) return first_error;
    int overflow = 0;
    for (;;) {
        size_t previous_count = *count;
        if (p4_target_matches(root)) {
            p4_collect_descendants(
                root->pid,
                root,
                descendants,
                capacity,
                count,
                &overflow,
                0
            );
        }
        for (size_t index = 0; index < *count; ++index) {
            int result = p4_stop_target(&descendants[index]);
            if (result != 0 && first_error == 0) first_error = result;
        }
        if (first_error != 0 || *count == previous_count) break;
    }
    if (first_error == 0 && overflow) first_error = EOVERFLOW;
    return first_error;
}

static int p4_continue_captured_tree(
    const p4_process_target *root,
    const p4_process_target *descendants,
    size_t count
) {
    int first_error = 0;
    for (size_t index = count; index > 0; --index) {
        int result = p4_signal_target(
            &descendants[index - 1],
            SIGCONT
        );
        if (result != 0 && first_error == 0) first_error = result;
    }
    if (p4_target_matches(root)) {
        int result = kill(-root->pid, SIGCONT);
        if (result < 0 && errno != ESRCH && first_error == 0) {
            first_error = errno;
        }
    }
    int result = p4_signal_target(root, SIGCONT);
    if (result != 0 && first_error == 0) first_error = result;
    return first_error;
}

static int p4_signal_captured_tree(
    const p4_process_target *root,
    const p4_process_target *descendants,
    size_t count,
    int signal_value
) {
    int first_error = 0;
    for (size_t index = count; index > 0; --index) {
        int result = p4_signal_target(&descendants[index - 1], signal_value);
        if (result != 0 && first_error == 0) first_error = result;
    }
    if (p4_target_matches(root)) {
        int result = kill(-root->pid, signal_value);
        if (result < 0 && errno != ESRCH && first_error == 0) {
            first_error = errno;
        }
    }
    int result = p4_signal_target(root, signal_value);
    if (result != 0 && first_error == 0) first_error = result;
    return first_error;
}

static void p4_sleep_millis(int32_t millis) {
    struct timespec remaining = {
        millis / 1000,
        (long)(millis % 1000) * 1000000L
    };
    while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
}
static int p4_any_captured_target_matches(
    const p4_process_target *root,
    const p4_process_target *descendants,
    size_t count
) {
    if (p4_target_matches(root)) return 1;
    for (size_t index = 0; index < count; ++index) {
        if (p4_target_matches(&descendants[index])) return 1;
    }
    return 0;
}

static void p4_wait_for_graceful_tree(
    const p4_process_target *root,
    const p4_process_target *descendants,
    size_t count,
    int32_t millis
) {
    int32_t remaining = millis;
    while (remaining > 0 &&
           p4_any_captured_target_matches(root, descendants, count)) {
        int32_t slice = remaining < 10 ? remaining : 10;
        p4_sleep_millis(slice);
        remaining -= slice;
    }
}


/*
 * Freeze the owned tree before signalling.  Stopping the root first prevents
 * new children at the ownership boundary; each observed descendant is then
 * stopped before its children are collected.  The fixed point pass closes
 * the fork window between reading a children list and stopping its parent.
 */
int32_t process4cj_terminate_tree(
    int64_t pid_value,
    int64_t expected_start_time,
    int32_t graceful_millis
) {
    pid_t pid = (pid_t)pid_value;
    if (pid <= 0 || expected_start_time < 0 || graceful_millis < 0) return EINVAL;
    p4_process_target root = p4_capture_target(pid);
    if (!root.valid ||
        (expected_start_time > 0 &&
         root.start_time != (uint64_t)expected_start_time)) {
        return ESRCH;
    }
    p4_process_target *descendants = calloc(
        P4_MAX_DESCENDANTS,
        sizeof(*descendants)
    );
    if (descendants == NULL) return ENOMEM;
    size_t count = 0;
    int freeze_error = p4_freeze_tree(
        &root,
        descendants,
        P4_MAX_DESCENDANTS,
        &count
    );
    if (freeze_error != 0) {
        (void)p4_continue_captured_tree(&root, descendants, count);
        int kill_error = p4_signal_captured_tree(
            &root,
            descendants,
            count,
            SIGKILL
        );
        free(descendants);
        return kill_error != 0 ? kill_error : freeze_error;
    }
    int first_error = 0;
    if (graceful_millis > 0) {
        first_error = p4_signal_captured_tree(
            &root,
            descendants,
            count,
            SIGTERM
        );
        int result = p4_continue_captured_tree(&root, descendants, count);
        if (result != 0 && first_error == 0) first_error = result;
        p4_wait_for_graceful_tree(
            &root,
            descendants,
            count,
            graceful_millis
        );
        /*
         * A SIGTERM handler can fork after the first snapshot. Stop the
         * supervisor again so the forced pass also owns those descendants.
         */
        count = 0;
        int refreeze_error = p4_freeze_tree(
            &root,
            descendants,
            P4_MAX_DESCENDANTS,
            &count
        );
        if (refreeze_error != 0) {
            (void)p4_continue_captured_tree(&root, descendants, count);
            int kill_error = p4_signal_captured_tree(
                &root,
                descendants,
                count,
                SIGKILL
            );
            free(descendants);
            return kill_error != 0 ? kill_error : refreeze_error;
        }
    }
    int result = p4_signal_captured_tree(
        &root,
        descendants,
        count,
        SIGKILL
    );
    if (result != 0 && first_error == 0) first_error = result;
    free(descendants);
    return (int32_t)first_error;
}

int32_t process4cj_is_alive(int64_t pid_value) {
    if (kill((pid_t)pid_value, 0) == 0 || errno == EPERM) return 1;
    return 0;
}

/* Preserve mode on an exclusively opened replacement without reopening its path. */
int32_t axyndra_workspace_copy_mode(const char *source, int32_t destination_fd) {
    struct stat info;
    if (stat(source, &info) < 0) return -errno;
    if (fchmod(destination_fd, info.st_mode & 07777) < 0) return -errno;
    return 0;
}

/* Atomically create without replacing a concurrently introduced destination. */
int32_t axyndra_workspace_create(const char *source, const char *destination) {
#ifdef SYS_renameat2
    if (syscall(SYS_renameat2, AT_FDCWD, source, AT_FDCWD, destination, 1U) < 0) {
        return -errno;
    }
    return 0;
#else
    (void)source;
    (void)destination;
    return -ENOTSUP;
#endif
}

/* POSIX rename preserves the destination when the operation fails. */
int32_t axyndra_workspace_replace(const char *source, const char *destination) {
    if (rename(source, destination) < 0) return -errno;
    return 0;
}

static int p4_workspace_same_identity(
    const struct stat *left,
    const struct stat *right
) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

typedef struct {
    int64_t files;
    int64_t bytes;
} p4_snapshot_copy_state;

static int p4_same_open_file(int left_fd, int right_fd) {
    struct stat left;
    struct stat right;
    if (fstat(left_fd, &left) < 0 || fstat(right_fd, &right) < 0) return -errno;
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

static int p4_fd_is_ancestor(int ancestor_fd, int child_fd) {
    int current = dup(child_fd);
    if (current < 0) return -errno;
    for (int depth = 0; depth < 1024; ++depth) {
        int same = p4_same_open_file(ancestor_fd, current);
        if (same != 0) {
            p4_close_if_open(current);
            return same;
        }
        int parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (parent < 0) {
            int error = errno;
            p4_close_if_open(current);
            return -error;
        }
        int at_root = p4_same_open_file(current, parent);
        p4_close_if_open(current);
        if (at_root < 0) {
            p4_close_if_open(parent);
            return at_root;
        }
        if (at_root == 1) {
            p4_close_if_open(parent);
            return 0;
        }
        current = parent;
    }
    p4_close_if_open(current);
    return -ELOOP;
}

static int p4_snapshot_copy_bytes(
    int source_fd,
    int destination_fd,
    int64_t max_bytes,
    int64_t *copied_bytes
) {
    /* This function also runs on Cangjie coroutine stacks. A 64 KiB C stack
     * frame can cross their guard page before read() is entered. Keep the
     * bounded transfer buffer on the heap and release it on every exit. */
    const size_t buffer_size = 65536;
    char *buffer = malloc(buffer_size);
    if (buffer == NULL) return -ENOMEM;
    int result = 0;
    *copied_bytes = 0;
    for (;;) {
        ssize_t count;
        do { count = read(source_fd, buffer, buffer_size); }
        while (count < 0 && errno == EINTR);
        if (count < 0) { result = -errno; break; }
        if (count == 0) break;
        if ((int64_t)count > max_bytes - *copied_bytes) { result = -EFBIG; break; }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written;
            do {
                written = write(destination_fd, buffer + offset, (size_t)(count - offset));
            } while (written < 0 && errno == EINTR);
            if (written < 0) { result = -errno; break; }
            if (written == 0) { result = -EIO; break; }
            offset += written;
        }
        if (result != 0) break;
        *copied_bytes += count;
    }
    free(buffer);
    return result;
}

static int p4_snapshot_copy_directory(
    int source_fd,
    int destination_fd,
    int depth,
    p4_snapshot_copy_state *state
) {
    if (depth > 64) return -ELOOP;
    int scan_fd = dup(source_fd);
    if (scan_fd < 0) return -errno;
    DIR *directory = fdopendir(scan_fd);
    if (directory == NULL) {
        int error = errno;
        p4_close_if_open(scan_fd);
        return -error;
    }
    int result = 0;
    errno = 0;
    for (struct dirent *entry = readdir(directory); entry != NULL; entry = readdir(directory)) {
        const char *name = entry->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) continue;
        if (strcmp(name, ".git") == 0 || strcmp(name, ".hg") == 0 ||
            strcmp(name, ".svn") == 0) continue;

        int child_fd = openat(
            source_fd,
            name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        );
        if (child_fd < 0) {
            result = -errno;
            break;
        }
        struct stat before;
        if (fstat(child_fd, &before) < 0) {
            result = -errno;
            p4_close_if_open(child_fd);
            break;
        }
        if (S_ISDIR(before.st_mode)) {
            if (mkdirat(destination_fd, name, 0700) < 0) {
                result = -errno;
                p4_close_if_open(child_fd);
                break;
            }
            int child_destination = openat(
                destination_fd,
                name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            );
            if (child_destination < 0) {
                result = -errno;
                p4_close_if_open(child_fd);
                break;
            }
            result = p4_snapshot_copy_directory(
                child_fd, child_destination, depth + 1, state
            );
            p4_close_if_open(child_destination);
        } else if (S_ISREG(before.st_mode)) {
            if (before.st_size < 0 || state->files >= 10000 ||
                before.st_size > 268435456 - state->bytes) {
                result = -EFBIG;
                p4_close_if_open(child_fd);
                break;
            }
            int child_destination = openat(
                destination_fd,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0600 | (before.st_mode & 0111)
            );
            if (child_destination < 0) {
                result = -errno;
                p4_close_if_open(child_fd);
                break;
            }
            int64_t copied_bytes = 0;
            result = p4_snapshot_copy_bytes(
                child_fd,
                child_destination,
                268435456 - state->bytes,
                &copied_bytes
            );
            struct stat after;
            if (result == 0 && fstat(child_fd, &after) < 0) result = -errno;
            if (result == 0 && (
                before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
                before.st_size != after.st_size || before.st_size != copied_bytes ||
                before.st_mtim.tv_sec != after.st_mtim.tv_sec ||
                before.st_mtim.tv_nsec != after.st_mtim.tv_nsec ||
                before.st_ctim.tv_sec != after.st_ctim.tv_sec ||
                before.st_ctim.tv_nsec != after.st_ctim.tv_nsec
            )) result = -ESTALE;
            p4_close_if_open(child_destination);
            if (result == 0) {
                state->files += 1;
                state->bytes += copied_bytes;
            }
        } else {
            result = -EINVAL;
        }
        p4_close_if_open(child_fd);
        if (result != 0) break;
        errno = 0;
    }
    if (result == 0 && errno != 0) result = -errno;
    closedir(directory);
    return result;
}

static int p4_open_directory_no_symlinks(const char *path) {
    if (path == NULL || path[0] == '\0') return -EINVAL;
#ifdef SYS_openat2
    const char *relative = path;
    const char *anchor_path = ".";
    if (path[0] == '/') {
        relative = path + 1;
        anchor_path = "/";
    }
    if (relative[0] == '\0') {
        int directory_fd = open(anchor_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        return directory_fd < 0 ? -errno : directory_fd;
    }
    int anchor_fd = open(anchor_path, O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (anchor_fd < 0) return -errno;
    struct open_how how = {
        .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS
    };
    int directory_fd = (int)syscall(
        SYS_openat2, anchor_fd, relative, &how, sizeof(how)
    );
    int error = directory_fd < 0 ? errno : 0;
    p4_close_if_open(anchor_fd);
    if (directory_fd < 0) return -error;
    return directory_fd;
#else
    return -ENOTSUP;
#endif
}
/* Registry management is supported only on Linux x86_64. These stable
 * files are never unlinked by normal publishers: flock is tied to an inode,
 * not to the current spelling of a path. No permission/grant is minted here. */
typedef struct {
    int directory_fd;
    int lock_fd;
    char *directory;
    struct stat directory_identity;
    struct stat lock_identity;
    struct stat pending_identity;
    int pending_owned;
} p4_registry_writer;

static int p4_registry_mkdir_open(const char *path) {
    if (path == NULL || path[0] == '\0' || strlen(path) >= PATH_MAX) return -EINVAL;
    char *copy = strdup(path);
    if (copy == NULL) return -ENOMEM;
    int current = open(path[0] == '/' ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (current < 0) { int error = -errno; free(copy); return error; }
    char *cursor = NULL;
    int count = 0;
    for (char *part = strtok_r(copy, "/", &cursor); part != NULL; part = strtok_r(NULL, "/", &cursor)) {
        if (strcmp(part, ".") == 0) continue;
        if (strcmp(part, "..") == 0 || ++count > 128) { p4_close_if_open(current); free(copy); return -EINVAL; }
        if (mkdirat(current, part, 0700) < 0 && errno != EEXIST) {
            int error = -errno; p4_close_if_open(current); free(copy); return error;
        }
        int next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) { int error = -errno; p4_close_if_open(current); free(copy); return error; }
        p4_close_if_open(current); current = next;
    }
    free(copy);
    return current;
}

static int p4_registry_same_inode(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino;
}

int32_t axyndra_registry_writer_validate(int64_t opaque) {
    if (opaque <= 0) return -EINVAL;
    p4_registry_writer *held = (p4_registry_writer *)(intptr_t)opaque;
    int directory = p4_open_directory_no_symlinks(held->directory);
    if (directory < 0) return directory;
    struct stat now_directory, now_lock, own_lock;
    int result = 0;
    if (fstat(directory, &now_directory) < 0 || fstat(held->lock_fd, &own_lock) < 0 ||
        fstatat(directory, ".registry-writer.lock", &now_lock, AT_SYMLINK_NOFOLLOW) < 0) result = -errno;
    else if (!p4_registry_same_inode(&now_directory, &held->directory_identity) ||
        !p4_registry_same_inode(&now_lock, &held->lock_identity) ||
        !p4_registry_same_inode(&own_lock, &held->lock_identity) ||
        !S_ISREG(now_lock.st_mode) || now_lock.st_nlink != 1 || own_lock.st_nlink != 1) result = -ESTALE;
    p4_close_if_open(directory);
    return result;
}

static int64_t p4_registry_lock_acquire(const char *directory, int mode) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)directory; (void)mode;
    return -ENOTSUP;
#else
    int dir = p4_registry_mkdir_open(directory);
    if (dir < 0) return dir;
    int fd = openat(dir, ".registry-writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600);
    if (fd < 0) { int error = -errno; p4_close_if_open(dir); return error; }
    struct stat directory_stat, lock_stat;
    int error = 0;
    if (fstat(dir, &directory_stat) < 0 || fstat(fd, &lock_stat) < 0) error = errno;
    else if (!S_ISREG(lock_stat.st_mode) || lock_stat.st_nlink != 1) error = EINVAL;
    else if (flock(fd, mode | LOCK_NB) < 0) error = errno;
    if (error != 0) { p4_close_if_open(fd); p4_close_if_open(dir); return -error; }
    p4_registry_writer *held = calloc(1, sizeof(*held));
    if (held == NULL) { p4_close_if_open(fd); p4_close_if_open(dir); return -ENOMEM; }
    held->directory_fd = dir; held->lock_fd = fd;
    held->directory = strdup(directory);
    held->directory_identity = directory_stat; held->lock_identity = lock_stat;
    if (held->directory == NULL) { p4_close_if_open(fd); p4_close_if_open(dir); free(held); return -ENOMEM; }
    int64_t result = (int64_t)(intptr_t)held;
    error = axyndra_registry_writer_validate(result);
    if (error < 0) { p4_close_if_open(fd); p4_close_if_open(dir); free(held->directory); free(held); return error; }
    return result;
#endif
}

int64_t axyndra_registry_writer_acquire(const char *directory) {
    return p4_registry_lock_acquire(directory, LOCK_EX);
}

int64_t axyndra_registry_reader_acquire(const char *directory) {
    return p4_registry_lock_acquire(directory, LOCK_SH);
}

int32_t axyndra_registry_writer_publication(int64_t opaque, _Bool begin) {
    int result = axyndra_registry_writer_validate(opaque);
    if (result != 0) return result;
    p4_registry_writer *held = (p4_registry_writer *)(intptr_t)opaque;
    const char *name = ".registry-publication.pending";
    if (begin) {
        if (held->pending_owned) return -EEXIST;
        int fd = openat(held->directory_fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) return -errno;
        static const char text[] = "workspace registry publication pending\n";
        ssize_t written;
        do { written = write(fd, text, sizeof(text) - 1); } while (written < 0 && errno == EINTR);
        if (written != sizeof(text) - 1) result = written < 0 ? -errno : -EIO;
        else if (fsync(fd) < 0 || fstat(fd, &held->pending_identity) < 0 || fsync(held->directory_fd) < 0) result = -errno;
        p4_close_if_open(fd);
        if (result == 0) held->pending_owned = 1;
        /* Any error deliberately leaves evidence. No destructive rename began. */
        return result;
    }
    if (!held->pending_owned) return -EINVAL;
    struct stat now;
    if (fstatat(held->directory_fd, name, &now, AT_SYMLINK_NOFOLLOW) < 0) return -errno;
    if (!S_ISREG(now.st_mode) || !p4_registry_same_inode(&now, &held->pending_identity)) return -ESTALE;
    if (unlinkat(held->directory_fd, name, 0) < 0) return -errno;
    held->pending_owned = 0;
    return fsync(held->directory_fd) < 0 ? -errno : 0;
}

void axyndra_registry_writer_release(int64_t opaque) {
    if (opaque <= 0) return;
    p4_registry_writer *held = (p4_registry_writer *)(intptr_t)opaque;
    /* close releases flock, including on abnormal process exit. Never unlink
     * either the persistent lock or an uncertain publication marker here. */
    p4_close_if_open(held->lock_fd); p4_close_if_open(held->directory_fd);
    free(held->directory); free(held);
}

/* These snapshots are inert metadata. The Cangjie owner prepays their full
 * allocation from the existing shared native payload pool before freeze().
 * Retaining the original fd prevents inode reuse from laundering an atomic
 * disable/re-enable ABA. Every check also compares all frozen bytes; a stat
 * timestamp alone never attests the installed state. No public path grants I/O. */
typedef struct {
    char *path;
    int fd;
    int absent;
    int frozen;
    int watch_fd, watch_descriptor, watch_stale;
    char watch_name[PATH_MAX];
    struct stat identity;
    uint8_t *bytes;
    int64_t size;
} p4_registry_snapshot;

static int p4_registry_metadata_open(const char *path) {
    if (path == NULL || path[0] != '/' || strlen(path) >= PATH_MAX) return -EINVAL;
    const char *leaf = strrchr(path, '/');
    if (leaf == NULL || leaf[1] == '\0' || strcmp(leaf + 1, ".") == 0 || strcmp(leaf + 1, "..") == 0) return -EINVAL;
    size_t size = (size_t)(leaf - path);
    char *parent = malloc(size + 1);
    if (parent == NULL) return -ENOMEM;
    memcpy(parent, path, size); parent[size] = '\0';
    int dir = p4_open_directory_no_symlinks(size == 0 ? "/" : parent);
    free(parent);
    if (dir < 0) return dir;
    int fd = openat(dir, leaf + 1, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    int result = fd < 0 ? -errno : fd;
    close(dir);
    if (result < 0) return result;
    struct stat st;
    if (fstat(fd, &st) < 0) { result = -errno; close(fd); return result; }
    if (!S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < 0 || st.st_size > 16777216) {
        close(fd); return -EINVAL;
    }
    return fd;
}

static int p4_registry_snapshot_identity(p4_registry_snapshot *held, int fd) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)held; (void)fd; return -ENOTSUP;
#else
    struct stat st;
    if (fstat(fd, &st) < 0) return -errno;
    if (!S_ISREG(st.st_mode) || st.st_nlink != 1 ||
        !p4_registry_same_inode(&st, &held->identity) || st.st_size != held->size ||
        st.st_mtim.tv_sec != held->identity.st_mtim.tv_sec || st.st_mtim.tv_nsec != held->identity.st_mtim.tv_nsec ||
        st.st_ctim.tv_sec != held->identity.st_ctim.tv_sec || st.st_ctim.tv_nsec != held->identity.st_ctim.tv_nsec) return -ESTALE;
    return 0;
#endif
}

/* Kernel watch queues are FD resources, like pipe buffers, subject to the
 * actual kernel limit. Every lost/overflow observation fails closed. The
 * original Cangjie metadata custody prepays this fixed userspace event buffer,
 * snapshot wrapper and all path occurrences before creating the watch. No
 * event array, JSON document, or pathname output is materialized here. */
static int p4_registry_snapshot_watch_drain(p4_registry_snapshot *held) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)held; return -ENOTSUP;
#else
    if (held->watch_stale || held->watch_fd < 0 || held->watch_descriptor < 0) return -ESTALE;
    uint8_t buffer[16384];
    /* A continuously busy unrelated ancestor cannot make an admission hang.
     * Incomplete observation is stale, never a successful partial proof. */
    for (size_t reads = 0; reads < 64; ++reads) {
        ssize_t count = read(held->watch_fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        if (count <= 0) { held->watch_stale = 1; return count < 0 ? -errno : -ESTALE; }
        size_t offset = 0;
        while (offset < (size_t)count) {
            struct inotify_event event;
            if ((size_t)count - offset < sizeof(event)) { held->watch_stale = 1; return -ESTALE; }
            memcpy(&event, buffer + offset, sizeof(event));
            if (event.len > (size_t)count - offset - sizeof(event)) { held->watch_stale = 1; return -ESTALE; }
            const char *name = (const char *)(buffer + offset + sizeof(event));
            if (event.mask & (IN_Q_OVERFLOW | IN_IGNORED | IN_UNMOUNT)) { held->watch_stale = 1; return -ESTALE; }
            if (event.wd != held->watch_descriptor) { held->watch_stale = 1; return -ESTALE; }
            if (!held->absent || (event.mask & (IN_DELETE_SELF | IN_MOVE_SELF))) {
                held->watch_stale = 1; return -ESTALE;
            }
            if (event.len > 0) {
                const char *end = memchr(name, '\0', event.len);
                if (end == NULL) { held->watch_stale = 1; return -ESTALE; }
                size_t length = (size_t)(end - name);
                if (strlen(held->watch_name) == length && memcmp(name, held->watch_name, length) == 0) {
                    held->watch_stale = 1; return -ESTALE;
                }
            }
            offset += sizeof(event) + event.len;
        }
    }
    held->watch_stale = 1; return -ESTALE;
#endif
}

static int p4_registry_snapshot_watch_arm(p4_registry_snapshot *held) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)held; return -ENOTSUP;
#else
    int target = held->fd, temporary = -1;
    if (held->absent) {
        /* Watch the real closest existing no-symlink ancestor. Only the next
         * missing component is relevant; unrelated lock/gate writes are not
         * a metadata mutation. Creating that component revokes this capture. */
        char parent[PATH_MAX];
        size_t extent = strlen(held->path);
        memcpy(parent, held->path, extent + 1);
        char *leaf = strrchr(parent, '/');
        if (leaf == NULL) return -EINVAL;
        memcpy(held->watch_name, leaf + 1, strlen(leaf + 1) + 1);
        *leaf = '\0';
        for (;;) {
            temporary = p4_open_directory_no_symlinks(parent[0] == '\0' ? "/" : parent);
            if (temporary >= 0) break;
            if (temporary != -ENOENT) return temporary;
            leaf = strrchr(parent, '/');
            if (leaf == NULL) return -EINVAL;
            memcpy(held->watch_name, leaf + 1, strlen(leaf + 1) + 1);
            *leaf = '\0';
        }
        target = temporary;
    }
    int notification = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (notification < 0) { int error = -errno; p4_close_if_open(temporary); return error; }
    char descriptor_path[96];
    int length = snprintf(descriptor_path, sizeof(descriptor_path), "/proc/self/fd/%d", target);
    int error = 0;
    if (length <= 0 || (size_t)length >= sizeof(descriptor_path)) error = -EINVAL;
    uint32_t mask = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_MOVE_SELF | IN_DELETE_SELF;
    if (held->absent) mask |= IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO | IN_ONLYDIR;
    int watched = error == 0 ? inotify_add_watch(notification, descriptor_path, mask) : -1;
    if (error == 0 && watched < 0) error = -errno;
    p4_close_if_open(temporary);
    if (error != 0) { p4_close_if_open(notification); return error; }
    held->watch_fd = notification; held->watch_descriptor = watched;
    return p4_registry_snapshot_watch_drain(held);
#endif
}

int64_t axyndra_registry_snapshot_open(const char *path) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)path; return -ENOTSUP;
#else
    int fd = p4_registry_metadata_open(path);
    if (fd < 0 && fd != -ENOENT) return fd;
    p4_registry_snapshot *held = calloc(1, sizeof(*held));
    if (held == NULL) { p4_close_if_open(fd); return -ENOMEM; }
    held->watch_fd = -1; held->watch_descriptor = -1;
    held->path = strdup(path); held->fd = fd; held->absent = fd == -ENOENT;
    if (held->path == NULL) { p4_close_if_open(fd); free(held); return -ENOMEM; }
    if (!held->absent && fstat(fd, &held->identity) < 0) {
        int error = -errno; close(fd); free(held->path); free(held); return error;
    }
    held->size = held->absent ? 0 : held->identity.st_size;
    int observed = p4_registry_snapshot_watch_arm(held);
    if (observed != 0) {
        p4_close_if_open(held->watch_fd); p4_close_if_open(held->fd);
        free(held->path); free(held); return observed;
    }
    return (int64_t)(intptr_t)held;
#endif
}

int64_t axyndra_registry_snapshot_size(int64_t opaque) {
    if (opaque <= 0) return -EINVAL;
    p4_registry_snapshot *held = (p4_registry_snapshot *)(intptr_t)opaque;
    return held->absent ? -1 : held->size;
}

int32_t axyndra_registry_snapshot_freeze(int64_t opaque) {
    if (opaque <= 0) return -EINVAL;
    p4_registry_snapshot *held = (p4_registry_snapshot *)(intptr_t)opaque;
    if (held->frozen) return -EINVAL;
    int observed = p4_registry_snapshot_watch_drain(held);
    if (observed != 0) return observed;
    if (held->absent) {
        observed = p4_registry_snapshot_watch_drain(held);
        if (observed == 0) held->frozen = 1;
        return observed;
    }
    int result = p4_registry_snapshot_identity(held, held->fd);
    if (result != 0) return result;
    held->bytes = malloc((size_t)(held->size > 0 ? held->size : 1));
    if (held->bytes == NULL) return -ENOMEM;
    int64_t offset = 0;
    while (offset < held->size) {
        ssize_t count = pread(held->fd, held->bytes + offset, (size_t)(held->size - offset), (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return count < 0 ? -errno : -ESTALE;
        offset += count;
    }
    result = p4_registry_snapshot_identity(held, held->fd);
    if (result == 0) result = p4_registry_snapshot_watch_drain(held);
    if (result == 0) held->frozen = 1;
    return result;
}

int32_t axyndra_registry_snapshot_copy(int64_t opaque, uint8_t *output, int64_t capacity) {
    if (opaque <= 0 || output == NULL) return -EINVAL;
    p4_registry_snapshot *held = (p4_registry_snapshot *)(intptr_t)opaque;
    if (!held->frozen || held->absent || capacity != held->size) return -EINVAL;
    if (capacity > 0) memcpy(output, held->bytes, (size_t)capacity);
    return 0;
}

int32_t axyndra_registry_snapshot_validate(int64_t opaque) {
    if (opaque <= 0) return -EINVAL;
    p4_registry_snapshot *held = (p4_registry_snapshot *)(intptr_t)opaque;
    if (!held->frozen) return -EINVAL;
    int observed = p4_registry_snapshot_watch_drain(held);
    if (observed != 0) return observed;
    int current = p4_registry_metadata_open(held->path);
    if (held->absent) {
        if (current == -ENOENT) return p4_registry_snapshot_watch_drain(held);
        p4_close_if_open(current); return current < 0 ? current : -ESTALE;
    }
    if (current < 0) return current;
    int result = p4_registry_snapshot_identity(held, current);
    if (result == 0) result = p4_registry_snapshot_identity(held, held->fd);
    uint8_t *buffer = result == 0 ? malloc(16384) : NULL;
    if (result == 0 && buffer == NULL) result = -ENOMEM;
    int64_t offset = 0;
    while (result == 0 && offset < held->size) {
        size_t amount = (size_t)(held->size - offset); if (amount > 16384) amount = 16384;
        ssize_t count = pread(current, buffer, amount, (off_t)offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { result = count < 0 ? -errno : -ESTALE; break; }
        if (memcmp(buffer, held->bytes + offset, (size_t)count) != 0) { result = -ESTALE; break; }
        offset += count;
    }
    if (result == 0) result = p4_registry_snapshot_identity(held, current);
    if (result == 0) result = p4_registry_snapshot_identity(held, held->fd);
    if (result == 0) result = p4_registry_snapshot_watch_drain(held);
    free(buffer); close(current); return result;
}

void axyndra_registry_snapshot_close(int64_t opaque) {
    if (opaque <= 0) return;
    p4_registry_snapshot *held = (p4_registry_snapshot *)(intptr_t)opaque;
    p4_close_if_open(held->watch_fd);
    p4_close_if_open(held->fd); free(held->path); free(held->bytes); free(held);
}

int32_t axyndra_workspace_open_parent(
    const char *workspace_root,
    const char *target
) {
    if (workspace_root == NULL || target == NULL) return -EINVAL;
#ifdef SYS_openat2
    size_t root_length = strlen(workspace_root);
    const char *relative = NULL;
    if (root_length == 1 && workspace_root[0] == '/') {
        if (target[0] != '/' || target[1] == '\0') return -EXDEV;
        relative = target + 1;
    } else {
        if (root_length == 0 || strncmp(workspace_root, target, root_length) != 0 ||
            target[root_length] != '/' || target[root_length + 1] == '\0') {
            return -EXDEV;
        }
        relative = target + root_length + 1;
    }
    const char *separator = strrchr(relative, '/');
    if (separator != NULL && separator[1] == '\0') return -EINVAL;

    int root_fd = p4_open_directory_no_symlinks(workspace_root);
    if (root_fd < 0) return root_fd;
    if (separator == NULL) {
        int parent_fd = fcntl(root_fd, F_DUPFD_CLOEXEC, 0);
        int error = parent_fd < 0 ? errno : 0;
        p4_close_if_open(root_fd);
        return parent_fd < 0 ? -error : parent_fd;
    }

    size_t parent_length = (size_t)(separator - relative);
    if (parent_length == 0) {
        int parent_fd = fcntl(root_fd, F_DUPFD_CLOEXEC, 0);
        int error = parent_fd < 0 ? errno : 0;
        p4_close_if_open(root_fd);
        return parent_fd < 0 ? -error : parent_fd;
    }
    char *parent = malloc(parent_length + 1);
    if (parent == NULL) {
        p4_close_if_open(root_fd);
        return -ENOMEM;
    }
    memcpy(parent, relative, parent_length);
    parent[parent_length] = '\0';
    struct open_how how = {
        .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS
    };
    int parent_fd = (int)syscall(
        SYS_openat2, root_fd, parent, &how, sizeof(how)
    );
    int error = parent_fd < 0 ? errno : 0;
    free(parent);
    p4_close_if_open(root_fd);
    return parent_fd < 0 ? -error : parent_fd;
#else
    (void)workspace_root;
    (void)target;
    return -ENOTSUP;
#endif
}

int32_t axyndra_workspace_close_parent(int32_t parent_fd) {
    if (parent_fd < 0) return -EINVAL;
    return close(parent_fd) < 0 ? -errno : 0;
}
int32_t axyndra_plugin_snapshot_copy(
    const char *source,
    const char *destination
) {
    if (source == NULL || destination == NULL) return -EINVAL;
    int source_fd = p4_open_directory_no_symlinks(source);
    if (source_fd < 0) return source_fd;
    int destination_fd = p4_open_directory_no_symlinks(destination);
    if (destination_fd < 0) {
        p4_close_if_open(source_fd);
        return destination_fd;
    }
    int source_contains_destination = p4_fd_is_ancestor(source_fd, destination_fd);
    int destination_contains_source = p4_fd_is_ancestor(destination_fd, source_fd);
    if (source_contains_destination < 0 || destination_contains_source < 0) {
        int error = source_contains_destination < 0
            ? source_contains_destination
            : destination_contains_source;
        p4_close_if_open(destination_fd);
        p4_close_if_open(source_fd);
        return error;
    }
    if (source_contains_destination == 1 || destination_contains_source == 1) {
        p4_close_if_open(destination_fd);
        p4_close_if_open(source_fd);
        return -EXDEV;
    }
    p4_snapshot_copy_state state = {0, 0};
    int result = p4_snapshot_copy_directory(source_fd, destination_fd, 0, &state);
    p4_close_if_open(destination_fd);
    p4_close_if_open(source_fd);
    return result;
}


static int p4_workspace_same_content(int left_fd, int right_fd) {
    char left[8192];
    char right[8192];
    if (lseek(left_fd, 0, SEEK_SET) < 0) return -errno;
    if (lseek(right_fd, 0, SEEK_SET) < 0) return -errno;
    for (;;) {
        ssize_t left_size;
        do { left_size = read(left_fd, left, sizeof(left)); }
        while (left_size < 0 && errno == EINTR);
        if (left_size < 0) return -errno;
        ssize_t right_size;
        do { right_size = read(right_fd, right, sizeof(right)); }
        while (right_size < 0 && errno == EINTR);
        if (right_size < 0) return -errno;
        if (left_size != right_size) return 0;
        if (left_size == 0) return 1;
        if (memcmp(left, right, (size_t)left_size) != 0) return 0;
    }
}

static int p4_workspace_exchange(
    const char *left,
    const char *right
) {
#ifdef SYS_renameat2
#ifndef RENAME_EXCHANGE
#define RENAME_EXCHANGE (1U << 1)
#endif
    if (syscall(
        SYS_renameat2,
        AT_FDCWD,
        left,
        AT_FDCWD,
        right,
        RENAME_EXCHANGE
    ) < 0) return -errno;
    return 0;
#else
    (void)left;
    (void)right;
    return -ENOTSUP;
#endif
}

/*
 * Return 0 for a verified exchange, 1 for a pre-publication conflict, and 2
 * when an exchange occurred but its identities or bytes cannot be verified.
 * Never roll back by pathname: another editor can replace either name between
 * an identity check and an exchange. On 2 the caller must retain source, which
 * may contain that editor's displaced file, and report an unknown effect.
 */
int32_t axyndra_workspace_replace_if_matches(
    const char *source,
    const char *destination,
    const char *expected
) {
    if (source == NULL || destination == NULL || expected == NULL) return -EINVAL;
    int destination_fd = open(destination, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (destination_fd < 0) {
        int error = errno;
        if (error == ENOENT || error == ENOTDIR || error == ELOOP ||
            error == EACCES || error == EPERM) return 1;
        return -error;
    }
    int expected_fd = open(expected, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (expected_fd < 0) {
        int error = errno;
        p4_close_if_open(destination_fd);
        return -error;
    }
    int source_fd = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (source_fd < 0) {
        int error = errno;
        p4_close_if_open(expected_fd);
        p4_close_if_open(destination_fd);
        return -error;
    }

    struct stat destination_before;
    struct stat source_before;
    int result = 0;
    if (fstat(destination_fd, &destination_before) < 0 ||
        fstat(source_fd, &source_before) < 0) {
        result = -errno;
        goto done;
    }
    if (!S_ISREG(destination_before.st_mode) || !S_ISREG(source_before.st_mode)) {
        result = -EINVAL;
        goto done;
    }
    result = p4_workspace_same_content(destination_fd, expected_fd);
    if (result <= 0) {
        if (result == 0) result = 1;
        goto done;
    }
    result = p4_workspace_exchange(source, destination);
    if (result != 0) goto done;

    struct stat swapped_previous;
    struct stat published;
    int content_matches = p4_workspace_same_content(destination_fd, expected_fd);
    int snapshot_matches =
        stat(source, &swapped_previous) == 0 &&
        stat(destination, &published) == 0 &&
        p4_workspace_same_identity(&destination_before, &swapped_previous) &&
        p4_workspace_same_identity(&source_before, &published);
    if (content_matches == 1 && snapshot_matches) {
        result = 0;
        goto done;
    }

    result = 2;

done:
    p4_close_if_open(source_fd);
    p4_close_if_open(expected_fd);
    p4_close_if_open(destination_fd);
    return (int32_t)result;
}

int32_t process4cj_random_bytes(uint8_t *buffer, int64_t length) {
    if (length < 0 || (length > 0 && buffer == NULL)) return -EINVAL;
    if (length == 0) return 0;
    int64_t offset = 0;
    while (offset < length) {
        size_t remaining = (size_t)(length - offset);
        size_t chunk = remaining > 256 ? 256 : remaining;
        ssize_t count;
        do {
            count = getrandom(buffer + offset, chunk, 0);
        } while (count < 0 && errno == EINTR);
        if (count < 0) return -errno;
        if (count == 0) return -EIO;
        offset += (int64_t)count;
    }
    return 0;
}


/* Generic read-view resource identity/copy. No search, hashline or editor
 * semantics. Never follow a link, open a device, or preserve executable bits.
 * A frozen identity is descriptive until the actual canonical host executor
 * has checked its source, exact ParentIntent and current capability ceiling. */
static int p4_read_view_open(const char *path) {
    if (path == NULL || path[0] != '/' || path[1] == '\0') return -EINVAL;
#ifdef SYS_openat2
    int root = open("/", O_PATH | O_DIRECTORY | O_CLOEXEC);
    if (root < 0) return -errno;
    struct open_how how = {
        .flags = O_PATH | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS
    };
    int fd = (int)syscall(SYS_openat2, root, path + 1, &how, sizeof(how));
    int error = fd < 0 ? errno : 0;
    close(root);
    return fd < 0 ? -error : fd;
#else
    return -ENOTSUP;
#endif
}

static int p4_read_view_witness(const struct stat *st, char *buffer, int64_t capacity) {
    if (buffer == NULL || capacity < 256) return -EINVAL;
    if (S_ISDIR(st->st_mode)) {
        snprintf(buffer, (size_t)capacity, "d:%llu:%llu:%u",
            (unsigned long long)st->st_dev, (unsigned long long)st->st_ino,
            (unsigned)(st->st_mode & 07777));
    } else if (S_ISREG(st->st_mode) && st->st_nlink == 1) {
        snprintf(buffer, (size_t)capacity, "f:%llu:%llu:%u:%lld:%lld:%ld:%lld:%ld",
            (unsigned long long)st->st_dev, (unsigned long long)st->st_ino,
            (unsigned)(st->st_mode & 07777), (long long)st->st_size,
            (long long)st->st_mtim.tv_sec, st->st_mtim.tv_nsec,
            (long long)st->st_ctim.tv_sec, st->st_ctim.tv_nsec);
    } else return -EPERM; /* includes hard links and non-regular resources */
    return 0;
}

/* Open content only through a verified O_PATH identity. The original path
 * may be renamed or replaced with a device while authorization is pending;
 * no content open of that replacement is permitted. The host-owned fd remains
 * alive until the reopen and second identity comparison are complete. */
static int p4_read_view_content(const char *path, const char *expected, int directory) {
    int held = p4_read_view_open(path);
    if (held < 0) return held;
    struct stat before, after;
    char identity[256], owned_path[64];
    int result = fstat(held, &before) == 0
        ? p4_read_view_witness(&before, identity, sizeof(identity)) : -errno;
    if (result == 0 && ((directory ? !S_ISDIR(before.st_mode) : !S_ISREG(before.st_mode)) ||
        strcmp(identity, expected) != 0)) result = -ESTALE;
    if (result != 0) { close(held); return result; }
    snprintf(owned_path, sizeof(owned_path), "/proc/self/fd/%d", held);
    int content = open(owned_path, O_RDONLY | O_NONBLOCK | O_CLOEXEC |
        (directory ? O_DIRECTORY : 0));
    result = content < 0 ? -errno : 0;
    if (result == 0) result = fstat(content, &after) == 0
        ? p4_read_view_witness(&after, identity, sizeof(identity)) : -errno;
    if (result == 0 && (before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
        strcmp(identity, expected) != 0)) result = -ESTALE;
    close(held);
    if (result != 0) { if (content >= 0) close(content); return result; }
    return content;
}

int32_t axyndra_read_view_probe(const char *path, char *identity, int64_t capacity) {
    int fd = p4_read_view_open(path);
    if (fd < 0) return fd;
    struct stat st;
    int result = fstat(fd, &st) == 0 ? p4_read_view_witness(&st, identity, capacity) : -errno;
    close(fd);
    return result;
}

/* Document transport owns this actual fd until close acknowledgement. The
 * pathname is used once, through the same no-follow held-identity reopen as
 * read views. Every subsequent read validates this fd before and after read;
 * callers must validate the complete source digest before the first consume. */
static int p4_document_input_identity(int fd, const char *expected) {
    if (fd < 0 || expected == NULL) return -EINVAL;
    struct stat st;
    char identity[256];
    int result = fstat(fd, &st) == 0 ? p4_read_view_witness(&st, identity, sizeof(identity)) : -errno;
    if (result == 0 && (!S_ISREG(st.st_mode) || strcmp(identity, expected) != 0)) result = -ESTALE;
    return result;
}

int32_t axyndra_document_input_open(const char *source, const char *expected, int64_t bytes) {
    /* Existing artifact observations are at most16MiB; document descriptors
     * still independently cap at8MiB. This fd primitive grants no read rights. */
    if (expected == NULL || bytes < 0 || bytes > 16777216) return -EINVAL;
    int fd = p4_read_view_content(source, expected, 0);
    if (fd < 0) return fd;
    struct stat st;
    int result = fstat(fd, &st) == 0 ? 0 : -errno;
    if (result == 0 && st.st_size != bytes) result = -ESTALE;
    if (result != 0) { close(fd); return result; }
    return fd;
}

/* Content-only verification of an already completed Host journal stream.
 * The legacy document-open 16MiB limit stays unchanged. No body allocation,
 * path traversal, read grant or execution authority is added here. The held
 * inode, full witness and exact completed size remain mandatory; all reads
 * use the existing 64KiB identity-checked fd primitive. */
int32_t axyndra_journal_stream_input_open(const char *source, const char *expected, int64_t bytes) {
    if (expected == NULL || bytes < 0) return -EINVAL;
    int fd = p4_read_view_content(source, expected, 0);
    if (fd < 0) return fd;
    struct stat st;
    int result = fstat(fd, &st) == 0 ? 0 : -errno;
    if (result == 0 && st.st_size != bytes) result = -ESTALE;
    if (result != 0) { close(fd); return result; }
    return fd;
}

int64_t axyndra_document_input_read(int32_t fd, const char *expected, uint8_t *buffer, int64_t capacity) {
    if (buffer == NULL || capacity < 1 || capacity > 65536) return -EINVAL;
    int result = p4_document_input_identity(fd, expected);
    if (result != 0) return result;
    ssize_t count;
    do { count = read(fd, buffer, (size_t)capacity); } while (count < 0 && errno == EINTR);
    if (count < 0) return -errno;
    result = p4_document_input_identity(fd, expected);
    return result == 0 ? count : result;
}

int32_t axyndra_document_input_rewind(int32_t fd, const char *expected) {
    int result = p4_document_input_identity(fd, expected);
    if (result != 0) return result;
    if (lseek(fd, 0, SEEK_SET) != 0) return -errno;
    return p4_document_input_identity(fd, expected);
}

int32_t axyndra_document_input_close(int32_t fd) {
    if (fd < 0) return -EINVAL;
    /* Linux releases a valid descriptor on close, including EINTR and delayed
     * I/O errors. Never retry that number: another thread may already reuse it.
     * EBADF also acknowledges that no descriptor remains at that number. */
    (void)close(fd);
    return 0;
}

/* Generic line-framed header, selected by frozen host parameters. One-byte
 * reads intentionally never touch the body beyond the closing line. Invalid
 * framing is an observed empty header, not absence of the underlying file. */
static int p4_read_view_header_bytes(int src, int dst, int64_t maximum,
    const char *start_marker, const char *end_marker, int trim_ascii, int64_t *copied) {
    size_t start_size = strlen(start_marker), end_size = strlen(end_marker);
    if (maximum < 1 || maximum > 65536 || start_size < 1 || start_size > 64 ||
        end_size < 1 || end_size > 64 || (trim_ascii != 0 && trim_ascii != 1)) return -EINVAL;
    for (size_t i = 0; i < start_size; ++i) {
        if ((unsigned char)start_marker[i] < 33 || (unsigned char)start_marker[i] > 126) return -EINVAL;
    }
    for (size_t i = 0; i < end_size; ++i) {
        if ((unsigned char)end_marker[i] < 33 || (unsigned char)end_marker[i] > 126) return -EINVAL;
    }
    char *bytes = malloc((size_t)maximum);
    if (bytes == NULL) return -ENOMEM;
    int64_t used = 0, line = 0;
    int opened = 0, complete = 0, result = 0;
    *copied = 0;
    while (used < maximum) {
        ssize_t count;
        do { count = read(src, bytes + used, 1); } while (count < 0 && errno == EINTR);
        if (count < 0) { result = -errno; break; }
        if (count == 0) break;
        used++;
        if (bytes[used - 1] != '\n') continue;
        int64_t first = line, end = used - 1;
        if (trim_ascii) {
            while (first < end && (bytes[first] == ' ' || (bytes[first] >= '\t' && bytes[first] <= '\r'))) first++;
            while (end > first && (bytes[end - 1] == ' ' || (bytes[end - 1] >= '\t' && bytes[end - 1] <= '\r'))) end--;
        }
        const char *marker = opened ? end_marker : start_marker;
        size_t marker_size = opened ? end_size : start_size;
        int matches = (uint64_t)(end - first) == marker_size && memcmp(bytes + first, marker, marker_size) == 0;
        if (!opened) { if (!matches) break; opened = 1; }
        else if (matches) { complete = 1; break; }
        line = used;
    }
    if (result == 0 && complete) {
        int64_t offset = 0;
        while (offset < used) {
            ssize_t count;
            do { count = write(dst, bytes + offset, (size_t)(used - offset)); } while (count < 0 && errno == EINTR);
            if (count <= 0) { result = count < 0 ? -errno : -EIO; break; }
            offset += count;
        }
        if (result == 0) *copied = used;
    }
    free(bytes);
    return result;
}

static int64_t p4_read_view_copy(const char *source, const char *expected,
    const char *destination, int64_t maximum, const char *start_marker, const char *end_marker, int trim_ascii) {
    if (expected == NULL || destination == NULL || maximum < 0 || maximum > 16777216) return -EINVAL;
    int src = p4_read_view_content(source, expected, 0);
    if (src < 0) return src;
    struct stat before, after;
    char identity[256];
    int result = fstat(src, &before) == 0 ? p4_read_view_witness(&before, identity, sizeof(identity)) : -errno;
    if (result == 0 && (!S_ISREG(before.st_mode) || strcmp(identity, expected) != 0 ||
        (start_marker == NULL && before.st_size > maximum))) result = -ESTALE;
    int dst = -1;
    if (result == 0) {
        /* Host owns a fresh private directory; still refuse links at every
         * ancestor and at the destination. Never overwrite an existing entry. */
        const char *leaf = strrchr(destination, '/');
        if (leaf == NULL || leaf[1] == '\0') result = -EINVAL;
        else {
            size_t length = (size_t)(leaf - destination);
            char *parent = malloc(length + 1);
            if (parent == NULL) result = -ENOMEM;
            else {
                memcpy(parent, destination, length); parent[length] = '\0';
                int dir = p4_open_directory_no_symlinks(parent); free(parent);
                if (dir < 0) result = dir;
                else {
                    dst = openat(dir, leaf + 1, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
                    if (dst < 0) result = -errno;
                    close(dir);
                }
            }
        }
    }
    int64_t copied = 0;
    if (result == 0) result = start_marker == NULL ? p4_snapshot_copy_bytes(src, dst, maximum, &copied) :
        p4_read_view_header_bytes(src, dst, maximum, start_marker, end_marker, trim_ascii, &copied);
    if (result == 0) {
        result = fstat(src, &after) == 0 ? p4_read_view_witness(&after, identity, sizeof(identity)) : -errno;
        if (result == 0 && (strcmp(identity, expected) != 0 || (start_marker == NULL && copied != before.st_size))) result = -ESTALE;
    }
    p4_close_if_open(dst); close(src);
    if (result != 0) { if (dst >= 0) unlink(destination); return result; }
    return copied;
}

int64_t axyndra_read_view_copy(const char *source, const char *expected,
    const char *destination, int64_t maximum) {
    return p4_read_view_copy(source, expected, destination, maximum, NULL, NULL, 0);
}

/* Compare complete bounded bytes through the same verified content fd.
 * Exact byte equality is stronger than a digest comparison. No metadata-only
 * witness substitutes for the originally frozen configuration bytes. */
int32_t axyndra_read_view_equal(const char *source, const char *expected,
    const uint8_t *frozen, int64_t length) {
    if (expected == NULL || frozen == NULL || length < 1 || length > 65536) return -EINVAL;
    int src = p4_read_view_content(source, expected, 0);
    if (src < 0) return src;
    struct stat st;
    char identity[256];
    /* Fixed private control scratch; do not put 16 KiB on the calling
     * Cangjie thread stack. No pointer is retained after this call. */
    uint8_t *buffer = NULL;
    int result = fstat(src, &st) == 0 ? p4_read_view_witness(&st, identity, sizeof(identity)) : -errno;
    if (result == 0 && (st.st_size != length || strcmp(identity, expected) != 0)) result = -ESTALE;
    if (result == 0) {
        buffer = malloc(16384);
        if (buffer == NULL) result = -ENOMEM;
    }
    int64_t offset = 0;
    while (result == 0 && offset < length) {
        size_t amount = (size_t)(length - offset);
        if (amount > 16384) amount = 16384;
        ssize_t count;
        do { count = read(src, buffer, amount); } while (count < 0 && errno == EINTR);
        if (count <= 0) { result = count < 0 ? -errno : -ESTALE; break; }
        if (memcmp(buffer, frozen + offset, (size_t)count) != 0) { result = -ESTALE; break; }
        offset += count;
    }
    if (result == 0) {
        result = fstat(src, &st) == 0 ? p4_read_view_witness(&st, identity, sizeof(identity)) : -errno;
        if (result == 0 && (offset != length || strcmp(identity, expected) != 0)) result = -ESTALE;
    }
    close(src);
    free(buffer);
    return result;
}

int64_t axyndra_read_view_header(const char *source, const char *expected,
    const char *destination, int64_t maximum, const char *start_marker, const char *end_marker, int trim_ascii) {
    if (start_marker == NULL || end_marker == NULL || maximum < 1 || maximum > 65536) return -EINVAL;
    return p4_read_view_copy(source, expected, destination, maximum, start_marker, end_marker, trim_ascii);
}

/* Return names from the same verified directory handle. A concurrent path
 * replacement cannot redirect enumeration into another directory. */
int64_t axyndra_read_view_directory(const char *path, const char *expected,
    uint8_t *output, int64_t capacity) {
    if (expected == NULL || output == NULL || capacity < 1 || capacity > 1048576) return -EINVAL;
    int fd = p4_read_view_content(path, expected, 1);
    if (fd < 0) return fd;
    struct stat st;
    char identity[256];
    int result = fstat(fd, &st) == 0 ? p4_read_view_witness(&st, identity, sizeof(identity)) : -errno;
    if (result == 0 && (!S_ISDIR(st.st_mode) || strcmp(identity, expected) != 0)) result = -ESTALE;
    if (result != 0) { close(fd); return result; }
    DIR *directory = fdopendir(fd);
    if (directory == NULL) { result = -errno; close(fd); return result; }
    int64_t used = 0, count = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (entry == NULL) { if (errno != 0) result = -errno; break; }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        size_t size = strlen(entry->d_name) + 1;
        if (++count > 1024 || size > (size_t)(capacity - used)) { result = -E2BIG; break; }
        memcpy(output + used, entry->d_name, size); used += (int64_t)size;
    }
    if (result == 0) {
        result = fstat(dirfd(directory), &st) == 0 ? p4_read_view_witness(&st, identity, sizeof(identity)) : -errno;
        if (result == 0 && strcmp(identity, expected) != 0) result = -ESTALE;
    }
    closedir(directory);
    return result == 0 ? used : result;
}

/* Included by process4cj_native.c after its existing process-tree helpers.
 * Namespace resources are kernel-held descriptors from the actual owned
 * sandbox payload; no plugin path, numeric PID or FD is accepted by Host IPC.
 * This library primitive supplies no canonical Run/Source/approval authority.
 */
#define P4_NAMESPACE_TARGETS 256
static const char *p4_namespace_names[3] = {"user", "net", "pid"};

static int p4_namespace_target_live(pid_t pid, uint64_t expected) {
    uint64_t actual = 0;
    char state = '\0';
    return expected > 0 && p4_read_process_stat(pid, NULL, &actual, &state) &&
        actual == expected && state != 'Z' && state != 'X' && state != 'x';
}

static int p4_namespace_open(pid_t pid, const char *name) {
    char path[96];
    int length = snprintf(path, sizeof(path), "/proc/%ld/ns/%s", (long)pid, name);
    if (length <= 0 || (size_t)length >= sizeof(path)) { errno = EINVAL; return -1; }
    return open(path, O_RDONLY | O_CLOEXEC);
}

static int p4_namespace_last_pid(pid_t pid, pid_t *result) {
    char path[96], buffer[16384];
    int length = snprintf(path, sizeof(path), "/proc/%ld/status", (long)pid);
    if (length <= 0 || (size_t)length >= sizeof(path)) return EINVAL;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return errno;
    ssize_t count;
    do { count = read(fd, buffer, sizeof(buffer) - 1); } while (count < 0 && errno == EINTR);
    int error = count < 0 ? errno : 0;
    p4_close_if_open(fd);
    if (error != 0) return error;
    if (count <= 0 || (size_t)count >= sizeof(buffer) - 1) return EOVERFLOW;
    buffer[count] = '\0';
    char *line = buffer;
    for (;;) {
        if (strncmp(line, "NSpid:", 6) == 0) {
            char *value = line + 6;
            pid_t last = 0;
            int parsed_count = 0;
            while (*value == ' ' || *value == '\t') value++;
            while (*value != '\0' && *value != '\n') {
                errno = 0;
                char *end = NULL;
                long parsed = strtol(value, &end, 10);
                if (errno != 0 || end == value || parsed <= 0 || parsed > INT_MAX ||
                    (pid_t)parsed != parsed || ++parsed_count > 32) return EPROTO;
                last = (pid_t)parsed;
                value = end;
                if (*value != '\0' && *value != '\n' && *value != ' ' && *value != '\t') return EPROTO;
                while (*value == ' ' || *value == '\t') value++;
            }
            if (parsed_count < 2 || last <= 0) return ENOTSUP;
            *result = last;
            return 0;
        }
        line = strchr(line, '\n');
        if (line == NULL || line[1] == '\0') return ENOTSUP;
        line++;
    }
}

static int p4_namespace_same_fd(int first, int second) {
    struct stat a, b;
    return first >= 0 && second >= 0 && fstat(first, &a) == 0 && fstat(second, &b) == 0 &&
        a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

static void p4_namespace_close_fds(const p4_owned_namespaces *value) {
    if (value == NULL) return;
    for (size_t index = 0; index < 4; ++index) p4_close_if_open(value->fds[index]);
}

static void p4_namespace_free(p4_owned_namespaces *value) {
    if (value == NULL) return;
    p4_namespace_close_fds(value);
    free(value);
}

static int p4_namespace_validate(const p4_owned_namespaces *value) {
    if (value == NULL || !p4_namespace_target_live(value->root_pid, value->root_start) ||
        !p4_namespace_target_live(value->payload_pid, value->payload_start)) return ESRCH;
    for (size_t index = 0; index < 3; ++index) {
        int current = p4_namespace_open(value->payload_pid, p4_namespace_names[index]);
        if (current < 0) return errno;
        int matched = p4_namespace_same_fd(current, value->fds[index]);
        p4_close_if_open(current);
        if (!matched) return ESTALE;
    }
    /* The fourth descriptor is the actual owner returned for the already
     * held PID namespace, not a PID/path/configuration assertion. */
    int owner = ioctl(value->fds[2], NS_GET_USERNS);
    if (owner < 0) return errno;
    int owner_matched = p4_namespace_same_fd(owner, value->fds[3]);
    p4_close_if_open(owner);
    if (!owner_matched) return ESTALE;
    if (!p4_namespace_target_live(value->root_pid, value->root_start) ||
        !p4_namespace_target_live(value->payload_pid, value->payload_start)) return ESRCH;
    return 0;
}

/* Only async-signal-safe descriptor/syscall work runs after fork. The exact
 * lease descriptors were duplicated and its identities validated before fork.
 * setns(pid) affects the subsequent bubblewrap clone, not this supervisor.
 * A join failure is a spawn failure; there is no host/shared fallback.
 */
static int p4_namespace_enter(const p4_owned_namespaces *value) {
    if (value == NULL) return 0;
    /* bubblewrap --disable-userns leaves the payload in a descendant user
     * namespace after creating net/PID namespaces. Enter their actual owning
     * user first; entering the inner payload user first loses authority over
     * those ancestor-owned namespaces. No failed join falls back to Host. */
    int error = 0, same_net = 0, same_owner = 0, same_payload = 0;
    int current_net = open("/proc/self/ns/net", O_RDONLY | O_CLOEXEC);
    if (current_net < 0) { error = errno; goto done; }
    struct stat current_info, held_info;
    if (fstat(current_net, &current_info) < 0) error = errno;
    if (error == 0 && fstat(value->fds[1], &held_info) < 0) error = errno;
    p4_close_if_open(current_net);
    if (error != 0) goto done;
    same_net = current_info.st_dev == held_info.st_dev &&
        current_info.st_ino == held_info.st_ino;
    int current_user = open("/proc/self/ns/user", O_RDONLY | O_CLOEXEC);
    if (current_user < 0) { error = errno; goto done; }
    if (fstat(current_user, &current_info) < 0) error = errno;
    if (error == 0 && fstat(value->fds[3], &held_info) < 0) error = errno;
    p4_close_if_open(current_user);
    if (error != 0) goto done;
    same_owner = current_info.st_dev == held_info.st_dev &&
        current_info.st_ino == held_info.st_ino;
    struct stat payload_info;
    if (fstat(value->fds[0], &payload_info) < 0) { error = errno; goto done; }
    same_payload = payload_info.st_dev == held_info.st_dev &&
        payload_info.st_ino == held_info.st_ino;
    /* Only real held/current FD equality skips a redundant join. Joining the
     * current user namespace is prohibited by the kernel. The same-host-net
     * case keeps its original exact-identity skip, never a policy fallback. */
    if (!same_owner && syscall(SYS_setns, value->fds[3], CLONE_NEWUSER) < 0) { error = errno; goto done; }
    if (!same_net && syscall(SYS_setns, value->fds[1], CLONE_NEWNET) < 0) { error = errno; goto done; }
    if (syscall(SYS_setns, value->fds[2], CLONE_NEWPID) < 0) { error = errno; goto done; }
    if (!value->defer_payload_user && !same_payload &&
        syscall(SYS_setns, value->fds[0], CLONE_NEWUSER) < 0) { error = errno; goto done; }
    if (value->defer_payload_user && fcntl(value->fds[0], F_SETFD, 0) < 0) {
        error = errno; goto done;
    }
done:
    if (error == 0 && value->defer_payload_user) {
        /* bwrap enters this held descendant user namespace before its clone.
         * Every other duplicate is closed here. The exact payload FD is the
         * sole namespace descriptor passed to that trusted setup executable. */
        for (size_t index = 1; index < 4; ++index) p4_close_if_open(value->fds[index]);
    } else p4_namespace_close_fds(value);
    return error;
}

static int p4_namespace_clone(const p4_owned_namespaces *value, p4_owned_namespaces **result) {
    int error = p4_namespace_validate(value);
    if (error != 0) return error;
    p4_owned_namespaces *copy = malloc(sizeof(*copy));
    if (copy == NULL) return ENOMEM;
    *copy = *value;
    copy->defer_payload_user = 0;
    for (size_t index = 0; index < 4; ++index) copy->fds[index] = -1;
    for (size_t index = 0; index < 4; ++index) {
        copy->fds[index] = fcntl(value->fds[index], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
        if (copy->fds[index] < 0) { error = errno; p4_namespace_free(copy); return error; }
    }
    error = p4_namespace_validate(copy);
    if (error != 0) { p4_namespace_free(copy); return error; }
    *result = copy;
    return 0;
}

int32_t process4cj_namespace_capture(int64_t root_pid, int64_t root_start, int64_t *handle) {
    if (root_pid <= 0 || root_pid > INT_MAX || root_start <= 0 || handle == NULL) return EINVAL;
    *handle = 0;
    p4_process_target root = {(pid_t)root_pid, (uint64_t)root_start, 1};
    if (!p4_namespace_target_live(root.pid, root.start_time)) return ESRCH;
    p4_process_target *targets = calloc(P4_NAMESPACE_TARGETS, sizeof(*targets));
    if (targets == NULL) return ENOMEM;
    size_t count = 0;
    int overflow = 0;
    p4_collect_descendants(root.pid, &root, targets, P4_NAMESPACE_TARGETS, &count, &overflow, 0);
    if (overflow) { free(targets); return EOVERFLOW; }
    int root_namespace = p4_namespace_open(root.pid, "pid");
    if (root_namespace < 0) { int error = errno; free(targets); return error; }
    p4_process_target selected = {0, 0, 0};
    int error = 0;
    for (size_t index = 0; index < count; ++index) {
        pid_t inner = 0;
        if (!p4_namespace_target_live(targets[index].pid, targets[index].start_time) ||
            p4_namespace_last_pid(targets[index].pid, &inner) != 0 || inner != 2) continue;
        int payload_namespace = p4_namespace_open(targets[index].pid, "pid");
        if (payload_namespace < 0) continue;
        int distinct = !p4_namespace_same_fd(payload_namespace, root_namespace);
        p4_close_if_open(payload_namespace);
        if (!distinct) continue;
        if (selected.valid) { error = EEXIST; break; }
        selected = targets[index];
    }
    p4_close_if_open(root_namespace);
    free(targets);
    if (error != 0) return error;
    if (!selected.valid) return EAGAIN;
    p4_owned_namespaces *value = calloc(1, sizeof(*value));
    if (value == NULL) return ENOMEM;
    value->root_pid = root.pid; value->root_start = root.start_time;
    value->payload_pid = selected.pid; value->payload_start = selected.start_time;
    for (size_t index = 0; index < 4; ++index) value->fds[index] = -1;
    for (size_t index = 0; index < 3; ++index) {
        value->fds[index] = p4_namespace_open(selected.pid, p4_namespace_names[index]);
        if (value->fds[index] < 0) { error = errno; p4_namespace_free(value); return error; }
    }
    value->fds[3] = ioctl(value->fds[2], NS_GET_USERNS);
    if (value->fds[3] < 0) { error = errno; p4_namespace_free(value); return error; }
    error = p4_namespace_validate(value);
    if (error != 0) { p4_namespace_free(value); return error; }
    *handle = (int64_t)(uintptr_t)value;
    return 0;
}

int32_t process4cj_namespace_validate(int64_t handle) {
    if (handle <= 0) return EINVAL;
    return p4_namespace_validate((const p4_owned_namespaces *)(uintptr_t)handle);
}

void process4cj_namespace_close(int64_t handle) {
    if (handle > 0) p4_namespace_free((p4_owned_namespaces *)(uintptr_t)handle);
}

/* Linux closes the descriptor even when close reports EINTR/EIO. Do not
 * retry its numeric FD: it may already have been reused. Record each attempted
 * descriptor as consumed, retain the exact heap handle on any first error,
 * and acknowledge a later checked retry only after no descriptor remains.
 * No liveness, namespace-current or launch-Source check blocks cleanup. */
int32_t process4cj_namespace_close_checked(int64_t handle) {
    if (handle <= 0) return EINVAL;
    p4_owned_namespaces *value = (p4_owned_namespaces *)(uintptr_t)handle;
    int first_error = 0;
    for (size_t index = 0; index < 4; ++index) {
        int descriptor = value->fds[index];
        if (descriptor < 0) continue;
        int result = close(descriptor);
        int error = result == 0 ? 0 : errno;
        value->fds[index] = -1;
        if (error != 0 && first_error == 0) first_error = error;
    }
    if (first_error != 0) return first_error;
    free(value);
    return 0;
}

int32_t process4cj_spawn_in_namespace(
    int64_t handle, const char *executable, char *const argv[], char *const envp[],
    const char *working_directory, int64_t *pid_out, int32_t *stdin_out,
    int32_t *stdout_out, int32_t *stderr_out, int32_t *status_out
) {
    if (handle <= 0) return EINVAL;
    p4_owned_namespaces *copy = NULL;
    int error = p4_namespace_clone((const p4_owned_namespaces *)(uintptr_t)handle, &copy);
    if (error != 0) return error;
    char **held_argv = NULL;
    char payload_descriptor[32];
    if (executable != NULL && strcmp(executable, "/usr/bin/bwrap") == 0) {
        /* bwrap otherwise implicitly creates a fresh user namespace after
         * exec, which the original --disable-userns forbids. Its documented
         * --userns entry regains setup capabilities in this exact held inner
         * namespace, without creating or weakening any user namespace. */
        size_t count = 0;
        if (argv == NULL || argv[0] == NULL) { error = EINVAL; goto complete; }
        /* Preserve the OS exec argument limits. This check bounds only the
         * real calloc multiplication and its four inserted options plus NUL. */
        for (;;) {
            if (count >= SIZE_MAX / sizeof(char *) - 5) { error = E2BIG; goto complete; }
            if (argv[count] == NULL) break;
            ++count;
        }
        int ended = 0;
        for (size_t index = 1; index < count;) {
            const char *option = argv[index];
            if (strcmp(option, "--") == 0) {
                if (index + 1 >= count) { error = EINVAL; goto complete; }
                ended = 1;
                break;
            }
            /* Exact borrowed Host sandbox grammar. Values are skipped by
             * arity, never mistaken for options or the payload delimiter.
             * Unknown options, including --args recursive input, cannot
             * replace our held namespace/sync FD or its lifetime init. */
            size_t arity;
            if (strcmp(option, "--die-with-parent") == 0 ||
                strcmp(option, "--unshare-ipc") == 0 || strcmp(option, "--unshare-uts") == 0 ||
                strcmp(option, "--unshare-cgroup-try") == 0 || strcmp(option, "--clearenv") == 0 ||
                strcmp(option, "--assert-userns-disabled") == 0) arity = 0;
            else if (strcmp(option, "--dir") == 0 || strcmp(option, "--proc") == 0 ||
                strcmp(option, "--dev") == 0 || strcmp(option, "--tmpfs") == 0 ||
                strcmp(option, "--chdir") == 0) arity = 1;
            else if (strcmp(option, "--ro-bind") == 0 || strcmp(option, "--ro-bind-try") == 0 ||
                strcmp(option, "--bind") == 0 || strcmp(option, "--setenv") == 0) arity = 2;
            else { error = EINVAL; goto complete; }
            if (arity >= count - index) { error = EINVAL; goto complete; }
            index += arity + 1;
        }
        if (!ended) { error = EINVAL; goto complete; }
        int width = snprintf(payload_descriptor, sizeof(payload_descriptor), "%d", copy->fds[0]);
        if (width < 1 || (size_t)width >= sizeof(payload_descriptor)) { error = EOVERFLOW; goto complete; }
        held_argv = calloc(count + 5, sizeof(char *));
        if (held_argv == NULL) { error = ENOMEM; goto complete; }
        held_argv[0] = argv[0]; held_argv[1] = "--userns"; held_argv[2] = payload_descriptor;
        /* The same held namespace is also owned by the sandbox lifetime init.
         * bwrap closes --sync-fd in its actual payload before exec, while the
         * init keeps it until the sandbox exits. No namespace FD reaches the
         * untrusted program, and the owning service remains the authority. */
        held_argv[3] = "--sync-fd"; held_argv[4] = payload_descriptor;
        for (size_t index = 1; index < count; ++index) held_argv[index + 4] = argv[index];
        copy->defer_payload_user = 1;
    }
    error = p4_spawn_process_internal(executable, held_argv == NULL ? argv : held_argv,
        envp, working_directory, 1, pid_out, stdin_out, stdout_out, stderr_out, status_out, copy);
complete:
    free(held_argv);
    p4_namespace_free(copy);
    return error;
}

/* A payload projection is accepted only from the exact newly owned process
 * tree, in this service's actual namespace, after the requested executable
 * has replaced the sandbox/setup wrappers. PID+startTime remain Host evidence;
 * the namespace PID is descriptive protocol output, never a launch grant.
 */
/* Return whether this exact matching executable has an earlier matching
 * payload in its actual captured owned ancestry. A Python launcher and its
 * Python debuggee are different processes; the child may never replace the
 * requested main payload. Every ancestry hop is bounded and startTime-fenced.
 */
static int p4_namespace_matching_ancestor(
    const p4_process_target *root, const p4_process_target *targets, size_t count,
    const p4_process_target *candidate, const struct stat *expected
) {
    p4_process_target cursor = *candidate;
    for (size_t depth = 0; depth <= count; ++depth) {
        pid_t parent = 0;
        uint64_t started = 0;
        if (!p4_read_process_stat(cursor.pid, &parent, &started, NULL) ||
            started != cursor.start_time) return -ESRCH;
        if (parent == root->pid) return p4_namespace_target_live(root->pid, root->start_time) ? 0 : -ESRCH;
        const p4_process_target *actual_parent = NULL;
        for (size_t index = 0; index < count; ++index) {
            if (targets[index].pid == parent) { actual_parent = &targets[index]; break; }
        }
        if (actual_parent == NULL || !p4_namespace_target_live(actual_parent->pid, actual_parent->start_time)) return -EAGAIN;
        char path[96];
        int length = snprintf(path, sizeof(path), "/proc/%ld/exe", (long)actual_parent->pid);
        struct stat executable;
        if (length <= 0 || (size_t)length >= sizeof(path) || stat(path, &executable) < 0) return -EAGAIN;
        if (!p4_namespace_target_live(actual_parent->pid, actual_parent->start_time)) return -ESRCH;
        if (executable.st_dev == expected->st_dev && executable.st_ino == expected->st_ino) return 1;
        cursor = *actual_parent;
    }
    return -EOVERFLOW;
}

int32_t process4cj_namespace_payload(
    int64_t handle, int64_t root_pid, int64_t root_start, const char *executable,
    int64_t *host_pid, int64_t *namespace_pid, int64_t *payload_start
) {
    if (handle <= 0 || root_pid <= 0 || root_pid > INT_MAX || root_start <= 0 ||
        executable == NULL || executable[0] != '/' || host_pid == NULL ||
        namespace_pid == NULL || payload_start == NULL) return EINVAL;
    const p4_owned_namespaces *value = (const p4_owned_namespaces *)(uintptr_t)handle;
    int error = p4_namespace_validate(value);
    if (error != 0) return error;
    struct stat expected;
    if (stat(executable, &expected) < 0) return errno;
    p4_process_target root = {(pid_t)root_pid, (uint64_t)root_start, 1};
    if (!p4_namespace_target_live(root.pid, root.start_time)) return ESRCH;
    p4_process_target *targets = calloc(P4_NAMESPACE_TARGETS, sizeof(*targets));
    if (targets == NULL) return ENOMEM;
    size_t count = 0;
    int overflow = 0;
    p4_collect_descendants(root.pid, &root, targets, P4_NAMESPACE_TARGETS, &count, &overflow, 0);
    if (overflow) { free(targets); return EOVERFLOW; }
    p4_process_target selected = {0, 0, 0};
    pid_t inner = 0;
    for (size_t index = 0; index < count; ++index) {
        if (!p4_namespace_target_live(targets[index].pid, targets[index].start_time)) continue;
        int matched = 1;
        for (size_t kind = 0; kind < 3; ++kind) {
            int ns = p4_namespace_open(targets[index].pid, p4_namespace_names[kind]);
            if (ns < 0) { matched = 0; break; }
            if (!p4_namespace_same_fd(ns, value->fds[kind])) matched = 0;
            p4_close_if_open(ns);
            if (!matched) break;
        }
        if (!matched) continue;
        char path[96];
        int length = snprintf(path, sizeof(path), "/proc/%ld/exe", (long)targets[index].pid);
        struct stat actual;
        if (length <= 0 || (size_t)length >= sizeof(path) || stat(path, &actual) < 0 ||
            actual.st_dev != expected.st_dev || actual.st_ino != expected.st_ino) continue;
        pid_t candidate_inner = 0;
        if (p4_namespace_last_pid(targets[index].pid, &candidate_inner) != 0) continue;
        int ancestor = p4_namespace_matching_ancestor(&root, targets, count, &targets[index], &expected);
        if (ancestor < 0) { error = -ancestor; break; }
        if (ancestor > 0) continue;
        if (selected.valid) { error = EEXIST; break; }
        selected = targets[index]; inner = candidate_inner;
    }
    if (error == 0 && selected.valid) {
        int ancestor = p4_namespace_matching_ancestor(&root, targets, count, &selected, &expected);
        if (ancestor != 0) error = ancestor < 0 ? -ancestor : ESTALE;
    }
    free(targets);
    if (error != 0) return error;
    if (!selected.valid) return EAGAIN;
    if (!p4_namespace_target_live(root.pid, root.start_time) ||
        !p4_namespace_target_live(selected.pid, selected.start_time)) return ESRCH;
    for (size_t kind = 0; kind < 3; ++kind) {
        int ns = p4_namespace_open(selected.pid, p4_namespace_names[kind]);
        if (ns < 0) return errno;
        int matched = p4_namespace_same_fd(ns, value->fds[kind]);
        p4_close_if_open(ns);
        if (!matched) return ESTALE;
    }
    error = p4_namespace_validate(value);
    if (error != 0) return error;
    *host_pid = selected.pid; *namespace_pid = inner; *payload_start = (int64_t)selected.start_time;
    return 0;
}

/* Private, anonymous, Host-owned complete event storage. This file has no
 * published name, Source or execution authority. Its descriptor is never
 * exported to a plugin or inherited by a worker. Every IO uses the original
 * descriptor; no pathname is reopened or removed during later cleanup. */
int32_t axyndra_run_event_spool_open(const char *root, int32_t *owned) {
    if (root == NULL || owned == NULL) return -EINVAL;
    *owned = -1;
    int directory = p4_open_directory_no_symlinks(root);
    if (directory < 0) return directory;
    int descriptor = openat(directory, ".", O_TMPFILE | O_RDWR | O_CLOEXEC, 0600);
    int failure = descriptor < 0 ? -errno : 0;
    /* Publish each acquired spool descriptor before any fallible post-check
     * or cleanup. The caller's existing real owner keeps it on failure. */
    *owned = descriptor;
    if (close(directory) < 0 && failure == 0) failure = -errno;
    if (failure != 0) return failure;
    struct stat actual;
    if (fstat(descriptor, &actual) < 0 || !S_ISREG(actual.st_mode) ||
        actual.st_nlink != 0 || actual.st_size != 0) {
        return -ESTALE;
    }
    return 0;
}

static int p4_run_event_spool_check(int descriptor, int64_t bytes) {
    if (descriptor < 0 || bytes < 0 || bytes > 67108864) return -EINVAL;
    struct stat actual;
    if (fstat(descriptor, &actual) < 0) return -errno;
    if (!S_ISREG(actual.st_mode) || actual.st_nlink != 0 || actual.st_size != bytes) return -ESTALE;
    return 0;
}

int32_t axyndra_run_event_spool_write(int descriptor, int64_t offset,
    const uint8_t *buffer, int64_t length) {
    if (buffer == NULL || length < 1 || length > 16384 || offset > 67108864 - length) return -EINVAL;
    int checked = p4_run_event_spool_check(descriptor, offset);
    if (checked != 0) return checked;
    int64_t written = 0;
    while (written < length) {
        ssize_t count = pwrite(descriptor, buffer + written, (size_t)(length - written), offset + written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return count < 0 ? -errno : -EIO;
        written += count;
    }
    return p4_run_event_spool_check(descriptor, offset + length);
}

int32_t axyndra_run_event_spool_freeze(int descriptor, int64_t bytes) {
    int checked = p4_run_event_spool_check(descriptor, bytes);
    if (checked != 0) return checked;
    int result;
    do { result = fsync(descriptor); } while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    return p4_run_event_spool_check(descriptor, bytes);
}

int64_t axyndra_run_event_spool_read(int descriptor, int64_t bytes,
    int64_t offset, uint8_t *buffer, int64_t capacity) {
    if (buffer == NULL || capacity < 1 || capacity > 65536 || offset < 0 || offset > bytes) return -EINVAL;
    int checked = p4_run_event_spool_check(descriptor, bytes);
    if (checked != 0) return checked;
    if (offset == bytes) return 0;
    int64_t amount = bytes - offset;
    if (amount > capacity) amount = capacity;
    ssize_t count;
    do { count = pread(descriptor, buffer, (size_t)amount, offset); } while (count < 0 && errno == EINTR);
    if (count <= 0) return count < 0 ? -errno : -ESTALE;
    checked = p4_run_event_spool_check(descriptor, bytes);
    return checked == 0 ? count : checked;
}

int32_t axyndra_run_event_spool_close(int descriptor) {
    if (descriptor < 0) return -EINVAL;
    if (close(descriptor) == 0) return 0;
    /* This translation unit is Linux-only. Linux releases the descriptor even
     * when close reports EINTR; retrying could close an unrelated reused fd. */
    if (errno == EBADF) return -errno;
    /* Linux also releases the descriptor for the other close errors. Report
     * that physical retirement distinctly; callers retain/report the actual
     * error without retrying a descriptor number that may already be reused. */
    return errno;
}


#include <stddef.h>
/* Actual Process180 restoration input. No launch/current/source authority.
 * The caller pays sizeof(this exact context) before construction. Directory
 * entries remain borrowed in one fixed getdents buffer until their exact UTF-8
 * byte extent has been paid; no Directory.readFrom snapshot or name cap. */
#if defined(__linux__) && defined(__x86_64__)
typedef struct {
    int fd;
    int directory;
    int close_failure;
    int64_t offset;
    int64_t available;
    const char *name;
    int64_t name_size;
    struct stat identity;
    uint8_t bytes[65536];
} p4_process_input180;
typedef struct {
    uint64_t ino;
    int64_t off;
    unsigned short reclen;
    unsigned char type;
    char name[];
} p4_process_dirent180;
static int p4_process_file_identity180(p4_process_input180 *held) {
    struct stat current;
    if (held->fd < 0 || fstat(held->fd, &current) < 0) return -errno;
    const struct stat *old = &held->identity;
    if (!S_ISREG(current.st_mode) || current.st_nlink != 1 ||
        current.st_dev != old->st_dev || current.st_ino != old->st_ino ||
        current.st_size != old->st_size || current.st_mtim.tv_sec != old->st_mtim.tv_sec ||
        current.st_mtim.tv_nsec != old->st_mtim.tv_nsec ||
        current.st_ctim.tv_sec != old->st_ctim.tv_sec ||
        current.st_ctim.tv_nsec != old->st_ctim.tv_nsec) return -ESTALE;
    return 0;
}
#endif
int64_t process4cj_input_context_bytes180(void) {
#if defined(__linux__) && defined(__x86_64__)
    return (int64_t)sizeof(p4_process_input180);
#else
    return 0;
#endif
}
int32_t process4cj_input_open180(const char *path, int32_t directory,
    int64_t maximum, int64_t *registered) {
    if (registered == NULL) return -EINVAL;
    *registered = 0;
#if !defined(__linux__) || !defined(__x86_64__)
    (void)path; (void)directory; (void)maximum; return -ENOTSUP;
#else
    if (path == NULL || maximum < 0 || (directory != 0 && directory != 1)) return -EINVAL;
    p4_process_input180 *held = calloc(1, sizeof(*held));
    if (held == NULL) return -ENOMEM;
    held->fd = -1; held->directory = directory;
    /* The caller's already registered cell receives this context before any
     * fallible open. On error it still owns close/error custody. */
    *registered = (int64_t)(intptr_t)held;
    if (directory) {
        int fd = p4_open_directory_no_symlinks(path);
        if (fd < 0) return fd;
        held->fd = fd; return 0;
    }
    int identity = p4_read_view_open(path);
    if (identity < 0) return identity;
    int result = fstat(identity, &held->identity) == 0 ? 0 : -errno;
    if (result == 0 && (!S_ISREG(held->identity.st_mode) || held->identity.st_nlink != 1 ||
        held->identity.st_size < 0 || held->identity.st_size > maximum)) result = -EPERM;
    char actual[64];
    if (result == 0) {
        snprintf(actual, sizeof(actual), "/proc/self/fd/%d", identity);
        held->fd = open(actual, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (held->fd < 0) result = -errno;
    }
    if (result == 0) result = p4_process_file_identity180(held);
    /* Linux close is attempted once; any late failure remains explicit. */
    if (close(identity) < 0 && result == 0 && errno != EINTR) result = -errno;
    return result;
#endif
}
int64_t process4cj_directory_next_extent180(int64_t opaque) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)opaque; return -ENOTSUP;
#else
    if (opaque <= 0) return -EINVAL;
    p4_process_input180 *held = (p4_process_input180 *)(intptr_t)opaque;
    if (!held->directory || held->fd < 0 || held->close_failure) return -EINVAL;
    held->name = NULL; held->name_size = 0;
    for (;;) {
        if (held->offset == held->available) {
            ssize_t read_count;
            do { read_count = syscall(SYS_getdents64, held->fd, held->bytes, sizeof(held->bytes)); }
            while (read_count < 0 && errno == EINTR);
            if (read_count < 0) return -errno;
            if (read_count == 0) return 0;
            held->offset = 0; held->available = read_count;
        }
        const int64_t prefix = (int64_t)offsetof(p4_process_dirent180, name);
        if (held->available - held->offset < prefix + 1) return -EPROTO;
        p4_process_dirent180 *entry = (p4_process_dirent180 *)(held->bytes + held->offset);
        if (entry->reclen < prefix + 1 || entry->reclen > held->available - held->offset) return -EPROTO;
        const char *end = memchr(entry->name, '\0', (size_t)(entry->reclen - prefix));
        if (end == NULL) return -EPROTO;
        held->offset += entry->reclen;
        int64_t size = (int64_t)(end - entry->name);
        if (size == 0 || (size == 1 && entry->name[0] == '.') ||
            (size == 2 && entry->name[0] == '.' && entry->name[1] == '.')) continue;
        held->name = entry->name; held->name_size = size; return size;
    }
#endif
}
int32_t process4cj_directory_copy_name180(int64_t opaque, uint8_t *out, int64_t extent) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)opaque; (void)out; (void)extent; return -ENOTSUP;
#else
    if (opaque <= 0 || out == NULL) return -EINVAL;
    p4_process_input180 *held = (p4_process_input180 *)(intptr_t)opaque;
    if (held->name == NULL || extent != held->name_size || held->fd < 0 || held->close_failure) return -EINVAL;
    memcpy(out, held->name, (size_t)extent); return 0;
#endif
}
int64_t process4cj_file_read_owned180(int64_t opaque, uint8_t *out, int64_t extent) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)opaque; (void)out; (void)extent; return -ENOTSUP;
#else
    if (opaque <= 0 || out == NULL || extent < 1 || extent > 65536) return -EINVAL;
    p4_process_input180 *held = (p4_process_input180 *)(intptr_t)opaque;
    if (held->directory || held->close_failure) return -EINVAL;
    int result = p4_process_file_identity180(held);
    if (result != 0) return result;
    ssize_t count;
    do { count = read(held->fd, out, (size_t)extent); } while (count < 0 && errno == EINTR);
    if (count < 0) return -errno;
    result = p4_process_file_identity180(held);
    return result == 0 ? count : result;
#endif
}
int32_t process4cj_input_close180(int64_t opaque) {
#if !defined(__linux__) || !defined(__x86_64__)
    (void)opaque; return -ENOTSUP;
#else
    if (opaque <= 0) return 0;
    p4_process_input180 *held = (p4_process_input180 *)(intptr_t)opaque;
    if (held->close_failure) return held->close_failure;
    int fd = held->fd; held->fd = -1;
    if (fd >= 0 && close(fd) < 0 && errno != EINTR) {
        held->close_failure = -errno; return held->close_failure;
    }
    free(held); return 0;
#endif
}

/* Private opened-process signalling. The caller invoices this exact fixed
 * synchronous frame before entry. No heap, process-wide directory snapshot,
 * shell command or supplied PID can stand in for the native owner identity. */
typedef struct {
    p4_process_target targets[P4_MAX_DESCENDANTS];
    uint8_t stopped[P4_MAX_DESCENDANTS];
    uint8_t directory[65536];
    char children[4096];
    char token[32];
    char path[128];
    size_t count;
} p4_owned_signal_frame180;

int64_t process4cj_signal_frame_bytes180(void) {
    return (int64_t)sizeof(p4_owned_signal_frame180) + 65536;
}
static int p4_stat_fields180(pid_t pid, pid_t *parent, uint64_t *started, char *state) {
    char path[96], bytes[4096];
    int length = snprintf(path, sizeof(path), "/proc/%ld/stat", (long)pid);
    if (pid < 1 || length < 1 || (size_t)length >= sizeof(path)) return EINVAL;
    int descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return errno;
    ssize_t size;
    do { size = read(descriptor, bytes, sizeof(bytes) - 1); } while (size < 0 && errno == EINTR);
    int error = size < 0 ? errno : (size < 1 ? EIO : 0);
    if (close(descriptor) < 0 && !error) error = errno;
    if (error) return error;
    if (size == (ssize_t)sizeof(bytes) - 1) return EOVERFLOW;
    bytes[size] = '\0';
    char *name_end = strrchr(bytes, ')');
    if (!name_end || name_end[1] != ' ') return EPROTO;
    char *cursor = name_end + 2;
    for (int field = 3; field <= 22; ++field) {
        while (*cursor == ' ') ++cursor;
        if (!*cursor || *cursor == '\n') return EPROTO;
        char *end = cursor;
        while (*end && *end != ' ' && *end != '\n') ++end;
        if (field == 3 && state) {
            if (end - cursor != 1) return EPROTO;
            *state = *cursor;
        }
        if ((field == 4 && parent) || field == 22) {
            uint64_t number = 0;
            for (char *digit = cursor; digit != end; ++digit) {
                if (*digit < '0' || *digit > '9' || number > (UINT64_MAX - (uint64_t)(*digit - '0')) / 10) return EPROTO;
                number = number * 10 + (uint64_t)(*digit - '0');
            }
            if (field == 4) {
                if (number > INT_MAX) return EOVERFLOW;
                *parent = (pid_t)number;
            } else {
                if (!number) return EPROTO;
                *started = number;
            }
        }
        cursor = end;
    }
    return 0;
}
static int p4_exact_stat180(const p4_process_target *target, char *state) {
    uint64_t started = 0;
    int result = p4_stat_fields180(target->pid, NULL, &started, state);
    if (result) return result == ENOENT ? ESRCH : result;
    return started == target->start_time ? 0 : ESRCH;
}
static int p4_pidfd_signal180(const p4_process_target *target, int signal_value, int *accepted) {
    if (accepted) *accepted = 0;
#if !defined(SYS_pidfd_open) || !defined(SYS_pidfd_send_signal)
    (void)target; (void)signal_value; return ENOTSUP;
#else
    int descriptor = (int)syscall(SYS_pidfd_open, target->pid, 0);
    if (descriptor < 0) return errno;
    int error = p4_exact_stat180(target, NULL);
    if (!error) {
        if (syscall(SYS_pidfd_send_signal, descriptor, signal_value, NULL, 0) < 0) error = errno;
        else if (accepted) *accepted = 1;
    }
    /* Never retry a descriptor number after close: Linux may already have
     * released it. Any unknown close is reported, never successful cleanup. */
    if (close(descriptor) < 0 && !error) error = errno;
    return error;
#endif
}
static int p4_append_child180(p4_owned_signal_frame180 *frame, const char *token,
    pid_t process_pid, pid_t thread_pid) {
    pid_t child = 0;
    if (!p4_parse_pid_name(token, &child)) return EPROTO;
    pid_t parent = 0; uint64_t started = 0;
    int result = p4_stat_fields180(child, &parent, &started, NULL);
    if (result) return result == ENOENT || result == ESRCH ? 0 : result;
    if (started == 0) return EPROTO;
    if (parent != process_pid && parent != thread_pid) return 0;
    p4_process_target target = { child, started, 1 };
    if (p4_contains_target(frame->targets, frame->count, &target)) return 0;
    if (frame->count == P4_MAX_DESCENDANTS) return EOVERFLOW;
    frame->targets[frame->count++] = target;
    return 0;
}
static int p4_read_thread_children180(p4_owned_signal_frame180 *frame,
    pid_t process_pid, pid_t thread_pid) {
    int length = snprintf(frame->path, sizeof(frame->path), "/proc/%ld/task/%ld/children",
        (long)process_pid, (long)thread_pid);
    if (length < 1 || (size_t)length >= sizeof(frame->path)) return EOVERFLOW;
    int descriptor = open(frame->path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (descriptor < 0) return errno == ENOENT || errno == ESRCH ? 0 : errno;
    int result = 0; size_t token_size = 0;
    for (;;) {
        ssize_t bytes;
        do { bytes = read(descriptor, frame->children, sizeof(frame->children)); } while (bytes < 0 && errno == EINTR);
        if (bytes < 0) { result = errno; break; }
        if (bytes == 0) break;
        for (ssize_t index = 0; index < bytes; ++index) {
            char byte = frame->children[index];
            if (byte >= '0' && byte <= '9') {
                if (token_size + 1 >= sizeof(frame->token)) { result = EOVERFLOW; break; }
                frame->token[token_size++] = byte;
            } else if (byte == ' ' || byte == '\n' || byte == '\t') {
                if (token_size) {
                    frame->token[token_size] = '\0';
                    result = p4_append_child180(frame, frame->token, process_pid, thread_pid);
                    token_size = 0;
                    if (result) break;
                }
            } else { result = EPROTO; break; }
        }
        if (result) break;
    }
    if (!result && token_size) {
        frame->token[token_size] = '\0';
        result = p4_append_child180(frame, frame->token, process_pid, thread_pid);
    }
    if (close(descriptor) < 0 && !result) result = errno;
    return result;
}
static int p4_collect_owned_children180(p4_owned_signal_frame180 *frame,
    const p4_process_target *target) {
    int result = p4_exact_stat180(target, NULL);
    if (result) return result;
    int length = snprintf(frame->path, sizeof(frame->path), "/proc/%ld/task", (long)target->pid);
    if (length < 1 || (size_t)length >= sizeof(frame->path)) return EOVERFLOW;
    int descriptor = open(frame->path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (descriptor < 0) return errno;
    for (;;) {
        ssize_t bytes;
        do { bytes = syscall(SYS_getdents64, descriptor, frame->directory, sizeof(frame->directory)); }
        while (bytes < 0 && errno == EINTR);
        if (bytes < 0) { result = errno; break; }
        if (!bytes) break;
        size_t offset = 0;
        while (offset < (size_t)bytes) {
            size_t prefix = offsetof(p4_process_dirent180, name);
            if ((size_t)bytes - offset < prefix + 1) { result = EPROTO; break; }
            p4_process_dirent180 *entry = (p4_process_dirent180 *)(frame->directory + offset);
            if (entry->reclen < prefix + 1 || entry->reclen > (size_t)bytes - offset ||
                memchr(entry->name, '\0', entry->reclen - prefix) == NULL) { result = EPROTO; break; }
            pid_t thread = 0;
            if (p4_parse_pid_name(entry->name, &thread)) {
                result = p4_read_thread_children180(frame, target->pid, thread);
                if (result) break;
            }
            offset += entry->reclen;
        }
        if (result) break;
    }
    if (close(descriptor) < 0 && !result) result = errno;
    return result;
}
int32_t process4cj_signal_owned_tree180(int64_t pid, int64_t expected_start, int32_t signal_value) {
#if !defined(__linux__) || !defined(__x86_64__) || !defined(SYS_getdents64)
    (void)pid; (void)expected_start; (void)signal_value; return ENOTSUP;
#else
    if (pid < 1 || pid > INT_MAX || expected_start < 1 ||
        (signal_value != SIGINT && signal_value != SIGTERM && signal_value != SIGHUP &&
         signal_value != SIGQUIT && signal_value != SIGKILL)) return EINVAL;
    p4_owned_signal_frame180 frame;
    memset(&frame, 0, sizeof(frame));
    frame.targets[frame.count++] = (p4_process_target){ (pid_t)pid, (uint64_t)expected_start, 1 };
    int result = 0; int stable_passes = 0; int captured = 0;
    /* Stop exact identities, then re-read ALL current parents, including the
     * stopped subreaper. A child can fork and exit before its SIGSTOP reaches
     * it, adopting a grandchild back to an already scanned root. Two stable
     * full passes after the stops close that window. The old 4096-entry cap
     * is unchanged; churn/overflow/unknown observations fail closed. */
    for (size_t pass = 0; pass < P4_MAX_DESCENDANTS + 2; ++pass) {
        size_t previous_count = frame.count;
        for (size_t index = 0; index < frame.count; ++index) {
            if (!frame.stopped[index]) {
                int accepted = 0;
                result = p4_pidfd_signal180(&frame.targets[index], SIGSTOP, &accepted);
                frame.stopped[index] = (uint8_t)accepted;
                if (result == ESRCH && index != 0) { result = 0; continue; }
                if (result) break;
                int stopped = 0;
                for (int attempt = 0; attempt < 100; ++attempt) {
                    char state = '\0';
                    result = p4_exact_stat180(&frame.targets[index], &state);
                    if (result == ESRCH && index != 0) { result = 0; stopped = 1; break; }
                    if (result) break;
                    if (state == 'T' || state == 't' || state == 'Z' || state == 'X') { stopped = 1; break; }
                    p4_sleep_millis(1);
                }
                if (result) break;
                if (!stopped) { result = ETIMEDOUT; break; }
            }
            result = p4_collect_owned_children180(&frame, &frame.targets[index]);
            if ((result == ESRCH || result == ENOENT) && index != 0) result = 0;
            if (result) break;
        }
        if (result) break;
        if (frame.count == previous_count) ++stable_passes;
        else stable_passes = 0;
        if (stable_passes == 2) { captured = 1; break; }
    }
    if (!result && !captured) result = EAGAIN;
    if (!result) {
        /* targets[0] is the ONLY subreaper. Never deliver the requested
         * signal to it, particularly SIGKILL: it must remain alive to reap. */
        for (size_t index = frame.count; index > 1; --index) {
            int actual = p4_pidfd_signal180(&frame.targets[index - 1], signal_value, NULL);
            if (actual != ESRCH && actual && !result) result = actual;
        }
    }
    /* Always resume the exact subreaper too. It may produce the private
     * receipt only after real ECHILD. Errors remain UNKNOWN/paid, never an
     * excuse to kill it and promote parent waitpid to a tree receipt. */
    for (size_t index = frame.count; index > 0; --index) {
        if (!frame.stopped[index - 1]) continue;
        int actual = p4_pidfd_signal180(&frame.targets[index - 1], SIGCONT, NULL);
        if (actual != ESRCH && actual && !result) result = actual;
    }
    return result;
#endif
}

/* The returned descriptor is published even on a post-open identity error.
 * The caller's prepaid registered owner, not a C temporary or a history row,
 * keeps it reachable until a whole close helper returns. */
int32_t process4cj_open_incarnation180(int64_t pid, int64_t expected_start, int32_t *owned_fd) {
#if !defined(__linux__) || !defined(SYS_pidfd_open)
    (void)pid; (void)expected_start; (void)owned_fd; return -ENOTSUP;
#else
    if (!owned_fd || pid < 1 || pid > INT_MAX || expected_start < 1) return -EINVAL;
    *owned_fd = -1;
    int descriptor = (int)syscall(SYS_pidfd_open, (pid_t)pid, 0);
    if (descriptor < 0) return errno == ESRCH ? 1 : -errno;
    *owned_fd = descriptor;
    p4_process_target target = { (pid_t)pid, (uint64_t)expected_start, 1 };
    int error = p4_exact_stat180(&target, NULL);
    if (error == ESRCH) return 1;
    return error ? -error : 0;
#endif
}
int32_t process4cj_incarnation_exit180(int32_t descriptor) {
    if (descriptor < 0) return -EBADF;
    struct pollfd owned = { descriptor, POLLIN, 0 };
    int result;
    do { result = poll(&owned, 1, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return -errno;
    if (owned.revents & (POLLERR | POLLNVAL)) return -EIO;
    if (owned.revents & POLLIN) return 1;
    if (owned.revents & POLLHUP) return -EIO;
    return 0;
}
int32_t process4cj_close_once180(int32_t descriptor) {
    if (descriptor < 0) return EBADF;
    return close(descriptor) == 0 ? 0 : errno;
}

/* No whole environ snapshot or value allocation precedes the invoice. A
 * changed larger value is refused by the bounded second read, not copied and
 * measured afterwards. The process does not mutate ambient environment. */
int32_t process4cj_environment_size180(const char *name, int64_t *length) {
    if (!name || !*name || !length || strchr(name, '=')) return -EINVAL;
    *length = 0;
    const char *value = getenv(name);
    if (!value) return 0;
    size_t size = strlen(value);
    if (size > INT64_MAX) return -EOVERFLOW;
    *length = (int64_t)size;
    return 1;
}
int32_t process4cj_environment_copy180(const char *name, uint8_t *bytes, int64_t capacity, int64_t *copied) {
    if (!name || !*name || capacity < 0 || !copied || strchr(name, '=') || (!bytes && capacity)) return -EINVAL;
    *copied = 0;
    const char *value = getenv(name);
    if (!value) return 0;
    size_t size = strlen(value);
    if (size > (uint64_t)capacity) return -ERANGE;
    if (size) memcpy(bytes, value, size);
    *copied = (int64_t)size;
    return 1;
}

/* The prepaid native owner retains this descriptor until the actual read
 * helper and waiting Future return. No ignored close, retry-on-EINTR close,
 * or errno-to-exit-code conversion can serve as resource retirement. */
int64_t process4cj_wait_status_owned180(int32_t fd) {
    if (fd < 0) return -EBADF;
    int32_t status = 0;
    unsigned char *bytes = (unsigned char *)&status;
    size_t offset = 0;
    while (offset < sizeof(status)) {
        ssize_t count = read(fd, bytes + offset, sizeof(status) - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) return -(int64_t)errno;
        if (count == 0) return -EPIPE;
        offset += (size_t)count;
    }
    return (int64_t)status;
}

/* Owned-only receipt: command status is unchanged and still arrives first.
 * A second, private fixed record exists only after the subreaper's REAL
 * waitpid(-1) loop reached ECHILD. A killed root, EOF, arbitrary exit status,
 * signal acceptance or process counter is never equivalent to this record. */
#define P4_OWNED_REAP_MAGIC180 0x50345250
#define P4_OWNED_FORK_MAGIC180 0x5034464B
int32_t process4cj_wait_tree_reap_receipt180(int32_t fd, int64_t command_status) {
    int64_t magic = process4cj_wait_status_owned180(fd);
    if (magic < 0) return (int32_t)-magic;
    if (magic != P4_OWNED_REAP_MAGIC180) return EPROTO;
    int64_t actual_status = process4cj_wait_status_owned180(fd);
    if (actual_status < 0) return (int32_t)-actual_status;
    return actual_status == command_status ? 0 : EPROTO;
}
int32_t process4cj_reap_receipted_supervisor180(int64_t pid, int64_t command_status) {
    if (pid < 1 || pid > INT_MAX || command_status < 0 || command_status > 255) return EINVAL;
    int status = 0; pid_t reaped;
    do { reaped = waitpid((pid_t)pid, &status, 0); } while (reaped < 0 && errno == EINTR);
    if (reaped < 0) return errno;
    if (reaped != (pid_t)pid || !WIFEXITED(status) || WEXITSTATUS(status) != command_status) return EPROTO;
    return 0;
}

static void p4_owned_supervisor_child180(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int in_read,
    int in_write,
    int out_read,
    int out_write,
    int err_read,
    int err_write,
    int status_read,
    int status_write,
    int error_write,
    int fork_ready_write,
    const p4_owned_namespaces *namespaces
) {
    if (setsid() < 0) {
        (void)p4_write_spawn_error(error_write, errno);
        _exit(127);
    }
    if (prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) < 0) {
        (void)p4_write_spawn_error(error_write, errno);
        _exit(127);
    }
    if (signal(SIGTERM, SIG_IGN) == SIG_ERR) {
        (void)p4_write_spawn_error(error_write, errno);
        _exit(127);
    }
    /*
     * A forked process inherits the broker's listener and lock descriptors.
     * Keep only the endpoints needed by this supervisor and its command;
     * otherwise an orphaned supervisor can keep a dead broker endpoint alive.
     */
    int inherited_fds[] = {
        in_read,
        in_write,
        out_read,
        out_write,
        err_read,
        err_write,
        status_read,
        status_write,
        error_write,
        fork_ready_write,
        namespaces == NULL ? -1 : namespaces->fds[0],
        namespaces == NULL ? -1 : namespaces->fds[1],
        namespaces == NULL ? -1 : namespaces->fds[2],
        namespaces == NULL ? -1 : namespaces->fds[3]
    };
    int close_error = p4_close_all_except(
        inherited_fds,
        sizeof(inherited_fds) / sizeof(inherited_fds[0])
    );
    if (close_error != 0) {
        (void)p4_write_spawn_error(error_write, close_error);
        _exit(127);
    }

    pid_t command_pid = fork();
    if (command_pid < 0) {
        (void)p4_write_spawn_error(error_write, errno);
        _exit(127);
    }
    if (command_pid == 0) {
        p4_close_if_open(fork_ready_write);
        p4_supervisor_exec_child(
            executable,
            argv,
            envp,
            working_directory,
            in_read,
            in_write,
            out_read,
            out_write,
            err_read,
            err_write,
            status_read,
            status_write,
            error_write,
            namespaces
        );
        _exit(127);
    }
    /* This private fixed record is issued ONLY after the actual command
     * fork returned. The parent must consume it before any post-fork close
     * or cancellation capture; two empty tree scans cannot prove a command
     * which this supervisor has not forked yet was cancelled. */
    int fork_ready_error = p4_write_spawn_error(fork_ready_write, P4_OWNED_FORK_MAGIC180);
    p4_close_if_open(fork_ready_write);
    /* An unknown readiness write must not kill the only live subreaper.
     * The parent's registered journal retains every endpoint on an unknown
     * readiness read; it cannot claim tree ACK or retry a close. */
    (void)fork_ready_error;
    p4_namespace_close_fds(namespaces);
    p4_close_if_open(in_read);
    p4_close_if_open(in_write);
    p4_close_if_open(out_read);
    p4_close_if_open(out_write);
    p4_close_if_open(err_read);
    p4_close_if_open(err_write);
    p4_close_if_open(status_read);
    p4_close_if_open(error_write);

    int command_status = 127;
    int command_reaped = 0;
    int status_sent = 0;
    for (;;) {
        int status = 0;
        pid_t waited;
        do { waited = waitpid(-1, &status, 0); }
        while (waited < 0 && errno == EINTR);
        if (waited < 0) {
            if (errno == ECHILD) break;
            _exit(127);
        }
        if (waited == command_pid) {
            command_reaped = 1;
            if (WIFEXITED(status)) {
                command_status = WEXITSTATUS(status);
            } else if (WIFSIGNALED(status)) {
                command_status = 128 + WTERMSIG(status);
            }
            if (p4_write_spawn_error(status_write, command_status) != 0) _exit(127);
            /* Keep this ORIGINAL private pipe until all adopted descendants
             * have actually been reaped. The command closes its inherited
             * endpoint before exec; no public callback can mint this receipt. */
            status_sent = 1;
        }
    }
    /* The only route here is the actual waitpid(-1) ECHILD break above.
     * Any earlier setup/wait/write failure exits WITHOUT this receipt. */
    if (!status_sent || !command_reaped) { p4_close_if_open(status_write); _exit(127); }
    if (p4_write_spawn_error(status_write, P4_OWNED_REAP_MAGIC180) != 0 ||
        p4_write_spawn_error(status_write, command_status) != 0) {
        p4_close_if_open(status_write); _exit(127);
    }
    p4_close_if_open(status_write);
    _exit(command_status);
}

/* Native-owned persistent spawn. This journal is allocated and registered by
 * ProcessNativeStartCustody180 before any pipe/fork. It is DATA, not authority.
 * Header: magic,pid,start,primary,entered,returned,exec-handshake,reaped,
 * signal-attempt,signal-errno,wait-attempt,wait-errno,fd-count,close-errno.
 * 32 fixed descriptor records at 16, each (fd,state,errno): open=0,
 * closed-by-one-actual-close=1, transferred-to-registered-owner=2, unknown=3.
 * A nonzero close result is never retried and never treated as absence.
 * Actual shipping ProcessCommand uses terminateProcessTree=true. A false
 * flag is rejected by this new entry BEFORE resources; old Support spawn
 * still implements its original posix_spawn contract without any change. */
#define P4_OWNED_JOURNAL_WORDS180 112
#define P4_OWNED_JOURNAL_FDS180 32
static int p4_owned_fd_register180(int64_t *journal, int fd) {
    int count = (int)journal[12];
    if (count < 0 || count >= P4_OWNED_JOURNAL_FDS180) return EOVERFLOW;
    journal[16 + count * 3] = fd;
    journal[16 + count * 3 + 1] = 0;
    journal[16 + count * 3 + 2] = 0;
    journal[12] = count + 1;
    return 0;
}
static int p4_owned_fd_index180(int64_t *journal, int fd) {
    for (int index = (int)journal[12] - 1; index >= 0; --index) {
        if (journal[16 + index * 3] == fd &&
            (journal[16 + index * 3 + 1] == 0 || journal[16 + index * 3 + 1] == 2)) return index;
    }
    return -1;
}
static int p4_owned_fd_close180(int64_t *journal, int fd) {
    if (fd < 0) return 0;
    int index = p4_owned_fd_index180(journal, fd);
    if (index < 0) return EPROTO;
    int result = close(fd);
    int error = result < 0 ? errno : 0;
    journal[16 + index * 3 + 1] = error == 0 ? 1 : 3;
    journal[16 + index * 3 + 2] = error;
    if (error != 0 && journal[13] == 0) journal[13] = error;
    return error;
}
static int p4_owned_pipe180(int64_t *journal, int descriptors[2]) {
    if (pipe2(descriptors, O_CLOEXEC) < 0) return errno;
    /* At most twelve endpoints plus twelve promotions exist: the fixed 32-record
     * journal is sufficient before entering pipe2, without a size guess. */
    int error = p4_owned_fd_register180(journal, descriptors[0]);
    if (error == 0) error = p4_owned_fd_register180(journal, descriptors[1]);
    return error;
}
static int p4_owned_promote180(int64_t *journal, int *fd) {
    if (*fd > STDERR_FILENO) return 0;
    int original_fd = *fd;
    int promoted = fcntl(original_fd, F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
    if (promoted < 0) return errno;
    int error = p4_owned_fd_register180(journal, promoted);
    *fd = promoted; /* The new descriptor is registered before old close. */
    if (error != 0) return error;
    return p4_owned_fd_close180(journal, original_fd);
}
static void p4_owned_transfer180(int64_t *journal, int fd) {
    int index = p4_owned_fd_index180(journal, fd);
    if (index >= 0) journal[16 + index * 3 + 1] = 2;
}
/* Called only with the parent's still-open journalled ORIGINAL status FD.
 * No receipt/read/reap failure is marked reaped. This is also the partial
 * launch and unwrapped-platform recovery route, not just normal close. */
static int p4_owned_reap_after_echild180(int64_t *journal, int status_fd) {
    journal[10] = 1;
    int index = p4_owned_fd_index180(journal, status_fd);
    if (status_fd < 0 || index < 0) { journal[11] = EBADF; return EBADF; }
    int64_t command_status = process4cj_wait_status_owned180(status_fd);
    int result = command_status < 0 ? (int)-command_status :
        process4cj_wait_tree_reap_receipt180(status_fd, command_status);
    if (!result) result = process4cj_reap_receipted_supervisor180(journal[1], command_status);
    if (result) journal[11] = result;
    else journal[7] = 1;
    return result;
}

int32_t process4cj_spawn_owned180(
    const char *executable, char *const argv[], char *const envp[],
    const char *working_directory, int32_t new_session, int64_t *pid_out,
    int32_t *stdin_out, int32_t *stdout_out, int32_t *stderr_out, int32_t *status_out,
    int64_t *journal, int64_t journal_words
) {
    if (journal == NULL || journal_words != P4_OWNED_JOURNAL_WORDS180 ||
        pid_out == NULL || stdin_out == NULL || stdout_out == NULL ||
        stderr_out == NULL || status_out == NULL) return EINVAL;
    memset(journal, 0, sizeof(int64_t) * P4_OWNED_JOURNAL_WORDS180);
    journal[0] = 180; journal[4] = 1;
    *pid_out = 0; *stdin_out = -1; *stdout_out = -1; *stderr_out = -1; *status_out = -1;
    int in_pipe[2] = {-1, -1}, out_pipe[2] = {-1, -1}, err_pipe[2] = {-1, -1};
    int status_pipe[2] = {-1, -1}, error_pipe[2] = {-1, -1};
    int fork_ready_pipe[2] = {-1, -1};
    int actual_fork_ready = 0;
    int result = new_session ? 0 : ENOTSUP;
    if (result != 0) goto owned_cleanup;
    if ((result = p4_owned_pipe180(journal, in_pipe)) != 0 ||
        (result = p4_owned_pipe180(journal, out_pipe)) != 0 ||
        (result = p4_owned_pipe180(journal, err_pipe)) != 0 ||
        (result = p4_owned_pipe180(journal, status_pipe)) != 0 ||
        (result = p4_owned_pipe180(journal, error_pipe)) != 0 ||
        (result = p4_owned_pipe180(journal, fork_ready_pipe)) != 0) goto owned_cleanup;
    for (int index = 0; index < (int)journal[12]; ++index) {
        if (journal[16 + index * 3 + 1] != 0) continue;
        int fd = (int)journal[16 + index * 3];
        if (fd > STDERR_FILENO) continue;
        int *groups[6] = {in_pipe, out_pipe, err_pipe, status_pipe, error_pipe, fork_ready_pipe};
        for (int group = 0; group < 6; ++group) for (int side = 0; side < 2; ++side) {
            if (groups[group][side] == fd && (result = p4_owned_promote180(journal, &groups[group][side])) != 0)
                goto owned_cleanup;
        }
    }
    pid_t parent_pid = getpid();
    pid_t supervisor = fork();
    if (supervisor < 0) { result = errno; goto owned_cleanup; }
    if (supervisor == 0) {
        p4_close_if_open(error_pipe[0]);
        p4_close_if_open(fork_ready_pipe[0]);
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0) {
            (void)p4_write_spawn_error(error_pipe[1], errno); _exit(127);
        }
        if (getppid() != parent_pid) {
            (void)p4_write_spawn_error(error_pipe[1], ESRCH); _exit(127);
        }
        p4_owned_supervisor_child180(executable, argv, envp, working_directory,
            in_pipe[0], in_pipe[1], out_pipe[0], out_pipe[1], err_pipe[0], err_pipe[1],
            status_pipe[0], status_pipe[1], error_pipe[1], fork_ready_pipe[1], NULL);
        _exit(127);
    }
    /* This write precedes the exec handshake and every post-fork close. The
     * parent remains actual waitpid owner, so the unreaped PID cannot recycle. */
    journal[1] = (int64_t)supervisor; *pid_out = (int64_t)supervisor;
    journal[2] = process4cj_start_time((int64_t)supervisor);
    /* Drop this parent's readiness writer before reading, so a supervisor
     * setup failure produces real EOF. An unknown writer close goes directly
     * to paid Held and NEVER attempts a pre-fork tree capture. */
    result = p4_owned_fd_close180(journal, fork_ready_pipe[1]); fork_ready_pipe[1] = -1;
    if (result != 0) goto owned_cleanup;
    /* Consume the complete private fork receipt BEFORE any capture or the
     * error-pipe close. Empty scans cannot acknowledge a later command fork. */
    {
        int64_t fork_ready = process4cj_wait_status_owned180(fork_ready_pipe[0]);
        if (fork_ready != P4_OWNED_FORK_MAGIC180) {
            result = fork_ready < 0 ? (int)-fork_ready : EPROTO;
            goto owned_cleanup;
        }
        actual_fork_ready = 1;
        result = p4_owned_fd_close180(journal, fork_ready_pipe[0]); fork_ready_pipe[0] = -1;
        if (result != 0) goto owned_cleanup;
    }
    result = p4_owned_fd_close180(journal, error_pipe[1]); error_pipe[1] = -1;
    if (result != 0) goto owned_cleanup;
    unsigned char bytes[sizeof(int)]; size_t received = 0;
    for (;;) {
        unsigned char buffer[sizeof(int)];
        ssize_t count = read(error_pipe[0], buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { result = errno; break; }
        if (count == 0) break;
        if (received + (size_t)count > sizeof(bytes)) { result = EPROTO; break; }
        memcpy(bytes + received, buffer, (size_t)count); received += (size_t)count;
    }
    if (result == 0 && received != 0) {
        if (received != sizeof(bytes)) result = EPROTO;
        else { memcpy(&result, bytes, sizeof(result)); if (result == 0) result = EIO; }
    }
    {
        int close_error = p4_owned_fd_close180(journal, error_pipe[0]); error_pipe[0] = -1;
        if (result == 0 && close_error != 0) result = close_error;
    }
    if (result != 0) goto owned_cleanup;
    journal[6] = 1;
    {
        int unused[4] = {in_pipe[0], out_pipe[1], err_pipe[1], status_pipe[1]};
        for (int index = 0; index < 4; ++index) {
            int error = p4_owned_fd_close180(journal, unused[index]);
            if (result == 0 && error != 0) result = error;
        }
    }
    if (result != 0) goto owned_cleanup;
    *stdin_out = in_pipe[1]; *stdout_out = out_pipe[0]; *stderr_out = err_pipe[0]; *status_out = status_pipe[0];
    p4_owned_transfer180(journal, in_pipe[1]); p4_owned_transfer180(journal, out_pipe[0]);
    p4_owned_transfer180(journal, err_pipe[0]); p4_owned_transfer180(journal, status_pipe[0]);
    journal[3] = 0; journal[5] = 1;
    return 0;

owned_cleanup:
    journal[3] = result == 0 ? EIO : result;
    if (journal[1] > 0 && actual_fork_ready) {
        journal[8] = 1;
        /* Missing incarnation metadata is UNKNOWN. Never fall back to
         * killing the only subreaper and claiming its exit as all-tree ACK. */
        int signal_error = journal[2] > 0 ?
            process4cj_signal_owned_tree180(journal[1], journal[2], SIGKILL) : ENODATA;
        journal[9] = signal_error;
        if (signal_error == 0) (void)p4_owned_reap_after_echild180(journal, status_pipe[0]);
        else journal[11] = signal_error;
    }
    /* Unknown readiness is not child absence. Keep the exact registered
     * endpoints and root reachable/paid so an actual still-live subreaper
     * can reap; do not close its receipt reader or fabricate journal[7]. */
    if (journal[1] > 0 && !actual_fork_ready) journal[11] = ENODATA;
    if (journal[1] <= 0 || actual_fork_ready)
    for (int index = 0; index < (int)journal[12]; ++index) {
        if (journal[16 + index * 3 + 1] == 0 || journal[16 + index * 3 + 1] == 2)
            (void)p4_owned_fd_close180(journal, (int)journal[16 + index * 3]);
    }
    journal[5] = 1;
    return (int32_t)journal[3];
}

/* The owned Cj caller invokes this only after the whole native start/wrapper
 * helper returned with its original exception and BEFORE a waiter was spawned
 * or a platform was installed. The same registered journal remains reachable.
 * No FD with an ambiguous prior close is retried. */
int32_t process4cj_abort_unwrapped_owned180(int64_t *journal, int64_t words, int32_t status_fd) {
    if (journal == NULL || words != P4_OWNED_JOURNAL_WORDS180 || journal[0] != 180 ||
        journal[5] != 1 || journal[3] != 0 || journal[14] != 0) return EINVAL;
    journal[14] = 1;
    int result = 0;
    if (journal[1] > 0 && journal[7] != 1) {
        journal[8] = 1;
        int error = journal[2] > 0 ?
            process4cj_signal_owned_tree180(journal[1], journal[2], SIGKILL) : ENODATA;
        journal[9] = error;
        /* The preinstalled Cj carrier passes its EXACT original native
         * status output, not an FD inferred from journal ordering. A caller
         * can have closed stdio before spawn, so promoted journal entries
         * are not necessarily in the same order as the four transfers.
         * No waiter exists yet; this private reader owns both fixed records. */
        if (!error) error = p4_owned_reap_after_echild180(journal, status_fd);
        else journal[11] = error;
        if (error != 0) result = error;
    }
    for (int index = 0; index < (int)journal[12]; ++index) {
        if (journal[16 + index * 3 + 1] == 0 || journal[16 + index * 3 + 1] == 2) {
            int error = p4_owned_fd_close180(journal, (int)journal[16 + index * 3]);
            if (result == 0 && error != 0) result = error;
        }
    }
    journal[15] = 1;
    return result;
}
