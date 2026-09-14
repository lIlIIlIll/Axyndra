#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static void p4_close_if_open(int fd) {
    if (fd >= 0) {
        while (close(fd) < 0 && errno == EINTR) {}
    }
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
    int32_t *stderr_out
) {
    int in_pipe[2] = {-1, -1};
    int out_pipe[2] = {-1, -1};
    int err_pipe[2] = {-1, -1};
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
    if (new_session) {
#ifdef POSIX_SPAWN_SETSID
        if ((result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID)) != 0) goto cleanup;
#else
        result = ENOTSUP;
        goto cleanup;
#endif
    }
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

cleanup:
    if (attributes_ready) posix_spawnattr_destroy(&attributes);
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    p4_close_if_open(in_pipe[0]); p4_close_if_open(in_pipe[1]);
    p4_close_if_open(out_pipe[0]); p4_close_if_open(out_pipe[1]);
    p4_close_if_open(err_pipe[0]); p4_close_if_open(err_pipe[1]);
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
#define P4_MAX_DESCENDANTS 1024

static void p4_collect_descendants(
    pid_t pid,
    pid_t *descendants,
    size_t capacity,
    size_t *count,
    int depth
) {
    if (pid <= 0 || depth > 32 || *count >= capacity) return;
    char path[96];
    int length = snprintf(
        path, sizeof(path), "/proc/%ld/task/%ld/children",
        (long)pid, (long)pid
    );
    if (length <= 0 || (size_t)length >= sizeof(path)) return;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return;
    char buffer[4096];
    ssize_t bytes;
    do { bytes = read(fd, buffer, sizeof(buffer) - 1); }
    while (bytes < 0 && errno == EINTR);
    p4_close_if_open(fd);
    if (bytes <= 0) return;
    buffer[bytes] = '\0';
    size_t index = 0;
    while (index < (size_t)bytes && *count < capacity) {
        while (index < (size_t)bytes &&
               (buffer[index] == ' ' || buffer[index] == '\n' ||
                buffer[index] == '\t')) {
            index++;
        }
        if (index >= (size_t)bytes) break;
        pid_t child = 0;
        int digits = 0;
        while (index < (size_t)bytes && buffer[index] >= '0' &&
               buffer[index] <= '9') {
            child = (pid_t)(child * 10 + (buffer[index] - '0'));
            index++;
            digits++;
        }
        if (digits == 0 || child <= 0) {
            while (index < (size_t)bytes && buffer[index] != ' ') index++;
            continue;
        }
        descendants[(*count)++] = child;
        p4_collect_descendants(child, descendants, capacity, count, depth + 1);
    }
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
    pid_t descendants[P4_MAX_DESCENDANTS];
    size_t count = 0;
    p4_collect_descendants(pid, descendants, P4_MAX_DESCENDANTS, &count, 0);
    int first_error = 0;
    for (size_t index = count; index > 0; --index) {
        int result = p4_signal_one(descendants[index - 1], signal_value);
        if (result != 0 && first_error == 0) first_error = result;
    }
    int result = kill(-pid, signal_value);
    if (result < 0 && errno != ESRCH && first_error == 0) first_error = errno;
    result = p4_signal_one(pid, signal_value);
    if (result != 0 && first_error == 0) first_error = result;
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

/* POSIX rename preserves the destination when the operation fails. */
int32_t axyndra_workspace_replace(const char *source, const char *destination) {
    if (rename(source, destination) < 0) return -errno;
    return 0;
}
