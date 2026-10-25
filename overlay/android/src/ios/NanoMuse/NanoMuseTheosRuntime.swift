import Foundation

/// TheosRuntime：MT-Agent 打包进 App 的那套 arm64 Procursus 工具链
/// （clang-16 / make / ld64 / ldid / dpkg-deb / odcctools）。
///
/// 它本身是好的，但跑起来会崩在：
///     Library not loaded: @rpath/libiosexec.1.dylib
///     sandbox blocked mmap()
///
/// 原因不是文件缺失，也不是架构不对，而是 **library validation**：
/// dyld 加载非 Apple 签名的 dylib 时，被加载者（clang-16 等）自己的签名
/// 必须带 `com.apple.security.cs.disable-library-validation`。entitlements 不继承，
/// 所以主程序加了权限也没用 —— 必须把 runtime 里的 Mach-O **逐个重签**。
///
/// 这个类型就做这件事：定位 runtime → 用随包 codex-sign + 我们的 entitlements 重签。
enum NanoMuseTheosRuntime {

    struct Report: Sendable {
        var ok = false
        var root: String?
        var signed = 0
        var failed = 0
        var total = 0
        var lines: [String] = []
        var text: String { lines.joined(separator: "\n") }
    }

    /// MT-Agent 把 runtime 落在这些位置（它用 no-container 直接写 /var/mobile）
    static let candidates = [
        "/var/mobile/Library/Application Support/CodexApp/PreparedRuntimes/TheosRuntime",
        "/var/mobile/Library/Application Support/CodexApp/PreparedRuntimes/theos",
        "/var/mobile/Library/Application Support/CodexApp/TheosRuntime",
        "/var/mobile/Library/Application Support/CodexApp/theos",
        "/var/mobile/Library/Caches/CodexApp/PreparedRuntimes/TheosRuntime",
        "/var/mobile/Library/Caches/CodexApp/TheosRuntime",
        "/var/mobile/Documents/CodexHelpers/TheosRuntime",
        "/var/mobile/Documents/Codex-mt/TheosRuntime",
        "/var/mobile/Documents/TheosRuntime",
        "/var/jb/opt/theos",
        "/opt/theos",
    ]

    /// 以 ourselves 容器里的副本优先（沙盒内 mmap 最稳），再扫设备上的常见位置
    static func searchRoots() -> [String] {
        var list: [String] = []
        let docs = NanoMuseTipaBuilder.documentsURL().path
        list.append(docs + "/TheosRuntime")
        list.append(NSHomeDirectory() + "/Library/TheosRuntime")
        list.append(contentsOf: candidates)
        return list
    }

    /// 判定一个目录像不像 TheosRuntime：要有 usr/bin 或 bin，并且能找到 make/clang 之一
    static func looksLikeRuntime(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        let probes = [
            "/usr/bin/make", "/usr/bin/clang", "/usr/bin/clang-16",
            "/bin/make", "/usr/bin/ldid", "/usr/bin/dpkg-deb",
        ]
        for p in probes where fm.fileExists(atPath: path + p) { return true }
        return false
    }

    static func locate() -> String? {
        for root in searchRoots() where looksLikeRuntime(root) {
            return root
        }
        return nil
    }

    /// 在 root 下找所有 Mach-O（跳过符号链接，签名跟着真实文件走）
    static func machOs(under root: String) -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: root),
                                        includingPropertiesForKeys: keys,
                                        options: [],
                                        errorHandler: nil) else { return [] }
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory == true || v.isSymbolicLink == true || v.isRegularFile != true { continue }
            if isMachO(url.path) { result.append(url.path) }
        }
        return result
    }

    static func isMachO(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let b = [UInt8](head)
        let magic = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        return [0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE,
                0xCAFEBABE, 0xBEBAFECA].contains(magic)
    }

    /// 用 codex-sign 把 runtime 里每个 Mach-O 重签成带我们 entitlements 的版本。
    /// 这样 clang-16 / make 自己就带 disable-library-validation，能加载 Procursus 的 dylib。
    static func resign(at root: String) async -> Report {
        var report = Report()
        report.root = root
        let ent = Bundle.main.bundlePath + "/entitlements.plist"
        guard FileManager.default.fileExists(atPath: ent) else {
            report.lines.append("ERR 包内没有 entitlements.plist，无法重签")
            return report
        }
        let targets = machOs(under: root)
        report.total = targets.count
        report.lines.append("== 重签 TheosRuntime ==")
        report.lines.append("root: \(root)")
        report.lines.append("Mach-O: \(targets.count) 个")
        guard !targets.isEmpty else {
            report.lines.append("ERR 没找到任何 Mach-O，路径可能不对")
            return report
        }
        for path in targets {
            let run = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run("codex-sign",
                                         arguments: ["--entitlements", ent, path],
                                         timeout: 120)
            }.value
            if run.exitCode == 0 {
                report.signed += 1
            } else {
                // 有些文件本来就不该签（脚本、数据），失败不阻断
                report.failed += 1
            }
        }
        report.lines.append("完成：成功 \(report.signed)，跳过/失败 \(report.failed)")
        report.ok = report.signed > 0
        if report.ok {
            report.lines.append("下一步：跑 clang-16 --version 验证 dylib 是否还会被拦。")
        }
        return report
    }

    /// 给 codex 用的环境：把 runtime 的 bin/lib 放进 PATH / DYLD 路径
    static func environment(for root: String) -> [String: String] {
        var env: [String: String] = [:]
        let bin = [root + "/usr/bin", root + "/bin"].filter {
            FileManager.default.fileExists(atPath: $0)
        }
        let base = NanoMuseHelperRunner.helpersDirectory
        env["PATH"] = (bin + [base, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        let libs = [root + "/usr/lib", root + "/lib"].filter {
            FileManager.default.fileExists(atPath: $0)
        }
        if !libs.isEmpty {
            env["DYLD_LIBRARY_PATH"] = libs.joined(separator: ":")
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libs.joined(separator: ":")
        }
        env["THEOS"] = root
        env["_THEOS_PLATFORM_DPKG_DEB"] = root + "/usr/bin/dpkg-deb"
        return env
    }
}
