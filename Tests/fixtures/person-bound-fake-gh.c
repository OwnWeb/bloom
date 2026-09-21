#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

int main(void) {
    const char *host = getenv("GH_HOST");
    const char *token = getenv("GH_TOKEN");
    if (host == NULL || strcmp(host, "github.com") != 0 ||
        token == NULL || strcmp(token, "raw-token-used-once") != 0) {
        return 1;
    }
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        char path[64];
        snprintf(path, sizeof(path), "/proc/%d/environ", getppid());
        int descriptor = open(path, O_RDONLY);
        if (descriptor >= 0) {
            close(descriptor);
            _exit(3);
        }
        _exit(errno == EACCES ? 0 : 4);
    }
    int status = 0;
    return waitpid(child, &status, 0) == child && WIFEXITED(status) ? WEXITSTATUS(status) : 5;
}
