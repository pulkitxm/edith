#include "RendererAudit.h"
#include <dlfcn.h>
#include <errno.h>
#include <spawn.h>
#include <stdatomic.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static atomic_bool auditing;
static atomic_uint process_calls;
static atomic_uint pty_calls;

pid_t fork(void) {
    if (atomic_load(&auditing)) {
        atomic_fetch_add(&process_calls, 1);
        errno = EPERM;
        return -1;
    }
    pid_t (*original)(void) = dlsym(RTLD_NEXT, "fork");
    return original();
}

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                         const posix_spawnattr_t *attributes, char *const argv[], char *const env[]) {
    if (atomic_load(&auditing)) {
        atomic_fetch_add(&process_calls, 1);
        return EPERM;
    }
    int (*original)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                    const posix_spawnattr_t *, char *const[], char *const[]) = dlsym(RTLD_NEXT, "posix_spawn");
    return original(pid, path, actions, attributes, argv, env);
}

int posix_spawnp(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                          const posix_spawnattr_t *attributes, char *const argv[], char *const env[]) {
    if (atomic_load(&auditing)) {
        atomic_fetch_add(&process_calls, 1);
        return EPERM;
    }
    int (*original)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                    const posix_spawnattr_t *, char *const[], char *const[]) = dlsym(RTLD_NEXT, "posix_spawnp");
    return original(pid, path, actions, attributes, argv, env);
}

int openpty(int *master, int *slave, char *name, struct termios *attributes,
                           struct winsize *size) {
    if (atomic_load(&auditing)) {
        atomic_fetch_add(&pty_calls, 1);
        errno = EPERM;
        return -1;
    }
    int (*original)(int *, int *, char *, struct termios *, struct winsize *) = dlsym(RTLD_NEXT, "openpty");
    return original(master, slave, name, attributes, size);
}

void renderer_audit_begin(void) {
    atomic_store(&process_calls, 0);
    atomic_store(&pty_calls, 0);
    atomic_store(&auditing, true);
}

void renderer_audit_end(void) {
    atomic_store(&auditing, false);
}

uint32_t renderer_audit_process_calls(void) { return atomic_load(&process_calls); }
uint32_t renderer_audit_pty_calls(void) { return atomic_load(&pty_calls); }

bool renderer_audit_probe(void) {
    renderer_audit_begin();
    pid_t process = fork();
    if (process == 0) _exit(99);
    if (process > 0) waitpid(process, NULL, 0);
    int master = -1;
    int slave = -1;
    int opened = openpty(&master, &slave, NULL, NULL, NULL);
    if (master >= 0) close(master);
    if (slave >= 0) close(slave);
    bool passed = process == -1 && opened == -1 && renderer_audit_process_calls() == 1 && renderer_audit_pty_calls() == 1;
    renderer_audit_end();
    return passed;
}
