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
        var skipped = 0
        var failed = 0
        var total = 0
        var lines: [String] = []
        var text: String { lines.joined(separator: "\n") }
    }

    /// 本 App 自有的 runtime 位置（**只用自己容器里的**）。
    ///
    /// 不再扫描 MT-Agent 的 `Application Support/CodexApp/...`：
    /// 那是别的 App 的容器，路径随时可能被它自己清理/升级覆盖，
    /// 写进去也等于改别人的文件。这里只认自己沙盒内的副本。
    static func ownRoots() -> [String] {
        var list: [String] = []
        // ② App 包内（若将来把 runtime 直接打进 tipa）
        list.append(Bundle.main.bundlePath + "/TheosRuntime")
        list.append(Bundle.main.resourcePath.map { $0 + "/TheosRuntime" } ?? "")
        // ③ 用户可直接投放的 Documents（Files App 可见）
        list.append(NanoMuseTipaBuilder.documentsURL().path + "/TheosRuntime")
        // ④ 正式安装位置（运行时安装器解包到这里）
        list.append(installRoot)
        return list.filter { !$0.isEmpty }
    }

    /// 判定一个目录像不像 TheosRuntime：要有 usr/bin 或 bin，并且能找到 make/clang 之一
    static func looksLikeRuntime(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        let probes = [
            "/usr/bin/make", "/usr/bin/clang", "/usr/bin/clang-16",
            "/usr/bin/ldid", "/usr/bin/dpkg-deb", "/opt/theos/makefiles",
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
            // 优先用我们自己的 adhoc 签名器：
            // codex-sign 的两种模式在本机都过不了 AMFI（CMS 被拒 / adhoc 报 -67048），
            // 自研实现只写 SHA256 CodeDirectory，正是 TrollStore 装 App 用的格式。
            // 可执行文件附带 entitlements（no-sandbox / platform-application），
            // 库文件不需要 entitlements。
            let lower = path.lowercased()
            let isLibrary = lower.hasSuffix(".dylib") || lower.hasSuffix(".so")
                || lower.contains(".framework/")
            if isLibrary {
                // 库不签：它们已经通过"依赖重定向"不再被加载
                report.skipped += 1
                marker.files[relative(path, to: root)] = fileStamp(path)
                continue
            }
            // 可执行文件用 codex-sign：实测它的签名能被 exec 接受（我们自研的 adhoc
            // 会被 AMFI 判 EBADARCH）。
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
        report.lines.append("完成：重签 \(report.signed)，库跳过 \(report.skipped)，失败 \(report.failed)")
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
        // 越狱环境里是 usr/bin/clang（不是 clang-16），两种都试
        let clangName = FileManager.default.isExecutableFile(atPath: root + "/usr/bin/clang-16")
            ? "usr/bin/clang-16" : "usr/bin/clang"
        let probes: [(String, [String])] = [
            (clangName, ["--version"]),
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

    // MARK: - 自行安装（只装到自己容器，不碰别人的目录）

    static let manifestURL =
        "https://raw.githubusercontent.com/susu123oss/CodexApp-Runtime/main/Runtime/runtime-manifest.json"
    /// GitHub 直连不稳时按顺序尝试的镜像前缀
    static let proxies = ["https://gh-proxy.org/", "https://ghproxy.net/"]

    struct Part {
        let name: String
        let url: String
        var expectedSize: Int = 0
    }

    /// 固定使用**已验证可加载**的那个运行时发布。
    ///
    /// 背景：`runtime-manifest.json` 的 main 分支现在指向 runtime-theos-336408a626ac，
    /// 它里面的 dylib 是 thin arm64、按本机的 AMFI 规则签名无效
    /// （加载时报 "code signature invalid"）。而 MT-Agent 用的
    /// runtime-theos-11caeba3c2d0 是 FAT 二进制，签名在本机能通过。
    /// 这里直接钉住后者；清单只作为兜底。
    static let pinnedRelease = "runtime-theos-11caeba3c2d0"
    static let pinnedParts: [Part] = {
        let base = "https://github.com/susu123oss/CodexApp-Runtime/releases/download/\(pinnedRelease)/TheosRuntime.tar.gz"
        var list: [Part] = []
        for i in 1...5 {
            let name = "TheosRuntime.tar.gz.part0\(i)"
            // 前 4 片各 48 MB，最后一片约 22 MB
            let size = i < 5 ? 50_331_648 : 23_040_723
            list.append(Part(name: name, url: base + ".part0\(i)", expectedSize: size))
        }
        return list
    }()

    /// 从清单里取 theos 运行时的分片列表
    static func fetchParts() async throws -> [Part] {
        guard let u = URL(string: manifestURL) else {
            throw NSError(domain: "NanoTheos", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "清单地址无效"])
        }
        var req = URLRequest(url: u)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "NanoTheos", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "清单下载失败"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = json["runtimes"] as? [String: Any],
              let theos = runtimes["theos"] as? [String: Any]
        else {
            throw NSError(domain: "NanoTheos", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "清单里没有 theos 条目"])
        }
        let raw = (theos["archive_parts"] as? [[String: Any]]) ?? []
        let parts: [Part] = raw.compactMap { p in
            guard let url = p["url"] as? String else { return nil }
            let size = (p["size"] as? NSNumber)?.intValue ?? 0
            return Part(name: (p["name"] as? String) ?? "part", url: url, expectedSize: size)
        }
        if parts.isEmpty, let single = theos["archive_url"] as? String {
            let size = (theos["download_size"] as? NSNumber)?.intValue ?? 0
            return [Part(name: "TheosRuntime.tar.gz", url: single, expectedSize: size)]
        }
        return parts
    }

    /// 下载进度回调（URLSession 的 task delegate，只在 async download 里可用）
    final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Int64, Int64) -> Void
        private var lastLogged: Int64 = 0
        private let step: Int64
        init(step: Int64 = 20 << 20, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.step = step
            self.onProgress = onProgress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten - lastLogged >= step {
                lastLogged = totalBytesWritten
                onProgress(totalBytesWritten, totalBytesExpectedToWrite)
            }
        }
    }

    /// 逐片下载并拼接成一个文件。用 URLSession 的流式下载（落盘，不进内存），
    /// 每 20MB 报一次进度；下完校验字节数与清单一致。
    static func download(_ parts: [Part], to dest: String,
                         log: @escaping (String) -> Void) async throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: dest)
        fm.createFile(atPath: dest, contents: nil)
        guard let out = FileHandle(forWritingAtPath: dest) else {
            throw NSError(domain: "NanoTheos", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建下载文件 \(dest)"])
        }
        defer { try? out.close() }

        var total: Int64 = 0
        for (i, part) in parts.enumerated() {
            log("  下载 \(i + 1)/\(parts.count)：\(part.name)")
            var ok = false
            for prefix in ([""] + proxies) {
                guard let u = URL(string: prefix + part.url) else { continue }
                do {
                    var req = URLRequest(url: u)
                    req.timeoutInterval = 1800
                    let logger = ProgressDelegate { done, expected in
                        let d = Double(done) / 1048576
                        let e = expected > 0 ? String(format: " / %.0f MB", Double(expected) / 1048576) : ""
                        log(String(format: "    %.0f MB%@", d, e))
                    }
                    let (tmp, resp) = try await URLSession.shared.download(for: req, delegate: logger)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        log("    HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                        continue
                    }
                    let size = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? 0
                    if part.expectedSize > 0, size != Int64(part.expectedSize) {
                        log("    大小不符：\(size) != \(part.expectedSize)，换源重试")
                        try? fm.removeItem(at: tmp)
                        continue
                    }
                    let h = try FileHandle(forReadingFrom: tmp)
                    defer { try? h.close() }
                    while true {
                        let chunk = try h.read(upToCount: 1 << 20) ?? Data()
                        if chunk.isEmpty { break }
                        try out.write(contentsOf: chunk)
                        total += Int64(chunk.count)
                    }
                    try? fm.removeItem(at: tmp)
                    ok = true
                    break
                } catch {
                    log("    失败：\(error.localizedDescription)")
                }
            }
            if !ok {
                throw NSError(domain: "NanoTheos", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "分片 \(part.name) 下载失败（直连与代理都不通）"])
            }
        }
        log("  合计 \(String(format: "%.1f", Double(total) / 1048576)) MB")
    }

    /// 解包：用随包的 tarx（只链 libSystem + libz），不走 ca-filetool 的 tar
    /// —— 那个只实现了 create 模式，`tar -xzf` 会直接报
    ///    "only create mode (-c) is supported"。
    static func extract(_ archive: String, to dest: String,
                        log: @escaping (String) -> Void) async throws {
        try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
        let tool = NanoMuseHelperRunner.path("tarx")
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw NSError(domain: "NanoTheos", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "缺少随包的 tarx（构建时没编译进来）"])
        }
        log("  解包中（224 MB → 约 1 GB，需要几分钟）…")
        let run = await Task.detached(priority: .userInitiated) {
            NanoMuseHelperRunner.run(tool, arguments: ["-xf", archive, "-C", dest], timeout: 3600)
        }.value
        log("  tarx rc=\(run.exitCode)")
        if run.exitCode != 0 {
            for l in run.output.split(separator: "\n").suffix(8) { log("    " + String(l)) }
            throw NSError(domain: "NanoTheos", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "解包失败（见上）"])
        }
        if !run.output.isEmpty {
            for l in run.output.split(separator: "\n").suffix(3) { log("    " + String(l)) }
        }
    }

    /// 解包后如果只有一个子目录（例如包内是 TheosRuntime/usr/...），把内容提到根上
    static func flattenIfSingleSubdir(_ root: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: root + "/usr") { return }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root),
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles]) else { return }
        let dirs = items.filter { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            return (v?.isDirectory ?? false)
        }
        guard dirs.count == 1, let names = try? fm.contentsOfDirectory(atPath: dirs[0].path) else { return }
        for name in names {
            try? fm.moveItem(atPath: dirs[0].path + "/" + name, toPath: root + "/" + name)
        }
        try? fm.removeItem(at: dirs[0])
    }

    /// 安装到自己的容器；已存在则直接返回
    static func install(log: @escaping (String) -> Void) async -> Bool {
        if let root = locate() {
            log("已存在：\(root)")
            return true
        }
        log("== 安装 TheosRuntime 到 \(installRoot) ==")
        do {
            var parts = pinnedParts
            log("固定版本：\(pinnedRelease)（\(parts.count) 片）")
            if parts.isEmpty {
                parts = try await fetchParts()
                log("清单分片：\(parts.count) 个")
            }
            let archive = NSTemporaryDirectory() + "TheosRuntime.tar.gz"
            try await download(parts, to: archive, log: log)
            try await extract(archive, to: installRoot, log: log)
            try? FileManager.default.removeItem(atPath: archive)
            flattenIfSingleSubdir(installRoot)      // 有的压缩包多套一层 TheosRuntime/
            let fixed = await repointLibraries(root: installRoot, log: log)
        } catch {
            log("ERR \(error.localizedDescription)")
            try? FileManager.default.removeItem(atPath: installRoot)   // 不留下半包
            return false
        }
        guard looksLikeRuntime(installRoot) else {
            log("ERR 解包完成但没找到 usr/bin/clang-16 —— 目录结构可能不对")
            return false
        }
        log("安装完成：\(installRoot)")
        return true
    }

    /// 把运行时里所有对 `libiosexec` 的依赖改成系统 libSystem。
    /// 这样工具就不需要 mmap 任何第三方 dylib —— 这正是本机沙盒唯一允许的形态。
    @discardableResult
    static func repointLibraries(root: String,
                                 log: @escaping (String) -> Void) async -> Int {
        // 优先用随包的 C 工具：确定性高、能打印每个被改写的文件。
        // （Swift 版曾因为并行 + try? 吞掉异常，静默返回 0。）
        let tool = NanoMuseHelperRunner.path("machrepoint")
        if FileManager.default.isExecutableFile(atPath: tool) {
            let run = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run(tool,
                                         arguments: ["-r", root, "libiosexec",
                                                     "/usr/lib/libSystem.B.dylib"],
                                         timeout: 600)
            }.value
            let lines = run.output.split(separator: "\n")
            let patched = lines.filter { $0.hasPrefix("patched ") }.count
            log("  machrepoint rc=\(run.exitCode)，改写 \(patched) 个文件")
            for l in lines.prefix(5) { log("    " + String(l)) }
            if run.exitCode == 0 { return patched }
            log("  （工具失败，回退到内置实现）")
        }

        // 回退：内置 Swift 实现（串行，带错误输出）
        let targets = machOs(under: root)
        var changed = 0
        var found = 0
        var skipped = 0
        var errors: [String] = []
        for path in targets {
            do {
                let r = try NanoMuseMachPatcher.repoint(path: path,
                                                        matching: "libiosexec",
                                                        to: "/usr/lib/libSystem.B.dylib")
                found += r.found
                skipped += r.skipped
                changed += r.patched
            } catch {
                if errors.count < 3 { errors.append("\(relative(path, to: root)): \(error.localizedDescription)") }
            }
        }
        log("  内置扫描 \(targets.count) 个 Mach-O，命中 \(found)，改写 \(changed)，跳过 \(skipped)")
        for e in errors { log("    " + e) }
        return changed
    }

    /// 一键：安装 → 重签 → 自检
    static func prepareAll(log: @escaping (String) -> Void) async -> [String] {
        var lines: [String] = []
        func emit(_ s: String) { lines.append(s); log(s) }
        guard await install(log: emit) else { return lines }
        guard let root = locate() else { emit("ERR 仍找不到 runtime"); return lines }
        // 已存在的运行时也要重定向（幂等）：把 libiosexec 依赖改到系统 libSystem
        let patched = await repointLibraries(root: root, log: emit)
        emit("依赖重定向：\(patched) 个二进制已改为链接系统库")
        let r = await resign(at: root)
        for l in r.lines { emit(l) }
        for l in await smokeTest(root: root) { emit(l) }
        return lines
    }

    // MARK: - 增量标记

    static let markerVersion = 9
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
        // Theos 需要 $THEOS/bin（dm.pl / fakeroot.sh …）在 PATH 里
        var bin = [root + "/usr/bin", root + "/bin"].filter { fm.fileExists(atPath: $0) }
        if fm.fileExists(atPath: root + "/theos/bin") { bin.append(root + "/theos/bin") }
        let base = NanoMuseHelperRunner.helpersDirectory
        env["PATH"] = (bin + [base, "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        let libs = [root + "/usr/lib", root + "/lib"].filter { fm.fileExists(atPath: $0) }
        if !libs.isEmpty {
            env["DYLD_LIBRARY_PATH"] = libs.joined(separator: ":")
            env["DYLD_FALLBACK_LIBRARY_PATH"] = libs.joined(separator: ":")
        }
        // THEOS 必须指向真正含 makefiles 的那一层：
        // 本运行时里是 <root>/theos（同时有 theos/bin、theos/sdks），不是 <root>。
        env["TOOLCHAIN_ROOT"] = root
        if fm.fileExists(atPath: root + "/theos/makefiles") {
            env["THEOS"] = root + "/theos"
        } else if fm.fileExists(atPath: root + "/opt/theos/makefiles") {
            env["THEOS"] = root + "/opt/theos"
        } else if fm.fileExists(atPath: root + "/makefiles") {
            env["THEOS"] = root
        }
        if fm.fileExists(atPath: root + "/theos/sdks") {
            env["THEOS_SDK_ROOT"] = root + "/theos/sdks"
        }
        let dpkg = root + "/usr/bin/dpkg-deb"
        if fm.isExecutableFile(atPath: dpkg) {
            env["_THEOS_PLATFORM_DPKG_DEB"] = dpkg
        }
        return env
    }
}
