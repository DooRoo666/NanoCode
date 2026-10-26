import Foundation

/// 启动后自动跑一遍「persona 探测 + 运行时安装 + 冒烟测试」，
/// 结果写进 Documents/nanocode-diag.txt。
///
/// 这样不需要用户点「高级维护 → Theos 工具链」：
/// 用户在 TrollStore 装好、点开 App 一次，日志就落盘了，
/// 外部 shell（nanoMuse 的 host_exec）可以直接读。
enum NanoMuseAutoDiag {

    static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var logURL: URL { documentsURL().appendingPathComponent("nanocode-diag.txt") }
    static var doneFlagURL: URL { documentsURL().appendingPathComponent(".autodiag-done") }

    /// 由 NanoMuseBootstrap.c 的 constructor 调用（@_cdecl 导出给 C）
    @_cdecl("nm_run_autodiag")
    public static func entry() {
        Task.detached(priority: .utility) {
            await run()
        }
    }

    static func write(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
    }

    static func run() async {
        var out: [String] = []
        out.append("== NanoCode 自动诊断 ==")
        out.append("时间: \(Date())")
        out.append("App: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
        out.append("设备: \(UIDeviceInfo.model) · iOS \(UIDeviceInfo.systemVersion)")
        out.append("bundle: \(Bundle.main.bundlePath)")
        out.append("installRoot: \(NanoMuseTheosRuntime.installRoot)")
        out.append("")
        out.append(contentsOf: NanoMusePersonaProbe.report())
        out.append("")

        // 运行时：已装就只跑冒烟测试；没装则尝试准备（会下载，日志里能看到）
        if let root = NanoMuseTheosRuntime.locate() {
            out.append("== 运行时 ==")
            out.append("  已安装: \(root)")
            write(out)
            for line in await NanoMuseTheosRuntime.smokeTest(root: root) { out.append("  " + line) }
        } else {
            out.append("== 运行时：未安装，开始准备（可能下载 ~224MB）==")
            write(out)
            let installed = await NanoMuseTheosRuntime.prepareAll { line in
                // 进度实时落盘，外部可观察
                var snapshot = out
                snapshot.append(line)
                write(snapshot)
            }
            out.append(installed == nil ? "  准备失败" : "  准备完成: \(installed!)")
            if let root = NanoMuseTheosRuntime.locate() {
                for line in await NanoMuseTheosRuntime.smokeTest(root: root) { out.append("  " + line) }
            }
        }

        out.append("")
        out.append("== 结束 ==")
        write(out)
        FileManager.default.createFile(atPath: doneFlagURL.path, contents: Data("1".utf8))
    }
}

/// 极简设备信息（避免额外引入 UIKit 依赖）
enum UIDeviceInfo {
    static var model: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? "iPhone" : machine
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }
}
