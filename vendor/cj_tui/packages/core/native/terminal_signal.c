#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdint.h>
#include <termios.h>
#include <unistd.h>

/* This process-wide guard follows TerminalSession's single terminal ownership.
 * All storage is native, and saved_termios is immutable while handlers exist.
 * Lock-free scalar publication also covers signals on a different runtime thread.
 */
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "terminal modes must be signal-safe");
enum {
    ALTERNATE = 1, MOUSE = 2, MOUSE_MOVE = 4, FOCUS = 8,
    PASTE = 16, CURSOR_HIDDEN = 32, MODIFY_KEYS = 64, KITTY_KEYS = 128,
    RAW = 256
};
static const int terminal_signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};
static struct sigaction previous_actions[4];
static struct termios saved_termios;
static int saved_termios_valid;
static unsigned int installed_count;
static atomic_uint modes;
static atomic_uint owned;

static void write_sequence(const char *bytes, size_t length)
{
    while (length != 0) {
        ssize_t count = write(STDOUT_FILENO, bytes, length);
        if (count > 0) {
            bytes += count;
            length -= (size_t)count;
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}
#define RESTORE(sequence) write_sequence(sequence, sizeof(sequence) - 1)

/* Only POSIX async-signal-safe functions and lock-free atomics occur here.
 * In particular, there is no @C Cangjie thunk, allocation, stdio or managed data.
 * Retain the observable TerminalSession contract: cleanup then 128 + signal.
 */
static void terminal_signal_handler(int signum)
{
    unsigned int enabled = atomic_load_explicit(&modes, memory_order_acquire);
    if (enabled & KITTY_KEYS) RESTORE("\033[<1u");
    if (enabled & MODIFY_KEYS) RESTORE("\033[>4;0m");
    if (enabled & PASTE) RESTORE("\033[?2004l");
    if (enabled & FOCUS) RESTORE("\033[?1004l");
    if (enabled & MOUSE_MOVE) RESTORE("\033[?1003l\033[?1006l");
    if (enabled & MOUSE) RESTORE("\033[?1006l\033[?1000l");
    if (enabled & CURSOR_HIDDEN) RESTORE("\033[?25h");
    if (enabled & ALTERNATE) RESTORE("\033[?1049l");
    if ((enabled & RAW) && saved_termios_valid) {
        while (tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved_termios) < 0 && errno == EINTR) {}
    }
    _exit(128 + signum);
}

int32_t cjtui_terminal_end(void)
{
    int error = 0;
    /* Keep cleanup modes published until all original dispositions are restored.
     * A signal racing normal close can still safely repeat native restoration.
     */
    while (installed_count != 0) {
        unsigned int index = installed_count - 1;
        if (sigaction(terminal_signals[index], &previous_actions[index], NULL) != 0) {
            error = errno;
            break;
        }
        installed_count--;
    }
    if (installed_count == 0) {
        atomic_store_explicit(&modes, 0, memory_order_release);
        atomic_store_explicit(&owned, 0, memory_order_release);
    }
    return error;
}

int32_t cjtui_terminal_begin(int32_t enabled)
{
    unsigned int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&owned, &expected, 1,
            memory_order_acq_rel, memory_order_acquire)) return EBUSY;
    /* Called before raw mode, never after it. No managed pointer is retained. */
    saved_termios_valid = 0;
    if ((enabled & RAW) && isatty(STDIN_FILENO)) {
        if (tcgetattr(STDIN_FILENO, &saved_termios) != 0) goto failed_before_install;
        saved_termios_valid = 1;
    }
    struct sigaction action = {0};
    action.sa_handler = terminal_signal_handler;
    if (sigemptyset(&action.sa_mask) != 0) goto failed_before_install;
    for (unsigned int index = 0; index < 4; index++) {
        if (sigaddset(&action.sa_mask, terminal_signals[index]) != 0) goto failed_before_install;
        if (sigaction(terminal_signals[index], NULL, &previous_actions[index]) != 0) goto failed_before_install;
    }
    atomic_store_explicit(&modes, (unsigned int)enabled, memory_order_release);
    for (unsigned int index = 0; index < 4; index++) {
        if (sigaction(terminal_signals[index], &action, NULL) != 0) {
            int error = errno;
            (void)cjtui_terminal_end();
            return error;
        }
        installed_count++;
    }
    return 0;

    failed_before_install: {
        int error = errno;
        atomic_store_explicit(&owned, 0, memory_order_release);
        return error;
    }
}

void cjtui_terminal_modes(int32_t enabled)
{
    if (atomic_load_explicit(&owned, memory_order_acquire) != 0) {
        atomic_store_explicit(&modes, (unsigned int)enabled, memory_order_release);
    }
}
