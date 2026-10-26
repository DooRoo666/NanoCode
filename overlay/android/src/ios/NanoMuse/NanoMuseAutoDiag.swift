import Foundation

/// 启动后自动跑一次 persona / 写包内探测，结果落盘到 Documents/persona-diag.txt。
/// 目的：不需要用户在 App 里点任何按钮，外部（宿主 shell）直接读日志就能定位问题。
enum NanoMuseAutoDiag {
    static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var doneMark: URL { documentsURL().appendingPathComponent(".autodiag-done") }

    @_cdecl("nm_run_autodiag")
    public static func entry() {
        Task.detached(priority: .utility) {
            guard !FileManager.default.fileExists(atPath: doneMark.path) else { return }
            NanoMusePersona.probeAndWrite()
            try? "done \(Date())".write(to: doneMark, atomically: true, encoding: .utf8)
        }
    }
}
