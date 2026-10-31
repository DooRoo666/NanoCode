#include <stdio.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>

typedef struct __CCDriver *CCDriverRef;
typedef struct __CCJob *CCJobRef;
typedef unsigned char Boolean;

typedef CCDriverRef (*fn_DriverCreate)(CFAllocatorRef, CFArrayRef, int);
// 反汇编确证: 09: mov x26,x0 (driver) -> 实参顺序是 (driver, allocator)
typedef CFArrayRef (*fn_CreateJobs)(CCDriverRef, CFAllocatorRef);
typedef Boolean (*fn_ExecuteJob)(CCJobRef, CFArrayRef*, CFStringRef*);
typedef CFURLRef (*fn_CopySysroot)(CCDriverRef);

static fn_DriverCreate pDriverCreate;
static CFURLRef (*pCopySysroot)(CCDriverRef);
static void* (*pCopySDK)(CCDriverRef);
static fn_CreateJobs   pCreateJobs;
static fn_ExecuteJob   pExecuteJob;
static fn_CopySysroot  pCopySysroot;

static void lg(FILE *f, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    vfprintf(f, fmt, ap); va_end(ap); fflush(f);
}


// ===== 清零 allocator：让 _CFRuntimeCreateInstance 分配出的对象内存全 0 =====
static const void *zAllocRetain(const void *info) { return info; }
static void  zAllocRelease(const void *info) {}
static CFStringRef zCopyDesc(const void *info) { return CFSTR("ZeroAlloc"); }

static void *zAllocate(CFIndex size, CFOptionFlags hint, void *info) {
    void *p = calloc(1, (size_t)size);
    return p;
}
static void *zReallocate(void *ptr, CFIndex newsize, CFOptionFlags hint, void *info) {
    // 新区域的后半段必须清零
    void *p = realloc(ptr, (size_t)newsize);
    return p;
}
static void zDeallocate(void *ptr, void *info) { free(ptr); }
static CFIndex zPreferredSize(CFIndex size, CFOptionFlags hint, void *info) { return size; }

static CFAllocatorRef g_zeroAlloc = NULL;

static void makeZeroAllocator(void) {
    if (g_zeroAlloc) return;
    CFAllocatorContext ctx;
    memset(&ctx, 0, sizeof ctx);
    ctx.version = 0;
    ctx.info = NULL;
    ctx.retain = zAllocRetain;
    ctx.release = zAllocRelease;
    ctx.copyDescription = zCopyDesc;
    ctx.allocate = zAllocate;
    ctx.reallocate = zReallocate;
    ctx.deallocate = zDeallocate;
    ctx.preferredSize = zPreferredSize;
    g_zeroAlloc = CFAllocatorCreate(kCFAllocatorSystemDefault, &ctx);
}

