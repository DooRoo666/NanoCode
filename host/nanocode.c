/*
 * nanocode.c — 单进程 Swift/C → 可执行 → .app
 *
 * 核心洞察：CoreCompiler 是完整 driver，内含链接器（kCCJobTypeLinker = 4）。
 * 给 driver 传 "-o out -framework UIKit ..."（不带 -c）它会自己派生出 linker job，
 * 链接在进程内完成，不需要外部 ld64.lld。
 *
 * 用法：
 *   nanocode <CoreCompiler> <sdk> <resdir> <cachedir> <outdir> <in>...
 */
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <dlfcn.h>

typedef struct __CCDriver *CCDriverRef;
typedef struct __CCJob    *CCJobRef;
enum { kJobCompiler=0, kJobDriver, kJobSwiftCompiler, kJobSwiftDriver, kJobLinker, kJobUnknown };

static void lg(const char *fmt, ...) {
    va_list a; va_start(a, fmt); vfprintf(stderr, fmt, a); va_end(a); fflush(stderr);
}

/* 清零 allocator */
static const void *zRetain(const void *i){return i;}
static void zRelease(const void *i){}
static CFStringRef zDesc(const void *i){return CFSTR("Z");}
static void *zAlloc(CFIndex s, CFOptionFlags h, void *i){return calloc(1,(size_t)s);}
static void *zRealloc(void *p, CFIndex n, CFOptionFlags h, void *i){return realloc(p,(size_t)n);}
static void zFree(void *p, void *i){free(p);}
static CFIndex zPref(CFIndex s, CFOptionFlags h, void *i){return s;}
static CFAllocatorRef g_alloc=NULL;
static void makeAllocator(void){
    if(g_alloc) return;
    CFAllocatorContext c; memset(&c,0,sizeof c);
    c.version=0; c.retain=zRetain; c.release=zRelease; c.copyDescription=zDesc;
    c.allocate=zAlloc; c.reallocate=zRealloc; c.deallocate=zFree; c.preferredSize=zPref;
    g_alloc=CFAllocatorCreate(kCFAllocatorSystemDefault,&c);
}

static CCDriverRef (*pDriverCreate)(CFAllocatorRef, CFArrayRef, int);
static CFArrayRef  (*pCreateJobs)(CFAllocatorRef, CCDriverRef);
static CCJobRef    (*pJobCreate)(CFAllocatorRef, int, CFArrayRef, CFArrayRef, CFURLRef);
static Boolean     (*pJobExec)(CCJobRef, CFArrayRef*, CFStringRef*);
static int         (*pJobGetType)(CCJobRef);

static void arrAdd(CFMutableArrayRef a, const char *s){
    CFStringRef v=CFStringCreateWithCString(NULL,s,kCFStringEncodingUTF8);
    CFArrayAppendValue(a,v); CFRelease(v);
}
static int endsWith(const char*s,const char*suf){
    size_t a=strlen(s),b=strlen(suf);
    return a>=b && strcmp(s+a-b,suf)==0;
}

static void dumpDiags(CFArrayRef diags, int limit){
    if(!diags) return;
    CFIndex n=CFArrayGetCount(diags), lim=n>limit?limit:n;
    for(CFIndex k=0;k<lim;k++){
        CFStringRef d=(CFStringRef)CFArrayGetValueAtIndex(diags,k);
        char b[1024]={0};
        if(d) CFStringGetCString(d,b,sizeof b,kCFStringEncodingUTF8);
        lg("      ! %s\n",b);
    }
    if(n>lim) lg("      ... 共 %ld 条\n",(long)n);
}

static int runJobs(CFArrayRef jobs, const char*label, int*outLinkerSeen){
    int fails=0; CFIndex n=CFArrayGetCount(jobs);
    lg("[%s] jobs=%ld\n",label,(long)n);
    for(CFIndex i=0;i<n;i++){
        CCJobRef j=(CCJobRef)CFArrayGetValueAtIndex(jobs,i);
        int jt=pJobGetType?pJobGetType(j):-1;
        if(jt==kJobLinker && outLinkerSeen) *outLinkerSeen=1;
        CFStringRef mainSrc=NULL; CFArrayRef diags=NULL;
        Boolean ok=pJobExec(j,&diags,&mainSrc);
        CFIndex dc=diags?CFArrayGetCount(diags):-1;
        lg("[%s] job%ld type=%d %-8s ok=%d diags=%ld\n",label,(long)i,jt,
           jt==kJobLinker?"LINKER":jt==kJobSwiftCompiler?"swift":"other",
           (int)ok,(long)dc);
        dumpDiags(diags,8);
        if(!ok) fails++;
    }
    return fails;
}

