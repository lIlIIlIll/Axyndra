#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>

int32_t cjtui_terminal_begin(int32_t modes);
int32_t cjtui_terminal_end(void);
static void previous_handler(int signal_number, siginfo_t *info, void *context)
{
    (void)signal_number;
    (void)info;
    (void)context;
}

int main(void)
{
    const int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT};
    struct sigaction expected[4];
    struct sigaction custom = {0};
    custom.sa_sigaction = previous_handler;
    custom.sa_flags = SA_SIGINFO | SA_RESTART;
    assert(sigemptyset(&custom.sa_mask) == 0);
    assert(sigaddset(&custom.sa_mask, SIGUSR1) == 0);
    for (unsigned int index = 0; index < 4; index++) {
        assert(sigaction(signals[index], &custom, NULL) == 0);
        assert(sigaction(signals[index], NULL, &expected[index]) == 0);
    }
    for (unsigned int cycle = 0; cycle < 3; cycle++) {
        assert(cjtui_terminal_begin(0) == 0);
        assert(cjtui_terminal_begin(256) == EBUSY);
        assert(cjtui_terminal_end() == 0);
        assert(cjtui_terminal_end() == 0);
        for (unsigned int index = 0; index < 4; index++) {
            struct sigaction restored;
            assert(sigaction(signals[index], NULL, &restored) == 0);
            assert(restored.sa_sigaction == expected[index].sa_sigaction);
            assert(restored.sa_flags == expected[index].sa_flags);
            for (int signal_number = 1; signal_number < 32; signal_number++) {
                assert(sigismember(&restored.sa_mask, signal_number) ==
                       sigismember(&expected[index].sa_mask, signal_number));
            }
        }
    }
    puts("PASS original sigaction handler, flags and mask; repeated normal end");
    return 0;
}
