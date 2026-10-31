/*
 * NanoCode host app — loads the embedded CoreCompiler.framework and drives
 * a Swift compilation in-process (no fork/exec).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <unistd.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>

static char *url_to_cstr(CFURLRef u) {
    if (!u) return strdup("(null)");
    char buf[4096];
    if (!CFURLGetFileSystemRepresentation(u, true, (UInt8*)buf, sizeof(buf)))
        return strdup("(unrepresentable)");
    return strdup(buf);
}

static FILE *g_log = NULL;

static void log_open(void) {
    if (g_log) return;
    const char *p = "/private/var/mobile/Documents/nanocode.log";
    g_log = fopen(p, "w");
    if (!g_log) g_log = stderr;
}

static void logf_(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(g_log ? g_log : stderr, fmt, ap);
    fputc('\n', g_log ? g_log : stderr);
    fflush(g_log ? g_log : stderr);
    va_end(ap);
}

static char *bundle_path(const char *rel) {
    char buf[4096];
    uint32_t n = (uint32_t)sizeof(buf);
    if (_NSGetExecutablePath(buf, &n) != 0) return NULL;
    char *slash = strrchr(buf, '/');
    if (!slash) return NULL;
    *slash = 0;
    char *out = malloc(strlen(buf) + strlen(rel) + 2);
    sprintf(out, "%s/%s", buf, rel);
    return out;
}

typedef struct __CCDriver *CCDriverRef;
typedef struct __CCSDK *CCSDKRef;
typedef CFTypeID (*fn_typeid)(void);
typedef void (*fn_bridge_classes)(CFTypeID, const char *);
typedef struct __CCJob *CCJobRef;

typedef CCDriverRef (*fn_driver_create)(CFAllocatorRef, CFArrayRef, uint8_t);
typedef CFArrayRef (*fn_driver_jobs)(CFAllocatorRef, CCDriverRef);
typedef Boolean (*fn_job_exec)(CCJobRef, CFArrayRef *, CFStringRef *);
typedef CFTypeID (*fn_sdk_typeid)(void);
typedef CCSDKRef (*fn_sdk_create)(CFAllocatorRef, CFURLRef);
typedef CFURLRef (*fn_driver_sdk)(CCDriverRef);
typedef CFURLRef (*fn_driver_sysroot)(CCDriverRef);

static CFArrayRef make_args(const char *const *argv, int argc) {
    const void **values = (const void **)calloc((size_t)argc, sizeof(void *));
    if (!values) return NULL;
    for (int i = 0; i < argc; i++) {
        values[i] = CFStringCreateWithCString(kCFAllocatorSystemDefault, argv[i], kCFStringEncodingUTF8);
        if (!values[i]) {
            for (int j = 0; j < i; j++) CFRelease(values[j]);
            free(values);
            return NULL;
        }
    }
    CFArrayRef a = CFArrayCreate(kCFAllocatorSystemDefault, values, argc, &kCFTypeArrayCallBacks);
    for (int i = 0; i < argc; i++) CFRelease(values[i]);
    free(values);
    return a;
}

int main(int argc, char **argv) {
    log_open();
    logf_("[nanocode] start argc=%d", argc);
    const char *fw = "Frameworks/CoreCompiler.framework/CoreCompiler";
    char *p = bundle_path(fw);
    logf_("[nanocode] loading %s", p);
    void *h = dlopen(p, RTLD_NOW);
    if (!h) { logf_("[nanocode] dlopen failed: %s", dlerror()); return 1; }
    logf_("[nanocode] dlopen OK");

    fn_driver_create driver_create = (fn_driver_create)dlsym(h, "CCDriverCreate");
    /* Diagnostic: locate the crashing allocation. */
    fprintf(stderr, "[nanocode] typeid(driver)=%lu\n",
            (unsigned long)((fn_typeid)dlsym(h, "CCDriverGetTypeID"))());
    fflush(stderr);
    fprintf(stderr, "[nanocode] typeid(job)=%lu\n",
            (unsigned long)((fn_typeid)dlsym(h, "CCJobGetTypeID"))());
    fflush(stderr);
    fn_driver_jobs   driver_jobs   = (fn_driver_jobs)dlsym(h, "CCDriverCreateJobs");
    fn_job_exec      job_exec      = (fn_job_exec)dlsym(h, "CCJobExecuteJob");
    fn_sdk_typeid    sdk_typeid    = (fn_sdk_typeid)dlsym(h, "CCSDKGetTypeID");
    fn_sdk_create    sdk_create    = (fn_sdk_create)dlsym(h, "CCSDKCreateWithDirectoryURL");
    fn_driver_sdk    driver_sdk    = (fn_driver_sdk)dlsym(h, "CCDriverCopySDK");
    fn_driver_sysroot driver_sysroot= (fn_driver_sysroot)dlsym(h, "CCDriverCopySysrootURL");

    logf_("[nanocode] syms: create=%p jobs=%p exec=%p sdk_create=%p sdk=%p sysroot=%p",
          (void*)driver_create,(void*)driver_jobs,(void*)job_exec,
          (void*)sdk_create,(void*)driver_sdk,(void*)driver_sysroot);
    if (!driver_create || !driver_jobs || !job_exec) {
        logf_("[nanocode] missing required symbols");
        return 2;
    }

    /* Defaults use the on-device SDK and an input bundled with this app. */
    char *bundled_src = bundle_path("hello.swift");
    const char *src = argc > 1 ? argv[1] : bundled_src;
    const char *out = argc > 2 ? argv[2] : "/private/var/mobile/Documents/hello.o";
    const char *sdk = argc > 3 ? argv[3] : "/private/var/mobile/Documents/nyxian/iPhoneOS26.5.sdk";
    const char *res = argc > 4 ? argv[4] : "/private/var/mobile/Documents/nyxian/Shared/swift";

    /* CCDriverCreate prepends swiftc internally; do not pass argv[0] here. */
    const char *ccargs[24];
    int n = 0;
    ccargs[n++] = "-target";
    ccargs[n++] = "arm64e-apple-ios26.5";
    if (sdk) { ccargs[n++] = "-sdk"; ccargs[n++] = sdk; }
    if (res) { ccargs[n++] = "-resource-dir"; ccargs[n++] = res; }
    ccargs[n++] = "-c";
    ccargs[n++] = src;
    ccargs[n++] = "-o";
    ccargs[n++] = out;

    CFArrayRef args = make_args(ccargs, n);
    logf_("[nanocode] CCDriverCreate(type=swift)");
    CCDriverRef drv = driver_create(kCFAllocatorSystemDefault, args, 1 /* kCCDriverTypeSwift */);
    if (!drv) { logf_("[nanocode] driver create failed"); return 3; }
    /* Build the Swift job directly; CCDriverCreateJobs crashes on this build. */
    CFArrayRef jobs = NULL;
    {
        typedef CCJobRef (*fn_job_create)(CFAllocatorRef, uint8_t, CFArrayRef, CFArrayRef, CFURLRef);
        fn_job_create job_create = (fn_job_create)dlsym(h, "CCJobCreate");
        fprintf(stderr, "[nanocode] CCJobCreate=%p\n", (void *)job_create);
        CFURLRef srcURL = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorSystemDefault, (const UInt8 *)src, strlen(src), false);
        CFArrayRef ins = CFArrayCreate(NULL, (const void **)&srcURL, 1, &kCFTypeArrayCallBacks);
        CFURLRef outURL = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorSystemDefault, (const UInt8 *)out, strlen(out), false);
        CFMutableArrayRef base = CFArrayCreateMutable(kCFAllocatorSystemDefault, 16, &kCFTypeArrayCallBacks);
        for (int i = 0; i < n; i++) {
            CFStringRef s = CFStringCreateWithCString(kCFAllocatorSystemDefault, ccargs[i], kCFStringEncodingUTF8);
            CFArrayAppendValue(base, s);
            CFRelease(s);
        }
        CFArrayRef one = CFArrayCreate(NULL, (const void **)&job_create, 0, NULL);
        (void)one;
        CFArrayRef arr = CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
        (void)arr;
        CCJobRef job = job_create ? job_create(kCFAllocatorSystemDefault, 2 /* kCCJobTypeSwiftCompiler */,
                                               base, ins, outURL) : NULL;
        CFArrayRef jobsArr = job ? CFArrayCreate(kCFAllocatorSystemDefault, (const void **)&job, 1, &kCFTypeArrayCallBacks) : NULL;
        jobs = jobsArr;
        CFRelease(base);
        CFRelease(ins);
        CFRelease(srcURL);
        CFRelease(outURL);
        if (job) CFRelease(job);
    }
    if (!jobs) { logf_("[nanocode] driver_jobs failed"); return 4; }
    logf_("[nanocode] %zu job(s)", (size_t)CFArrayGetCount(jobs));

    for (CFIndex i = 0; i < CFArrayGetCount(jobs); i++) {
        CCJobRef job = (CCJobRef)CFArrayGetValueAtIndex(jobs, i);
        CFArrayRef diags = NULL;
        CFStringRef mainSrc = NULL;
        Boolean ok = job_exec(job, &diags, &mainSrc);
        logf_("[nanocode] job %ld -> %s", (long)i, ok ? "OK" : "FAILED");
        if (diags) {
            CFIndex c = CFArrayGetCount(diags);
            for (CFIndex j = 0; j < c; j++) {
                CFTypeRef d = CFArrayGetValueAtIndex(diags, j);
                CFStringRef ds = CFGetTypeID(d) == CFStringGetTypeID() ? (CFStringRef)d : NULL;
                if (ds) {
                    char buf[4096];
                    if (CFStringGetCString(ds, buf, sizeof(buf), kCFStringEncodingUTF8))
                        logf_("  diag: %s", buf);
                } else {
                    logf_("  diag: (non-string type %ld)", (long)CFGetTypeID(d));
                }
            }
        }
        if (!ok) return 5;
    }

    /* ================= 阶段二：进程内链接 ================= */
    /* 关掉编译专用的参数，换成链接器参数；同一个 CoreCompiler 直接出可执行文件。
     * 这一步替代了此前「iSH 里跑 ld64.lld」的整段外部流程。 */
    logf_("[nanocode] === link stage ===");
    {
        typedef CCJobRef (*fn_job_create)(CFAllocatorRef, uint8_t, CFArrayRef, CFArrayRef, CFURLRef);
        typedef Boolean (*fn_link_exec)(CCJobRef, CFArrayRef *);
        fn_job_create job_create = (fn_job_create)dlsym(h, "CCJobCreate");
        fn_link_exec link_exec = (fn_link_exec)dlsym(h, "CCLinkerJobExecute");
        logf_("[nanocode] CCJobCreate=%p CCLinkerJobExecute=%p",
              (void *)job_create, (void *)link_exec);
        if (!job_create || !link_exec) { logf_("[nanocode] linker unavailable"); return 6; }

        char exe[1024];
        snprintf(exe, sizeof exe, "%s.bin", out);
        char syslib[1024], swiftlib[1024];
        snprintf(swiftlib, sizeof swiftlib, "%s/usr/lib/swift", sdk);
        snprintf(syslib, sizeof syslib, "%s/usr/lib", sdk);

        const char *largs[40];
        int ln = 0;
        largs[ln++] = "-arch";           largs[ln++] = "arm64";
        largs[ln++] = "-platform_version"; largs[ln++] = "ios";
        largs[ln++] = "17.0";            largs[ln++] = "26.5";
        largs[ln++] = "-syslibroot";     largs[ln++] = sdk;
        largs[ln++] = "-L";              largs[ln++] = swiftlib;
        largs[ln++] = "-L";              largs[ln++] = syslib;
        largs[ln++] = "-lswiftCore";
        largs[ln++] = "-lswiftFoundation";
        largs[ln++] = "-framework";      largs[ln++] = "UIKit";
        largs[ln++] = "-framework";      largs[ln++] = "Foundation";

        CFMutableArrayRef larr = CFArrayCreateMutable(kCFAllocatorSystemDefault, 32, &kCFTypeArrayCallBacks);
        for (int i = 0; i < ln; i++) {
            CFStringRef s = CFStringCreateWithCString(kCFAllocatorSystemDefault, largs[i], kCFStringEncodingUTF8);
            CFArrayAppendValue(larr, s); CFRelease(s);
        }
        CFURLRef objURL = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorSystemDefault, (const UInt8 *)out, strlen(out), false);
        CFURLRef exeURL = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorSystemDefault, (const UInt8 *)exe, strlen(exe), false);
        CFArrayRef ins = CFArrayCreate(NULL, (const void **)&objURL, 1, &kCFTypeArrayCallBacks);

        /* kCCJobTypeLinker == 4（见 Support/CCJob.h 枚举顺序） */
        CCJobRef ljob = job_create(kCFAllocatorSystemDefault, 4, larr, ins, exeURL);
        logf_("[nanocode] link job=%p target=%s", (void *)ljob, exe);
        if (!ljob) { logf_("[nanocode] link job create failed"); return 7; }

        CFArrayRef ldiags = NULL;
        Boolean lok = link_exec(ljob, &ldiags);
        logf_("[nanocode] link -> %s", lok ? "OK" : "FAILED");
        if (ldiags) {
            CFIndex c = CFArrayGetCount(ldiags);
            for (CFIndex j = 0; j < c; j++) {
                CFTypeRef d = CFArrayGetValueAtIndex(ldiags, j);
                if (CFGetTypeID(d) == CFStringGetTypeID()) {
                    char buf[2048];
                    if (CFStringGetCString((CFStringRef)d, buf, sizeof buf, kCFStringEncodingUTF8))
                        logf_("  ldiag: %s", buf);
                }
            }
        }
        CFRelease(larr); CFRelease(objURL); CFRelease(exeURL); CFRelease(ins);
        CFRelease(ljob);
        if (!lok) return 8;
    }

    logf_("[nanocode] DONE");
    return 0;
}
