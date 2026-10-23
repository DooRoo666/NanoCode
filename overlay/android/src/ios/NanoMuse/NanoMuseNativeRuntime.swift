import Foundation
import CryptoKit
import Combine

/// 原生运行时安装器（对齐 MT-Agent 的真实形态）。
///
/// 为什么需要它：原版清单里的包是 **iOS 原生** 产物——
///   · codex 的 asset 是 `wiki.qaq.codex_…_iphoneos-arm64.deb`
///   · theos 带 `iPhoneOS16.5.sdk`，解包 934 MB
///   · node 的持久路径是 `Library/Application Support/CodexApp/Node/prefix/bin`
/// 这些是 Mach-O，塞进 Alpine（Linux ELF 环境）跑不起来，必须解到 App 容器里、
/// 由 `NanoMuseHelperRunner` 用 posix_spawn 起。
enum NanoMuseNativeRuntime {

    /// 安装日志：MainActor 隔离 + @Published，界面直接观察，避免跨线程改 @State。
    @MainActor
    final class Log: ObservableObject {
        @Published private(set) var lines: [String] = []

        func add(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lines.append(trimmed)
            if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        }

        func clear() { lines.removeAll() }
    }

    struct Installed: Sendable {
        let id: String
        let root: String
        let installedAt: Date
    }

