import Foundation

/// 启动后自动跑一次 persona / 写包内探测，结果落盘到 Documents/persona-diag.txt。
/// 目的：不需要用户在 App 里点任何按钮，外部（宿主 shell）直接读日志就能定位问题。
enum NanoMuseAutoDiag {
    static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var doneMark: URL { documentsURL().appendingPathComponent(".autodiag-done") }

    /// 每次启动都跑一次（旧版用 doneMark 只跑一次，结果一旦写坏就再也看不到新数据）。
    /// 日志超过 200KB 时先清空，避免无限增长。
    static func runOnce() {
        Task.detached(priority: .utility) {
            let file = documentsURL().appendingPathComponent("persona-diag.txt")
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int,
               size > 200_000 {
                try? FileManager.default.removeItem(at: file)
            }
            NanoMusePersona.probeAndWrite()
            // Nyxian 工具链自检：dlopen CoreCompiler + 编译/链接一个 hello，结果写 nyxian-diag.txt
            _ = NanoMuseNyxian.writeDiagnostics()

            // ★ 2026-10-30 新增：SDK 自动下载
            // 当前策略 = 「开箱即用」：启动时若 Runtimes/sdks/ 里没有可用 SDK，
            // 自动从官方地址拉一份，用户不用管。
            // ⏳ 后期计划 = 「用户自选下载」：改由 NanoMuseRuntimeManifest 里的清单
            //    条目驱动，用户在设置里自己选下哪一份（含版本号、体积、来源）。
            //    届时把下面这行的 `NanoMuseSDKDownloader.ensureInstalled()` 换成
            //    「检查清单 + 提示用户去设置页下载」，NanoMuseSDKDownloader 本身可原样保留。
            NanoMuseSDKDownloader.ensureInstalled { _ in }

            NanoMuseNyxian.startSwiftWatch()
        }
    }
}

/// C 侧（NanoMuseBootstrap.c）在启动 3 秒后调用
@_cdecl("nm_run_autodiag")
public func nm_run_autodiag() {
    NanoMuseAutoDiag.runOnce()
}
