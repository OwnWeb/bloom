#include <sys/prctl.h>
#include <signal.h>
#include <unistd.h>

// gh can only receive its token through the environment. This constructor runs before gh's main
// function and closes same-uid /proc and ptrace inspection for the lifetime of the operation.
__attribute__((constructor)) static void bloom_credential_shield(void) {
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) != 0) {
        _exit(126);
    }
    // The root tracer resumes the rest of the reservation only after observing this stop.
    raise(SIGSTOP);
}
