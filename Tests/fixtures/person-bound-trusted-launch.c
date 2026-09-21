#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int read_file(const char *path, char *buffer, size_t size) {
    int descriptor = open(path, O_RDONLY);
    if (descriptor < 0) return -errno;
    ssize_t count = read(descriptor, buffer, size - 1);
    close(descriptor);
    if (count < 0) return -errno;
    buffer[count] = '\0';
    return (int)count;
}

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    pid_t wrapper = fork();
    if (wrapper < 0) return 2;
    if (wrapper == 0) {
        execl(argv[1], argv[1], "gh-v2", "pr", "view", "1", NULL);
        _exit(127);
    }
    pid_t watcher = fork();
    if (watcher < 0) return 3;
    if (watcher == 0) {
        char path[64];
        char buffer[8192];
        for (int attempt = 0; attempt < 5000; attempt++) {
            snprintf(path, sizeof(path), "/proc/%d/cmdline", wrapper);
            int command_count = read_file(path, buffer, sizeof(buffer));
            if (command_count < 0) _exit(command_count == -ENOENT ? 5 : 6);
            if (memmem(buffer, (size_t)command_count, "/usr/bin/gh", sizeof("/usr/bin/gh") - 1) != NULL) {
                snprintf(path, sizeof(path), "/proc/%d/environ", wrapper);
                int environment_count = read_file(path, buffer, sizeof(buffer));
                if (environment_count == -EACCES) _exit(0);
                if (environment_count >= 0) _exit(7);
                _exit(8);
            }
            usleep(1000);
        }
        _exit(9);
    }
    int wrapper_status = 0;
    int watcher_status = 0;
    if (waitpid(wrapper, &wrapper_status, 0) != wrapper) return 4;
    if (waitpid(watcher, &watcher_status, 0) != watcher) return 5;
    if (!WIFEXITED(wrapper_status) || WEXITSTATUS(wrapper_status) != 0) return 10;
    if (!WIFEXITED(watcher_status) || WEXITSTATUS(watcher_status) != 0) return 20 + WEXITSTATUS(watcher_status);
    return 0;
}
