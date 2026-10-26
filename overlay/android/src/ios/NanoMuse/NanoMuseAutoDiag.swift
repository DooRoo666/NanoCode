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
            NanoMuseHostBridge.start()
            NanoMuseRuntimeDiag.write()
        }
    }
}

/// C 侧（NanoMuseBootstrap.c）在启动 3 秒后调用
@_cdecl("nm_run_autodiag")
public func nm_run_autodiag() {
    NanoMuseAutoDiag.runOnce()
}
