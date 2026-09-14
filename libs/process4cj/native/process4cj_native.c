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
    uint64_t *start_time
);
static p4_process_target p4_capture_target(pid_t pid);
static int p4_capture_child_target(
    pid_t child_pid,
    pid_t process_pid,
    pid_t thread_pid,
    p4_process_target *target_out
);
static int p4_target_matches(const p4_process_target *target);
static int p4_signal_target(const p4_process_target *target, int signal_value);

static void p4_collect_descendants(
    pid_t pid,
    const p4_process_target *expected_target,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count,
    int depth
);
static void p4_collect_child_token(
    const char *token,
    pid_t process_pid,
    pid_t thread_pid,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count,
    int depth
) {
    if (token == NULL || token[0] == '\0' || *count >= capacity) return;
    pid_t child = 0;
    if (!p4_parse_pid_name(token, &child)) return;
    p4_process_target child_target;
    if (!p4_capture_child_target(
            child, process_pid, thread_pid, &child_target)) {
        return;
    }
    descendants[(*count)++] = child_target;
    p4_collect_descendants(
        child,
        &child_target,
        descendants,
        capacity,
        count,
        depth + 1
    );
}


static void p4_collect_children_from_thread(
    pid_t process_pid,
    pid_t thread_pid,
    p4_process_target *descendants,
    size_t capacity,
    size_t *count,
    int depth
) {
    if (process_pid <= 0 || thread_pid <= 0 || *count >= capacity) return;
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
    while (*count < capacity) {
        ssize_t bytes;
        do { bytes = read(fd, buffer, sizeof(buffer)); }
        while (bytes < 0 && errno == EINTR);
        if (bytes <= 0) break;
        for (ssize_t index = 0;
             index < bytes && *count < capacity;
             ++index) {
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
                        depth
                    );
                }
                token_length = 0;
                token_overflow = 0;
            }
        }
    }
    if (*count < capacity && (token_length > 0 || token_overflow)) {
        if (!token_overflow) {
            token[token_length] = '\0';
            p4_collect_child_token(
                token,
                process_pid,
                thread_pid,
                descendants,
                capacity,
                count,
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
    int depth
) {
    if (pid <= 0 || depth > 32 || *count >= capacity) return;
    if (expected_target != NULL && !p4_target_matches(expected_target)) return;
    char path[96];
    int length = snprintf(path, sizeof(path), "/proc/%ld/task", (long)pid);
    if (length <= 0 || (size_t)length >= sizeof(path)) return;
    DIR *tasks = opendir(path);
    if (tasks == NULL) return;
    struct dirent *entry;
    while (*count < capacity && (entry = readdir(tasks)) != NULL) {
        pid_t thread_pid = 0;
        if (!p4_parse_pid_name(entry->d_name, &thread_pid)) continue;
        p4_collect_children_from_thread(
            pid, thread_pid, descendants, capacity, count, depth
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
    p4_process_target descendants[P4_MAX_DESCENDANTS];
    size_t count = 0;
    p4_collect_descendants(
        pid,
        NULL,
        descendants,
        P4_MAX_DESCENDANTS,
        &count,
        0
    );
    int first_error = 0;
    for (size_t index = count; index > 0; --index) {
        int result = p4_signal_target(&descendants[index - 1], signal_value);
        if (result != 0 && first_error == 0) first_error = result;
    }
    int result = kill(-pid, signal_value);
    if (result < 0 && errno != ESRCH && first_error == 0) first_error = errno;
    result = p4_signal_one(pid, signal_value);
    if (result != 0 && first_error == 0) first_error = result;
    return (int32_t)first_error;
}

static int p4_read_process_stat(
    pid_t pid,
    pid_t *parent_pid,
    uint64_t *start_time
) {
    if (pid <= 0 || (parent_pid == NULL && start_time == NULL)) return 0;
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
    for (int field = 3; field <= 22; ++field) {
        while (*cursor == ' ') cursor++;
        if (*cursor == '\0' || *cursor == '\n') return 0;
        char *end = cursor;
        while (*end != '\0' && *end != ' ' && *end != '\n') end++;
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
    return parent_found && start_found;
}

static int p4_read_start_time(pid_t pid, uint64_t *start_time) {
    return p4_read_process_stat(pid, NULL, start_time);
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
    if (!p4_read_process_stat(child_pid, &parent_pid, &start_time) ||
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


/* Escalate using one process-tree snapshot.  A descendant can be reparented
 * after the leader receives SIGTERM, so recollecting from the root for the
 * forced pass would lose ownership of that descendant. */
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
    p4_process_target descendants[P4_MAX_DESCENDANTS];
    size_t count = 0;
    p4_collect_descendants(
        pid,
        &root,
        descendants,
        P4_MAX_DESCENDANTS,
        &count,
        0
    );
    if (!p4_target_matches(&root)) return ESRCH;
    int first_error = p4_signal_captured_tree(
        &root,
        descendants,
        count,
        SIGTERM
    );
    p4_wait_for_graceful_tree(
        &root,
        descendants,
        count,
        graceful_millis
    );
    int result = p4_signal_captured_tree(
        &root,
        descendants,
        count,
        SIGKILL
    );
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
