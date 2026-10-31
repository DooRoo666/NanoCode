/*
 * link_test.c — 验证 CoreCompiler 内置链接器（CCLinkerJobExecute）
 *
 * 核心思路：CoreCompiler 是一个完整 driver，CCDriverCreateJobs 会按参数
 * 自动分派 job 类型（CCJobTypeCompiler / SwiftCompiler / Linker）。
 * 所以不需要直接调 CCLinkerJobExecute —— 只要喂链接参数即可。
 *
 * 编译：clang -arch arm64e -isysroot <sdk> -framework CoreFoundation
 * 链接：-framework CoreFoundation，dlopen CoreCompiler
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>
#include <fcntl.h>

typedef struct __CCDriver *CCDriverRef;
typedef struct __CCJob    *CCJobRef;

static void lg(const char *fmt, ...) {
    va_list a; va_start(a, fmt);
    vfprintf(stderr, fmt, a);
    va_end(a); fflush(stderr);
}

/* ===== 清零 allocator（与 stage2.c 同款，必须：_CFRuntimeCreateInstance
 *       分配出的 C++ 对象若不先清零，未初始化成员会导致崩溃） ===== */
static const void *zRetain(const void *i) { return i; }
static void  zRelease(const void *i) {}
static CFStringRef zDesc(const void *i) { return CFSTR("ZeroAlloc"); }
static void *zAlloc(CFIndex sz, CFOptionFlags h, void *i) { return calloc(1, (size_t)sz); }
static void *zRealloc(void *p, CFIndex n, CFOptionFlags h, void *i) { return realloc(p, (size_t)n); }
static void  zFree(void *p, void *i) { free(p); }
static CFIndex zPref(CFIndex sz, CFOptionFlags h, void *i) { return sz; }

static CFAllocatorRef g_zeroAlloc = NULL;
static void makeZeroAllocator(void) {
    if (g_zeroAlloc) return;
    CFAllocatorContext ctx; memset(&ctx, 0, sizeof ctx);
    ctx.version = 0;
    ctx.retain = zRetain; ctx.release = zRelease; ctx.copyDescription = zDesc;
    ctx.allocate = zAlloc; ctx.reallocate = zRealloc;
    ctx.deallocate = zFree; ctx.preferredSize = zPref;
    g_zeroAlloc = CFAllocatorCreate(kCFAllocatorSystemDefault, &ctx);
}