void stage2_run(const char *compilerPath, const char *sdkPath, const char *resourceDir, const char *moduleCachePath, const char *srcPath, const char *outPath, FILE *log) {
    makeZeroAllocator();
    {   // Nyxian 每次引导都会重建 ModuleCache，缺失会导致 Swift 前端初始化失败
        mkdir(moduleCachePath, 0755);   // 不用 system()，本机 fork 不可用
        struct stat st;
        lg(log, "[s2] moduleCache %s -> %s\n", moduleCachePath,
           (stat(moduleCachePath, &st)==0) ? "OK" : "MISSING");
    }
    lg(log, "[s2] begin compiler=%s\n", compilerPath);
    lg(log, "[s2] sdk=%s\n", sdkPath);
    lg(log, "[s2] src=%s\n", srcPath);
    lg(log, "[s2] out=%s\n", outPath);
    lg(log, "[s2] resourceDir=%s\n", resourceDir);

    void *h = dlopen(compilerPath, RTLD_NOW);
    if (!h) { lg(log, "[s2] dlopen FAIL %s\n", dlerror()); return; }
    lg(log, "[s2] dlopen ok\n");

    pDriverCreate = (fn_DriverCreate)dlsym(h, "CCDriverCreate");
    pCopySysroot = dlsym(h, "CCDriverCopySysrootURL");
    pCopySDK     = dlsym(h, "CCDriverCopySDK");
    int (*pGetType)(CCDriverRef) = (int (*)(CCDriverRef))dlsym(h, "CCDriverGetType");
    lg(log, "[s2] GetType sym=%p\n", (void*)pGetType);
    pCreateJobs   = (fn_CreateJobs)dlsym(h, "CCDriverCreateJobs");
    pExecuteJob   = (fn_ExecuteJob)dlsym(h, "CCJobExecuteJob");
    pCopySysroot  = (fn_CopySysroot)dlsym(h, "CCDriverCopySysrootURL");
    lg(log, "[s2] syms %p %p %p %p\n", (void*)pDriverCreate, (void*)pCreateJobs,
          (void*)pExecuteJob, (void*)pCopySysroot);
    if (!pDriverCreate || !pCreateJobs || !pExecuteJob) {
        lg(log, "[s2] missing syms\n"); return;
    }

    // Nyxian 在 +load 里做的 CF -> ObjC 类型桥接，少了会导致 CF 对象字段访问越界
    typedef CFTypeRef (*fn_GetTypeID)(void);
    typedef void (*fn_Bridge)(CFTypeRef, const char*);
    fn_GetTypeID pDriverTypeID = (fn_GetTypeID)dlsym(h, "CCDriverGetTypeID");
    fn_Bridge   pBridge      = (fn_Bridge)dlsym(RTLD_DEFAULT, "_CFRuntimeBridgeClasses");
    lg(log, "[s2] bridge syms typeID=%p bridge=%p\n", (void*)pDriverTypeID, (void*)pBridge);
    if (pDriverTypeID && pBridge) {
        pBridge(pDriverTypeID(), "MDKDriver");
        lg(log, "[s2] bridged MDKDriver\n");
    }
    // ---- 关键修复：CoreCompiler 的 CCDriverCreate 没有对 C++ 成员做 placement new,
    // SmallVector 的 Capacity/Size 会是 malloc 残留垃圾 -> reserve() 申请巨量内存 -> bad_alloc
    // 用一个 calloc 语义的 CFAllocator 让它分配出的 payload 全为 0
    CFAllocatorRef zeroAlloc = g_zeroAlloc;
    lg(log, "[s2] zeroAlloc=%p\n", (void*)zeroAlloc);

    lg(log, "[s2] step1 creating args\n");

    CFMutableArrayRef args = CFArrayCreateMutable(kCFAllocatorSystemDefault, 0, &kCFTypeArrayCallBacks);
    // 完全对齐 Nyxian NXCodeTemplate.m: NXSwiftFlagsForCodeTemplateLanguage
    char targetBuf[128], resBuf[512], cacheBuf[640];
    // Nyxian NXProject.m:80 默认 NXDeploymentTarget=25.0；117 行 triple 为 apple-arm64-ios<ver>
    snprintf(targetBuf, sizeof targetBuf, "arm64-apple-ios26.5");
    snprintf(resBuf, sizeof resBuf, "%s", resourceDir);
    snprintf(cacheBuf, sizeof cacheBuf, "%s", moduleCachePath);
    const char *argv[] = {
        "-target", targetBuf,
        "-sdk", sdkPath,
        "-resource-dir", resBuf,
        "-module-cache-path", cacheBuf,
        "-module-name", "main",
        "-emit-object",
        "-o", outPath,
        srcPath,          /* ★ 必须有输入文件，否则 parseArgStrings 报 no input files */
        NULL
    };
    for (int i = 0; argv[i]; i++) {
        CFStringRef s = CFStringCreateWithCString(NULL, argv[i], kCFStringEncodingUTF8);
        CFArrayAppendValue(args, s); CFRelease(s);
    }
    int argc=0; while(argv[argc]) argc++;
    lg(log, "[s2] step2 args built (%d)\n", argc);

    lg(log, "[s2] BEFORE Create: args count=%ld\n", (long)CFArrayGetCount(args));
    CCDriverRef drv = pDriverCreate(zeroAlloc, args, 1 /*kCCDriverTypeSwift*/);
    lg(log, "[s2] AFTER  Create: args count=%ld\n", (long)CFArrayGetCount(args));
    lg(log, "[s2] step3 driver=%p\n", (void*)drv);
    if (!drv) { lg(log, "[s2] driver NULL\n"); return; }

    if (pGetType) {
        unsigned long long raw = *(unsigned long long *)((char *)drv + 8);
        lg(log, "[s2] GetType()=%d  raw@+8=0x%llx\n", (int)pGetType(drv), raw);
    }
    if (pCopySysroot) {
        CFURLRef sys = pCopySysroot(drv);
        lg(log, "[s2] sysroot=%p\n", (void*)sys);
        if (sys) { CFStringRef d = CFURLGetString(sys);
            char b[512]; if (d && CFStringGetCString(d,b,sizeof b,kCFStringEncodingUTF8))
                lg(log, "[s2] sysrootStr=%s\n", b); }
    }

    {   // 精确探针：type 在 +0x10 (strb w20,[x19,#0x10])
        unsigned char *b=(unsigned char*)drv;
        lg(log, "[s2] type@+0x10 = %d  (期望 1)\n", (int)b[0x10]);
        lg(log, "[s2] hdr: %02x %02x %02x %02x %02x %02x %02x %02x | %02x %02x %02x %02x\n",
           b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[0xA],b[0xB]);
        lg(log, "[s2] +0x10..: %02x %02x %02x %02x %02x %02x %02x %02x\n",
           b[0x10],b[0x11],b[0x12],b[0x13],b[0x14],b[0x15],b[0x16],b[0x17]);
    }
    lg(log, "[s2] step4 createJobs...\n");
    {   // 调用前 dump driver 关键字段
        unsigned char *b=(unsigned char*)drv;
        lg(log, "[s2] pre-CreateJobs: type[+0x10]=%d\n", (int)b[0x10]);
        /* 把 stderr 重定向到文件，捕获 PrintingDiagnosticConsumer 的输出 */
        {
            char dbg[512]; snprintf(dbg, sizeof dbg, "%s/diag.log", moduleCachePath);
            int dfd = open(dbg, O_WRONLY|O_CREAT|O_TRUNC, 0644);
            if (dfd >= 0) { dup2(dfd, STDERR_FILENO); dup2(dfd, STDOUT_FILENO); close(dfd); }
            lg(log, "[s2] diag capture -> %s\n", dbg);
        }
        lg(log, "[s2]   sysroot=%p sdk=%p\n",
           (void*)(pCopySysroot?pCopySysroot(drv):0), pCopySDK?pCopySDK(drv):0);
        lg(log, "[s2]   +0x198(SwiftDriver)=%p  +0x1C0(diagVec)=%p  +0x1C8=%d\n",
           *(void**)(b+0x198), *(void**)(b+0x1C0), *(int*)(b+0x1C8));
        lg(log, "[s2]   +0x1A0(ClangDriver)=%p  +0x1D0=%d\n",
           *(void**)(b+0x1A0), *(int*)(b+0x1D0));
        lg(log, "[s2] pre: count(args)=%ld\n", (long)CFArrayGetCount(args));
        for (CFIndex qi=0; qi<CFArrayGetCount(args) && qi<20; qi++) {
            CFStringRef sv=(CFStringRef)CFArrayGetValueAtIndex(args,qi);
            char tb[256]; CFStringGetCString(sv,tb,sizeof tb,kCFStringEncodingUTF8);
            lg(log, "[s2]   arg[%ld]=%s\n",(long)qi,tb);
        }
    }
    CFArrayRef jobs = pCreateJobs(drv, zeroAlloc);
    lg(log, "[s2] step5 jobs=%p count=%ld\n", (void*)jobs,
       jobs ? (long)CFArrayGetCount(jobs) : -1L);
    if (!jobs) { lg(log, "[s2] no jobs\n"); return; }

    CFIndex n = CFArrayGetCount(jobs);
    for (CFIndex i = 0; i < n; i++) {
        CCJobRef j = (CCJobRef)CFArrayGetValueAtIndex(jobs, i);
        lg(log, "[s2] exec job %ld ...\n", (long)i);
        /* 心跳：每 5 秒写一条，用于区分「卡死」与「只是慢」 */
        static volatile int hbStop = 0;
        hbStop = 0;
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            int t = 0;
            while (!hbStop && t < 600) {
                for (int s = 0; s < 10 && !hbStop; s++)
                    usleep(100000);
                t += 1;
                if (hbStop) break;
                if (t % 5 == 0) {
                    struct rusage ru; int rs = getrusage(RUSAGE_SELF, &ru);
                    long mb = rs == 0 ? (long)(ru.ru_maxrss / (1024*1024)) : -1;
                    lg(log, "[hb] %d 秒 rss=%ldMB\n", t, mb);
                }
            }
        });
        CFArrayRef diags = NULL; CFStringRef mainsrc = NULL;
        Boolean ok = pExecuteJob(j, &diags, &mainsrc);
        hbStop = 1;
        lg(log, "[s2] job %ld -> %d\n", (long)i, (int)ok);
        if (diags) {
            CFIndex dn = CFArrayGetCount(diags);
            lg(log, "[s2] diagCount=%ld\n", (long)dn);
            for (CFIndex k = 0; k < dn; k++) {
                CFTypeRef d = (CFTypeRef)CFArrayGetValueAtIndex(diags, k);
                char b[2048];
                b[0] = 0;
                /* 元素可能是 CCDiagnostic（__NSCFType），不是 NSString。
                   只有确认类型后才当字符串读，否则整体 description。 */
                CFTypeID tid = d ? CFGetTypeID(d) : 0;
                if (tid == CFStringGetTypeID()) {
                    if (!CFStringGetCString((CFStringRef)d, b, sizeof b, kCFStringEncodingUTF8))
                        b[0] = 0;
                } else if (d) {
                    CFStringRef desc = CFCopyDescription(d);
                    if (desc) {
                        CFStringGetCString(desc, b, sizeof b, kCFStringEncodingUTF8);
                        CFRelease(desc);
                    }
                }
                lg(log, "[diag] %s\n", b[0] ? b : "(unprintable)");
            }
        }
    }
    lg(log, "[s2] DONE\n");
}