    /// `Library/Application Support/NanoCodex/runtimes`
    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("NanoCodex/runtimes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func directory(for id: String) -> URL {
        rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: id).appendingPathComponent(".installed").path)
    }

    static func installedIDs() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)) ?? []
        return contents.filter { isInstalled($0) }
    }

    /// 卸载：删掉整个运行时目录
    @discardableResult
    static func uninstall(_ id: String) -> Bool {
        let dir = directory(for: id)
        do {
            try FileManager.default.removeItem(at: dir)
            return true
        } catch {
            return false
        }
    }

    // MARK: - 安装主流程

    static func install(_ package: NanoMuseRuntimeManifest.Package,
                        proxies: [String],
                        log: Log) async -> Bool {

        await log.add("STEP 1/5 准备")
        await log.add("  目标：\(directory(for: package.id).path)")
        await log.add("  大小：\(package.sizeText)")

        // 依赖 / 冲突门禁（清单里的 requires / conflicts）
        let missing = package.requires.filter { !isInstalled($0) }
        if !missing.isEmpty {
            await log.add("ERR 需要先安装：\(missing.joined(separator: ", "))")
            return false
        }
        let conflicted = package.conflicts.filter { isInstalled($0) }
        if !conflicted.isEmpty {
            await log.add("ERR 与已安装的 \(conflicted.joined(separator: ", ")) 冲突")
            return false
        }

        let destination = directory(for: package.id)

        // ---- 下载 ----
        await log.add("STEP 2/5 下载")
        guard let archive = await download(package.archiveURL, proxies: proxies, log: log) else {
            await log.add("ERR 下载失败（直连与代理都不可用）")
            return false
        }
        await log.add("  已落地：\(archive.lastPathComponent)")

        // ---- 校验 ----
        await log.add("STEP 3/5 校验 SHA256")
        let digest = (try? sha256(of: archive)) ?? ""
        await log.add("  期望：\(package.sha256)")
        await log.add("  实际：\(digest)")
        guard !package.sha256.isEmpty, digest == package.sha256 else {
            await log.add("ERR sha256 不匹配，已丢弃")
            try? FileManager.default.removeItem(at: archive)
            return false
        }

        // ---- 解包 ----
        await log.add("STEP 4/5 解包")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let payload = await preparePayload(archive: archive, log: log) else {
            await log.add("ERR 无法准备解包载荷（不支持的压缩格式）")
            return false
        }
        guard await extract(payload: payload, into: destination, log: log) else {
            await log.add("ERR 解包失败（ca-filetool tar 返回非 0）")
            return false
        }
        try? FileManager.default.removeItem(at: archive)

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        await log.add("  内容：\(entries.prefix(6).joined(separator: " "))")

        // 单层目录归一
        if entries.count == 1, let only = entries.first,
           !FileManager.default.fileExists(atPath: destination.appendingPathComponent("bin").path) {
            let inner = destination.appendingPathComponent(only)
            await log.add("  归一化单层目录：\(only)")
            for child in (try? FileManager.default.contentsOfDirectory(atPath: inner.path)) ?? [] {
                try? FileManager.default.moveItem(at: inner.appendingPathComponent(child),
                                                  to: destination.appendingPathComponent(child))
            }
            try? FileManager.default.removeItem(at: inner)
        }

        // ---- 权限 / 签名 / 探测 ----
        await log.add("STEP 5/5 权限与探测")
        let executables = makeExecutable(destination)
        await log.add("  可执行文件：\(executables) 个")

        let signed = await attemptSign(destination, log: log)
        await log.add("  签名：\(signed) 个")

        try? Data("\(package.sha256)\n".utf8)
            .write(to: destination.appendingPathComponent(".installed"))

        if let binary = probeBinary(package: package, root: destination) {
            let output = await probe(binary: binary, arguments: package.probeArguments)
            await log.add("  探测输出：\(String(output.prefix(200)))")
            if let expected = package.probeContains, !expected.isEmpty {
                await log.add(output.contains(expected) ? "  probe 通过" : "  probe 未匹配（仍算安装完成）")
            }
        } else {
            await log.add("  （清单未给探测命令）")
        }
        await log.add("STEP done")
        return true
    }

    // MARK: - 下载（直连 → 代理回退）

    private static func download(_ urlString: String,
                                 proxies: [String],
                                 log: Log) async -> URL? {
        for prefix in ([""] + proxies) {
            guard let url = URL(string: prefix + urlString) else { continue }
            await log.add("  尝试：\(prefix.isEmpty ? "直连" : prefix)")
            do {
                let (file, response) = try await URLSession.shared.download(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    await log.add("    HTTP \(status)")
                    continue
                }
                let suffix: String
                if urlString.hasSuffix(".gz") { suffix = "tar.gz" }
                else if urlString.hasSuffix(".deb") { suffix = "deb" }
                else if urlString.hasSuffix(".xz") { suffix = "tar.xz" }
                else if urlString.hasSuffix(".zst") { suffix = "tar.zst" }
                else { suffix = "bin" }

                let target = FileManager.default.temporaryDirectory
                    .appendingPathComponent("rt-\(UUID().uuidString.prefix(6)).\(suffix)")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: file, to: target)
                let attributes = try? FileManager.default.attributesOfItem(atPath: target.path)
                let size = (attributes?[.size] as? Int) ?? 0
                await log.add("    完成：\(size / 1048576) MB")
                return target
            } catch {
                await log.add("    失败：\(error.localizedDescription)")
            }
        }
        return nil
    }

    // MARK: - SHA256（流式，避免 200 MB 进内存）

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - deb / tar 载荷准备

    private static func preparePayload(archive: URL, log: Log) async -> URL? {
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return archive }
        guard name.hasSuffix(".deb") else {
            await log.add("  不支持：\(name)（仅支持 .deb 与 .tar.gz）")
            return nil
        }
        return await arExtract(archive: archive, matchingPrefix: "data.tar", log: log)
    }

    /// 极简 `ar` 读取器：`!<arch>\n` + 60 字节头。
    private static func arExtract(archive: URL, matchingPrefix: String, log: Log) async -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 8), magic == Data("!<arch>\n".utf8) else {
            await log.add("  不是 ar 归档")
            return nil
        }
        while true {
            guard let header = try? handle.read(upToCount: 60), header.count == 60 else { break }
            let nameField = header.subdata(in: 0..<16)
            let sizeField = header.subdata(in: 48..<58)
            let name = String(decoding: nameField, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/", with: "")
            let size = Int(String(decoding: sizeField, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)) ?? 0
            await log.add("  ar 成员：\(name.isEmpty ? "(长名)" : name) \(size) B")
            guard size > 0 else { continue }

            if name.hasPrefix(matchingPrefix) {
                guard let payload = try? handle.read(upToCount: size) else { return nil }
                let suffix = name.hasSuffix(".xz") ? "xz" : (name.hasSuffix(".zst") ? "zst" : "gz")
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("payload-\(UUID().uuidString.prefix(6)).tar.\(suffix)")
                try? payload.write(to: out)
                if suffix == "gz" { return out }
                await log.add("  deb 内层为 .\(suffix)，原生解包不支持（可改用 Alpine 路线）")
                return nil
            }
            let skip = UInt64(size % 2 == 0 ? size : size + 1)
            try? handle.seek(toOffset: handle.offsetInFile + skip)
        }
        await log.add("  deb 里没找到 \(matchingPrefix)")
        return nil
    }

    /// 用随包的 ca-filetool（多调用工具，含 tar）解包，避免在 Swift 里实现 tar。
    private static func extract(payload: URL, into destination: URL, log: Log) async -> Bool {
        guard NanoMuseHelperRunner.exists("ca-filetool") else {
            await log.add("  缺少 ca-filetool，无法解包")
            return false
        }
        // tar 可能是几百 MB 的活，放后台线程，别占主线程
        let result = await Task.detached(priority: .userInitiated) {
            NanoMuseHelperRunner.run(
                "ca-filetool",
                arguments: ["tar", "xzf", payload.path, "-C", destination.path],
                timeout: 900
            )
        }.value
        await log.add("  tar 退出码：\(result.exitCode)")
        for line in result.output.split(separator: "\n").suffix(3) {
            await log.add("  \(line)")
        }
        return result.exitCode == 0
    }

    // MARK: - 权限 / 签名 / 探测

    @discardableResult
    private static func makeExecutable(_ root: URL) -> Int {
        var count = 0
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: [.isRegularFileKey],
                                                             options: []) else { return 0 }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard isMachO(url) else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            count += 1
        }
        return count
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        try? handle.close()
        let magic = [UInt8](head)
        return magic == [0xCF, 0xFA, 0xED, 0xFE]
            || magic == [0xCE, 0xFA, 0xED, 0xFE]
            || magic == [0xCA, 0xFE, 0xBA, 0xBE]
    }

    /// 尽力用随包的 codex-sign 做 ad-hoc 签名；失败不阻断（App 已无沙盒）。
    private static func attemptSign(_ root: URL, log: Log) async -> Int {
        guard NanoMuseHelperRunner.exists("codex-sign") else {
            await log.add("  （未随包 codex-sign，跳过）")
            return 0
        }
        var targets: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: []) {
            for case let url as URL in enumerator where isMachO(url) { targets.append(url) }
        }
        var signed = 0
        for url in targets {
            let result = await Task.detached(priority: .utility) {
                NanoMuseHelperRunner.run("codex-sign", arguments: ["--adhoc-only", url.path], timeout: 60)
            }.value
            if result.exitCode == 0 { signed += 1 }
        }
        return signed
    }

    private static func probeBinary(package: NanoMuseRuntimeManifest.Package, root: URL) -> String? {
        guard let first = package.probeArguments.first else { return nil }
        let candidate = first.contains("/")
            ? root.appendingPathComponent(first)
            : root.appendingPathComponent("bin/\(first)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    private static func probe(binary: String, arguments: [String]) async -> String {
        let escaped = arguments.dropFirst()
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let (_, output) = await NanoMuseCodex.runCommand("'\(binary)' \(escaped) 2>&1 | head -5", timeout: 60)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 清单里的 `install.environment`：把 `${RUNTIME_ROOT}` 换成本地路径
    static func environment(for package: NanoMuseRuntimeManifest.Package) -> [String: String] {
        let root = directory(for: package.id).path
        return package.environment.mapValues {
            $0.replacingOccurrences(of: "${RUNTIME_ROOT}", with: root)
        }
    }
}