int main(int argc, char **argv) {
    // argv: <corecompiler.dylib> <sdk> <.o 输入...> -o <out>
    if (argc < 4) { fprintf(stderr, "usage: %s <CC.dylib> <sdk> <in.o> -o <out>\n", argv[0]); return 2; }

    const char *compilerPath = argv[1];
    const char *sdkPath      = argv[2];

    void *h = dlopen(compilerPath, RTLD_NOW);
    if (!h) { lg("[lk] dlopen FAIL %s\n", dlerror()); return 1; }
    lg("[lk] dlopen ok\n");

    /* ---- 1. 探测链接器符号是否真实导出 ---- */
    void *pLinkerExec = dlsym(h, "CCLinkerJobExecute");
    void *pJobType    = dlsym(h, "CCJobTypeLinker");
    lg("[lk] CCLinkerJobExecute = %p\n", pLinkerExec);
    lg("[lk] CCJobTypeLinker    = %p\n", pJobType);

    /* ---- 2. driver 符号 ---- */
    CCDriverRef (*pDriverCreate)(CFAllocatorRef, CFArrayRef, int) = dlsym(h, "CCDriverCreate");
    CFArrayRef  (*pCreateJobs)(CCDriverRef, CFAllocatorRef)       = dlsym(h, "CCDriverCreateJobs");
    Boolean     (*pExecuteJob)(CCJobRef, CFArrayRef*, CFStringRef*) = dlsym(h, "CCJobExecuteJob");
    int         (*pJobGetType)(CCJobRef)                           = dlsym(h, "CCJobGetType");
    lg("[lk] driver syms: create=%p jobs=%p exec=%p getType=%p\n",
       (void*)pDriverCreate, (void*)pCreateJobs, (void*)pExecuteJob, (void*)pJobGetType);
    if (!pDriverCreate || !pCreateJobs || !pExecuteJob) { lg("[lk] missing driver syms\n"); return 1; }
    if (!pLinkerExec) { lg("[lk] ^^^ 链接器符号未导出，需外部 ld64.lld ^^^\n"); return 2; }

    /* ---- 3. CF 桥接（与 stage2.c 一致，必须） ---- */
    CFTypeID (*pDriverTypeID)(void) = dlsym(h, "CCDriverGetTypeID");
    void (*pBridge)(CFTypeRef, const char*) = dlsym(RTLD_DEFAULT, "_CFRuntimeBridgeClasses");
    if (pDriverTypeID) { lg("[lk] driverTypeID=%lu\n", (unsigned long)pDriverTypeID()); }

    /* ---- 4. 用 zero allocator 规避未初始化 C++ 成员问题 ---- */
    makeZeroAllocator();
    if (!g_zeroAlloc) { lg("[lk] no zero allocator\n"); return 1; }

    /* ---- 5. 组装链接参数（swiftc 风格） ---- */
    CFMutableArrayRef args = CFArrayCreateMutable(kCFAllocatorSystemDefault, 0, &kCFTypeArrayCallBacks);

    char sdkArg[512], outArg[512];
    snprintf(sdkArg, sizeof sdkArg, "%s", sdkPath);
    snprintf(outArg,  sizeof outArg,  "%s", argv[argc-1]); /* 约定最后一个参数是 -o 的输出 */

    const char *head[] = { "-target", "arm64-apple-ios26.5", "-sdk", sdkArg, "-o", outArg, NULL };
    for (int i = 0; head[i]; i++) {
        CFStringRef s = CFStringCreateWithCString(NULL, head[i], kCFStringEncodingUTF8);
        CFArrayAppendValue(args, s); CFRelease(s);
    }
    /* 追加所有非选项的输入文件（原样传入，由 driver 解释） */
    for (int i = 3; i < argc - 1; i++) {
        CFStringRef s = CFStringCreateWithCString(NULL, argv[i], kCFStringEncodingUTF8);
        CFArrayAppendValue(args, s); CFRelease(s);
        lg("[lk]   input[%d]=%s\n", i, argv[i]);
    }

    lg("[lk] creating driver ...\n");
    CCDriverRef drv = pDriverCreate(g_zeroAlloc, args, 1 /*kCCDriverTypeSwift*/);
    lg("[lk] driver=%p\n", (void*)drv);
    if (!drv) return 1;

    lg("[lk] createJobs ...\n");
    CFArrayRef jobs = pCreateJobs(drv, g_zeroAlloc);
    if (!jobs) { lg("[lk] jobs NULL\n"); return 1; }
    CFIndex n = CFArrayGetCount(jobs);
    lg("[lk] jobs=%ld\n", (long)n);

    int rc = 0;
    for (CFIndex i = 0; i < n; i++) {
        CCJobRef j = (CCJobRef)CFArrayGetValueAtIndex(jobs, i);
        int jt = pJobGetType ? pJobGetType(j) : -1;
        lg("[lk] job %ld type=%d\n", (long)i, jt);
        CFStringRef mainSrc = NULL;
        CFArrayRef diags = NULL;
        Boolean ok = pExecuteJob(j, &diags, &mainSrc);
        lg("[lk] job %ld -> %d (diags=%ld)\n", (long)i, (int)ok,
           diags ? (long)CFArrayGetCount(diags) : -1L);
        if (!ok) rc = 1;
    }

    /* 检查输出文件是否生成 */
    if (access(outArg, R_OK) == 0) {
        FILE *f = fopen(outArg, "rb");
        unsigned char m[4] = {0};
        if (f) { fread(m, 1, 4, f); fclose(f); }
        lg("[lk] OUTPUT OK  magic=%02x %02x %02x %02x (cffaedfe=MH64)\n", m[0],m[1],m[2],m[3]);
    } else {
        lg("[lk] OUTPUT MISSING %s\n", outArg);
        rc = 1;
    }
    return rc;
}
