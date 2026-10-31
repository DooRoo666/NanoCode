// 探测：能否在 app 进程内 dlopen CoreCompiler
#include <stdio.h>
#include <dlfcn.h>

int main(void) {
    FILE *f = fopen("/var/mobile/Documents/_probe_result.txt", "w");
    if (!f) return 1;

    const char *paths[] = {
        "/var/mobile/Documents/nyxian/CoreCompiler.framework/CoreCompiler",
        "/private/var/mobile/Documents/nyxian/CoreCompiler.framework/CoreCompiler",
        NULL
    };

    for (int i = 0; paths[i]; i++) {
        fprintf(f, "--- try: %s\n", paths[i]);
        void *h = dlopen(paths[i], RTLD_NOW);
        if (!h) {
            fprintf(f, "    FAIL: %s\n", dlerror());
            continue;
        }
        fprintf(f, "    OK  handle=%p\n", h);
        fprintf(f, "    CCLinkerJobExecute = %p\n", dlsym(h, "CCLinkerJobExecute"));
        fprintf(f, "    CCJobCreate        = %p\n", dlsym(h, "CCJobCreate"));
        fprintf(f, "    CCDriverCreateJobs = %p\n", dlsym(h, "CCDriverCreateJobs"));
        fprintf(f, "    CCDriverCreate     = %p\n", dlsym(h, "CCDriverCreate"));
        dlclose(h);
        break;
    }
    fclose(f);
    return 0;
}
