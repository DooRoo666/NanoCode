// NanoMuseBootstrap.c
//
// 唯一的启动钩子：用 constructor 在 App 加载时登记一次延时回调，
// 到点后调用 Swift 的 nm_run_autodiag()（见 NanoMuseAutoDiag.swift）。
//
// 为什么用 C：Swift 没有 @load/constructor 机制，而 overlay 里新增的
// .swift 文件是随文件系统同步组自动进 target 的，.c 同样会被自动编译。
// 不用 block 语法，避免给 .c 加 -fblocks。

#include <dispatch/dispatch.h>

extern void nm_run_autodiag(void);

static void nm_boot_cb(void *ctx) {
    (void)ctx;
    nm_run_autodiag();
}

__attribute__((constructor))
static void nm_bootstrap(void) {
    // 等 3 秒，确保 SwiftUI 的 App 结构体、Bundle 都已就绪
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(),
                     NULL,
                     nm_boot_cb);
}
