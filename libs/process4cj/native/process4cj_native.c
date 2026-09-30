#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <dirent.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <limits.h>
#include <sys/prctl.h>

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
    int error_write
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
    int error_write
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
        error_write
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
            error_write
        );
        _exit(127);
    }
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
    pid_t *pid_out
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
            error_pipe[1]
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

int32_t process4cj_spawn(
    const char *executable,
    char *const argv[],
    char *const envp[],
    const char *working_directory,
    int32_t new_session,
    int64_t *pid_out,
    int32_t *stdin_out,
    int32_t *stdout_out,
    int32_t *stderr_out,
    int32_t *status_out
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
            &pid
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
    char buffer[65536];
    *copied_bytes = 0;
    for (;;) {
        ssize_t count;
        do { count = read(source_fd, buffer, sizeof(buffer)); }
        while (count < 0 && errno == EINTR);
        if (count < 0) return -errno;
        if (count == 0) return 0;
        if ((int64_t)count > max_bytes - *copied_bytes) return -EFBIG;
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written;
            do {
                written = write(destination_fd, buffer + offset, (size_t)(count - offset));
            } while (written < 0 && errno == EINTR);
            if (written < 0) return -errno;
            if (written == 0) return -EIO;
            offset += written;
        }
        *copied_bytes += count;
    }
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
