#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <sys/types.h>
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

int64_t process4cj_wait(int64_t pid_value) {
    int status = 0;
    pid_t result;
    do { result = waitpid((pid_t)pid_value, &status, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return -(int64_t)errno;
    if (WIFEXITED(status)) return (int64_t)WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return (int64_t)(128 + WTERMSIG(status));
    return 255;
}

int32_t process4cj_kill(int64_t pid_value, int32_t force, int32_t process_group) {
    pid_t target = process_group ? -(pid_t)pid_value : (pid_t)pid_value;
    if (kill(target, force ? SIGKILL : SIGTERM) == 0 || errno == ESRCH) return 0;
    return (int32_t)errno;
}

int32_t process4cj_is_alive(int64_t pid_value) {
    if (kill((pid_t)pid_value, 0) == 0 || errno == EPERM) return 1;
    return 0;
}
