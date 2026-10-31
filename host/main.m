// NanoCodeHost — 常驻宿主（不引用 UIKit 头，纯 runtime 调用 UIApplicationMain）
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdio.h>
#import <stdarg.h>
#import <unistd.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>

extern int UIApplicationMain(int argc, char *argv[], NSString *principalClassName,
                             NSString *delegateClassName);

static FILE *gLog = NULL;

static void LOG(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (gLog) { fprintf(gLog, "[nano] %s\n", s.UTF8String); fflush(gLog); }
}

static void OpenLog(void) {
    gLog = fopen("/var/mobile/Documents/nyxian/nanolog.txt", "w");
    if (!gLog) {
        NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"nanolog.txt"];
        gLog = fopen(p.fileSystemRepresentation, "w");
    }
}

static void Stage1(void) {
    NSBundle *b = [NSBundle mainBundle];
    LOG(@"start pid=%d", (int)getpid());
    LOG(@"bundle=%@", [b bundlePath]);

    NSString *core = [[b bundlePath]
        stringByAppendingPathComponent:@"Frameworks/CoreCompiler.framework/CoreCompiler"];
    LOG(@"core=%@", core);
    LOG(@"exists=%d readable=%d",
        (int)[[NSFileManager defaultManager] fileExistsAtPath:core],
        (int)[[NSFileManager defaultManager] isReadableFileAtPath:core]);

    void *h = dlopen(core.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        const char *e = dlerror();
        LOG(@"dlopen failed: %s", e ? e : "null");
        return;
    }
    LOG(@"dlopen ok handle=%p", h);

    const char *syms[] = { "CCDriverCreate", "CCDriverCreateJobs", "CCJobExecuteJob",
                           "CCJobCreate", "CCJobCreateArguments",
                           "CCSwiftCompilerJobExecute", "CCSDKGetTypeID",
                           "CCDriverCopySysrootURL" };
    for (int i = 0; i < 8; i++) {
        LOG(@"dlsym %s -> %p", syms[i], dlsym(h, syms[i]));
    }
    LOG(@"stage1 done");
}

extern void stage2_run(const char*, const char*, const char*, const char*, const char*, const char*, FILE*);
static BOOL gRan = NO;

@interface NCHAppDelegate : NSObject @end

@implementation NCHAppDelegate

- (BOOL)application:(id)app didFinishLaunchingWithOptions:(id)opts {
    LOG(@"didFinishLaunching");
    // 全部用 C 缓冲区：block 里绝不捕获 ObjC 对象（否则 _Block_copy 会 retain，
    // 之前 objc_msgSend 拿到的裸指针在那时是野指针 → SIGSEGV far=0x2）
    static char ccPathBuf[1024];
    static char outBuf[1024];
    NSString *bundle = [[NSBundle mainBundle] bundlePath];
    NSString *ccPath = [bundle stringByAppendingPathComponent:
                        @"Frameworks/CoreCompiler.framework/CoreCompiler"];
    NSString *outObj = [NSTemporaryDirectory() stringByAppendingPathComponent:@"stage2_out.o"];
    snprintf(ccPathBuf, sizeof ccPathBuf, "%s", ccPath.fileSystemRepresentation);
    snprintf(outBuf, sizeof outBuf, "%s", outObj.fileSystemRepresentation);

    // 在 block 外申请后台任务，避免 block 捕获 ObjC 对象（那是 s16 的崩溃原因）
    static uintptr_t gBgTask = 0;
    {
        SEL sharedSel = sel_registerName("sharedApplication");
        Class appCls = (Class)objc_getClass("UIApplication");
        id sharedApp = appCls ? ((id(*)(id, SEL))objc_msgSend)((id)appCls, sharedSel) : nil;
        SEL beginSel = sel_registerName("beginBackgroundTaskWithExpirationHandler:");
        if (sharedApp && [sharedApp respondsToSelector:beginSel]) {
            id (^h)(void) = ^id { LOG(@"bg task expired"); return nil; };
            gBgTask = (uintptr_t)((id(*)(id, SEL, id))objc_msgSend)(sharedApp, beginSel, h);
            LOG(@"bgtask=%lu", (unsigned long)gBgTask);
        }
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LOG(@"bg: stage2 start");
        stage2_run(ccPathBuf,
                   "/private/var/mobile/Documents/nyxian/iPhoneOS26.5.sdk",
                   "/private/var/mobile/Documents/nyxian/Shared/swift",
                   "/var/mobile/Documents/nyxian/ModuleCache",
                   "/private/var/mobile/Documents/nyxian/hello.swift",
                   outBuf,
                   gLog);
        LOG(@"bg: stage2 returned");
    });
    return YES;
}

@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if (!gLog) OpenLog();
        LOG(@"main entered argc=%d", argc);
        // stage2 已移到 didFinishLaunchingWithOptions 的后台队列，避开启动 watchdog
        LOG(@"entering UIApplicationMain");
        int rc = UIApplicationMain(argc, argv, nil, @"NCHAppDelegate");
        LOG(@"UIApplicationMain returned %d", rc);
        return rc;
    }
}
