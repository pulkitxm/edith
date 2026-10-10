#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern void edith_host_dispatch(void);

void edith_host_bootstrap_anchor(void) {}

__attribute__((constructor)) static void dispatch_host(void) {
    Dl_info image;
    char executable[PATH_MAX];
    char resolved_executable[PATH_MAX];
    char resolved_image[PATH_MAX];
    uint32_t length = sizeof(executable);
    if (dladdr(&edith_host_dispatch, &image) != 0
        && _NSGetExecutablePath(executable, &length) == 0
        && realpath(executable, resolved_executable) != NULL
        && realpath(image.dli_fname, resolved_image) != NULL
        && strcmp(resolved_executable, resolved_image) == 0) {
        edith_host_dispatch();
    }
}
