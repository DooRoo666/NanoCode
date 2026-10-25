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
    ///
    /// 为了不每次启动都扫 373 个文件重签一遍，这里做**增量**：
    /// 在 runtime 根目录写 `.nanomuse-resign.json`，记录 entitlements 指纹
    /// 和每个文件的 (size, mtime)；指纹与文件状态都没变就直接跳过。
    static func resign(at root: String, force: Bool = false) async -> Report {
        var report = Report()
        report.root = root
        let ent = Bundle.main.bundlePath + "/entitlements.plist"
        guard let entData = FileManager.default.contents(atPath: ent) else {
            report.lines.append("ERR 包内没有 entitlements.plist，无法重签")
            return report
        }
        let entHash = fnv1a(entData)

        let targets = machOs(under: root)
        report.total = targets.count
        report.lines.append("== 重签 TheosRuntime（增量）==")
        report.lines.append("root: \(root)")
        report.lines.append("Mach-O: \(targets.count) 个")
        guard !targets.isEmpty else {
            report.lines.append("ERR 没找到任何 Mach-O，路径可能不对")
            return report
        }

        var marker = loadMarker(root) ?? Marker(version: markerVersion, entHash: "", files: [:])
        let firstRun = marker.entHash.isEmpty
        let entChanged = marker.entHash != entHash
        if entChanged && !firstRun {
            report.lines.append("entitlements 变了 → 全部重签")
            marker.files.removeAll()
        }
        marker.entHash = entHash

        var pending: [String] = []
        for path in targets {
            let rel = relative(path, to: root)
            let stamp = fileStamp(path)
            if !force, let old = marker.files[rel], old == stamp { continue }
            pending.append(path)
        }
        report.lines.append("待重签: \(pending.count) 个（已是最新 \(targets.count - pending.count) 个）")

        if pending.isEmpty {
            report.signed = targets.count
            report.ok = true
            report.lines.append("无需重签：签名与 entitlements 都是最新的")
            return report
        }

        for path in pending {
            let run = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run("codex-sign",
                                         arguments: ["--entitlements", ent, path],
                                         timeout: 120)
            }.value
            if run.exitCode == 0 {
                report.signed += 1
                marker.files[relative(path, to: root)] = fileStamp(path)
            } else {
                // 有些文件本来就不该签（脚本、数据），失败不阻断
                report.failed += 1
            }
        }
        saveMarker(root, marker)
        report.lines.append("完成：成功 \(report.signed)，跳过/失败 \(report.failed)")
        report.ok = report.signed > 0
        if report.ok {
            report.lines.append("下一步：跑 clang-16 --version 验证 dylib 是否还会被拦。")
        }
        return report
    }

    /// codex 启动时调用：有缓存就直接返回，过期才真正重签。
    /// 全程在后台，不阻塞 UI，也不改动 MT-Agent 的文件布局（原地重签，不复制）。
    @discardableResult
    static func prepareInBackground() -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            guard let root = NanoMuseTheosRuntime.locate() else { return }
            let r = await NanoMuseTheosRuntime.resign(at: root)
            if !r.ok {
                NSLog("[NanoMuse] TheosRuntime 重签未完成：\n\(r.text)")
            }
        }
    }

    /// 轻量自检：确认工具链真的能起来（重签是否生效的最终判据）
    static func smokeTest(root: String) async -> [String] {
        var lines: [String] = ["== TheosRuntime 自检 =="]
        let probes: [(String, [String])] = [
            ("usr/bin/clang-16", ["--version"]),
            ("usr/bin/make", ["--version"]),
            ("usr/bin/ldid", ["-h"]),
            ("usr/bin/dpkg-deb", ["--version"]),
        ]
        for (rel, args) in probes {
            let path = root + "/" + rel
            guard FileManager.default.isExecutableFile(atPath: path) else {
                lines.append("  \(rel): 不存在")
                continue
            }
            let run = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run(path, arguments: args, timeout: 60)
            }.value
            let first = run.output.split(separator: "\n").first.map(String.init) ?? ""
            let mark = run.exitCode == 0 ? "OK " : "FAIL"
            lines.append("  \(mark) \(rel) rc=\(run.exitCode) \(first.prefix(80))")
            if run.exitCode != 0, run.output.contains("Library not loaded") {
                lines.append("       ↳ library validation 仍生效，确认本次重签是否成功")
            }
        }
        return lines
    }

    // MARK: - 增量标记

    static let markerVersion = 1
    static let markerName = ".nanomuse-resign.json"

    struct Marker: Codable {
        var version: Int
        var entHash: String
        /// 相对路径 -> [size, mtime]
        var files: [String: [String]]
    }

    static func markerPath(_ root: String) -> String { root + "/" + markerName }

    static func loadMarker(_ root: String) -> Marker? {
        guard let d = FileManager.default.contents(atPath: markerPath(root)) else { return nil }
        guard let m = try? JSONDecoder().decode(Marker.self, from: d) else { return nil }
        return m.version == markerVersion ? m : nil
    }

    static func saveMarker(_ root: String, _ m: Marker) {
        guard let d = try? JSONEncoder().encode(m) else { return }
        try? d.write(to: URL(fileURLWithPath: markerPath(root)))
    }

    static func fileStamp(_ path: String) -> [String] {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (a?[.size] as? NSNumber)?.stringValue ?? "0"
        let mtime = (a?[.modificationDate] as? Date).map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        return [size, mtime]
    }

    static func relative(_ path: String, to root: String) -> String {
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return path
    }

    /// FNV-1a：只用来判断 entitlements 有没有变，不需要密码学强度
    static func fnv1a(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// 给 codex 用的环境：把 runtime 的 bin/lib 放进 PATH / DYLD 路径
    static func environment(for root: String) -> [String: String] {
        var env: [String: String] = [:]
        let fm = FileManager.default
        let bin = [root + "/usr/bin", root + "/bin"].filter { fm.fileExists(atPath: $0) }
        let base = NanoMuseHelperRunner.helpersDirectory
        env["PATH"] = (bin + [base, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        let libs = [root + "/usr/lib", root + "/lib"].filter { fm.fileExists(atPath: $0) }
        if !libs.isEmpty {
            env["DYLD_LIBRARY_PATH"] = libs.joined(separator: ":")
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libs.joined(separator: ":")
        }
        // 只有真的带 Theos makefiles 时才叫 THEOS；TheosRuntime 自己不是 Theos 安装树，
        // 硬塞 THEOS 会让真正的 Theos 工程找不到 makefiles。
        env["TOOLCHAIN_ROOT"] = root
        if fm.fileExists(atPath: root + "/makefiles") {
            env["THEOS"] = root
        }
        let dpkg = root + "/usr/bin/dpkg-deb"
        if fm.isExecutableFile(atPath: dpkg) {
            env["_THEOS_PLATFORM_DPKG_DEB"] = dpkg
        }
        return env
    }
}