int main(int argc,char**argv){
    if(argc<7){
        fprintf(stderr,"usage: %s <CoreCompiler> <sdk> <resdir> <cachedir> <outdir> <in>...\n",argv[0]);
        return 2;
    }
    const char*ccPath=argv[1], *sdk=argv[2], *resdir=argv[3];
    const char*cachedir=argv[4], *outdir=argv[5];

    makeAllocator();
    if(!g_alloc){lg("[nc] allocator fail\n");return 1;}

    void*h=dlopen(ccPath,RTLD_NOW|RTLD_LOCAL);
    if(!h){lg("[nc] dlopen FAIL: %s\n",dlerror());return 1;}
    lg("[nc] dlopen ok\n");

    pDriverCreate=(CCDriverRef(*)(CFAllocatorRef,CFArrayRef,int))dlsym(h,"CCDriverCreate");
    pCreateJobs  =(CFArrayRef(*)(CFAllocatorRef,CCDriverRef))dlsym(h,"CCDriverCreateJobs");
    pJobCreate   =(CCJobRef(*)(CFAllocatorRef,int,CFArrayRef,CFArrayRef,CFURLRef))dlsym(h,"CCJobCreate");
    pJobExec     =(Boolean(*)(CCJobRef,CFArrayRef*,CFStringRef*))dlsym(h,"CCJobExecuteJob");
    pJobGetType  =(int(*)(CCJobRef))dlsym(h,"CCJobGetType");
    void*pLink   =dlsym(h,"CCLinkerJobExecute");

    if(!pDriverCreate||!pCreateJobs||!pJobExec){lg("[nc] missing driver syms\n");return 1;}
    lg("[nc] CCLinkerJobExecute=%p -> 内置链接器%s\n",pLink,pLink?"可用":"缺失");

    /* Nyxian 在 +load 里做的 CF->ObjC 类型桥接，缺了会字段越界 */
    {
        typedef CFTypeRef(*fnTid)(void);
        typedef void(*fnBr)(CFTypeRef,const char*);
        fnTid pid=(fnTid)dlsym(h,"CCDriverGetTypeID");
        fnBr  pbr=(fnBr)dlsym(RTLD_DEFAULT,"_CFRuntimeBridgeClasses");
        if(pid&&pbr){ pbr(pid(),"MDKDriver"); lg("[nc] bridged MDKDriver\n"); }
        else lg("[nc] bridge skipped (tid=%p br=%p)\n",(void*)pid,(void*)pbr);
    }

    /* 输入分类 */
    int hasSwift=0;
    for(int i=6;i<argc;i++){
        if(endsWith(argv[i],".swift")) hasSwift=1;
        lg("[nc] input: %s\n",argv[i]);
    }

    /* ===== 阶段 1：编译 ===== */
    CFMutableArrayRef args=CFArrayCreateMutable(kCFAllocatorSystemDefault,0,&kCFTypeArrayCallBacks);
    arrAdd(args,"-target"); arrAdd(args,"arm64-apple-ios26.5");
    arrAdd(args,"-sdk"); arrAdd(args,sdk);
    arrAdd(args,"-resource-dir"); arrAdd(args,resdir);
    arrAdd(args,"-module-cache-path"); arrAdd(args,cachedir);
    arrAdd(args,"-module-name"); arrAdd(args,"main");
    arrAdd(args,"-O");
    if(hasSwift) arrAdd(args,"-parse-as-library");   /* 无需 @main */
    for(int i=6;i<argc;i++) arrAdd(args,argv[i]);

    CCDriverRef drv=pDriverCreate(g_alloc,args,hasSwift?1:0);
    lg("[nc] driver=%p\n",(void*)drv);
    if(!drv){lg("[nc] driver NULL\n");return 1;}

    CFArrayRef jobs=pCreateJobs(g_alloc,drv);
    if(!jobs){lg("[nc] createJobs NULL\n");return 1;}

    int linkerSeen=0;
    if(runJobs(jobs,"stage1",&linkerSeen)>0){lg("[nc] stage1 FAILED\n");return 1;}
    lg("[nc] stage1 done, linkerSeen=%d\n",linkerSeen);

    /* ===== 阶段 2：链接 =====
     * 阶段 1 若已产出可执行文件，说明 driver 自己派生了 linker job；
     * 否则显式再跑一遍带链接参数的 driver。 */
    if(!linkerSeen){
        lg("[nc] 阶段1未派发 linker job，显式构建链接参数\n");
        CFMutableArrayRef largs=CFArrayCreateMutable(kCFAllocatorSystemDefault,0,&kCFTypeArrayCallBacks);
        arrAdd(largs,"-target"); arrAdd(largs,"arm64-apple-ios26.5");
        arrAdd(largs,"-sdk");    arrAdd(largs,sdk);
        arrAdd(largs,"-resource-dir"); arrAdd(largs,resdir);
        for(int i=6;i<argc;i++) arrAdd(largs,argv[i]);
        /* 框架与运行时库：缺 UIKit 会导致 UIApplicationMain 符号未定义 */
        if(hasSwift){
            arrAdd(largs,"-lswiftCore"); arrAdd(largs,"-lswiftFoundation");
            arrAdd(largs,"-framework"); arrAdd(largs,"UIKit");
            arrAdd(largs,"-framework"); arrAdd(largs,"Foundation");
        }
        CCDriverRef ldrv=pDriverCreate(g_alloc,largs,hasSwift?1:0);
        if(!ldrv){lg("[nc] link driver NULL\n");return 1;}
        CFArrayRef ljobs=pCreateJobs(g_alloc,ldrv);
        if(!ljobs){lg("[nc] link createJobs NULL\n");return 1;}
        int seen2=0;
        if(runJobs(ljobs,"stage2",&seen2)>0){lg("[nc] link FAILED\n");return 1;}
        lg("[nc] link jobs done, linkerSeen=%d\n",seen2);
    }

    lg("[nc] ALL DONE\n");
    return 0;
}
