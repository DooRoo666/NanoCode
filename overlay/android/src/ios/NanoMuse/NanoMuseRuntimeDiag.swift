import Darwin
import Foundation

/// 运行时能不能「动态加载」的现场取证。
///
/// 背景：在 nanoMuse 里跑 `Library/TheosRuntime/usr/bin/ld64` 报
/// `file system sandbox blocked mmap()` —— 那是 nanoMuse 的沙盒，不是 NanoCode 的。
/// 我们的 App 带着 platform-application + no-sandbox 签名，
/// 到底允不允许把运行时里的 dylib 映射成可执行页，只能在自己进程里验。
enum NanoMuseRuntimeDiag {
    static let root = "/var/mobile/Library/TheosRuntime"

    static func run() -> [String] {
        var lines: [String] = ["===== 运行时动态加载取证 ====="]
        lines.append("root=\(root)")

        // ① dlopen：过了就说明沙盒允许映射 dylib
        let candidates = [
            "usr/lib/libxar.1.dylib",
            "usr/lib/libiosexec.1.dylib",
            "usr/lib/llvm-16/lib/libLLVM.dylib",
        ]
        for rel in candidates {
            let path = root + "/" + rel
            guard FileManager.default.fileExists(atPath: path) else {
                lines.append("dlopen \(rel): 文件不存在")
                continue
            }
            errno = 0
            if let handle = dlopen(path, RTLD_NOW) {
                lines.append("dlopen \(rel): OK")
                dlclose(handle)
            } else {
                let message = dlerror().map { String(cString: $0) } ?? "unknown"
                lines.append("dlopen \(rel): FAIL errno=\(errno) \(message)")
            }
        }

        // ② 跑关键工具：动态链接的能过，说明整条 Theos 链可用
        let probes: [(String, String, [String])] = [
            ("ld64", "usr/bin/ld64", ["-v"]),
            ("perl", "usr/bin/perl", ["-v"]),
            ("dpkg-deb", "usr/bin/dpkg-deb", ["--version"]),
            ("clang-16", "usr/bin/clang-16", ["--version"]),
            ("make", "usr/bin/make", ["-v"]),
            ("ldid", "usr/bin/ldid", []),
        ]
        for (name, rel, args) in probes {
            let path = root + "/" + rel
            guard FileManager.default.fileExists(atPath: path) else {
                lines.append("\(name): 文件不存在")
                continue
            }
            guard let result = NanoMusePersona.spawn(path, args: [name] + args, personaID: nil, timeout: 15) else {
                lines.append("\(name): spawn 失败")
                continue
            }
            let head = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(name): rc=\(result.rc) \(String(head.prefix(160)))")
        }

        return lines
    }

    static func write() {
        let text = run().joined(separator: "\n") + "\n"
        let url = NanoMuseAutoDiag.documentsURL().appendingPathComponent("runtime-diag.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
