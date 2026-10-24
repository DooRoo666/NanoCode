import Compression
import Foundation

/// 本地打包 tipa —— 完全复刻 MT-Agent 的「不 fork」路线。
///
/// 为什么必须这么写：iOS SDK 把 `fork()` 标为 unavailable，宿主侧任何
/// 「复制自己再执行」的工具（make / clang / zip 的子进程）都活不下来。
/// 所以这里每一步都刻意避开 fork：
///
///   · 遍历 / 复制 / 建目录 → 进程内 FileManager，不创建进程
///   · 签名 → 随包 `codex-sign`，用 posix_spawn 启动（不是 fork）
///   · 压缩 → Compression.framework，进程内 raw deflate
///   · 打包 → 自己写 ZIP 结构（不依赖 zip 命令，也没有子进程）
///
/// 结果：即使 fork 在这台设备上是坏的，也能在本地产出可安装的 .tipa。
public enum NanoMuseTipaBuilder {

    public struct Report: Sendable {
        public var ok = false
        public var tipa: String?
        public var bytes: Int64 = 0
        public var signed = 0
        public var kept = 0
        public var failed = 0
        public var lines: [String] = []

        public var text: String { lines.joined(separator: "\n") }
    }

    // MARK: - 入口

    /// 把一个 .app 打成 tipa。`appPath` 传 `Bundle.main.bundlePath` 就是「把本 App 打包」。
    /// 默认先复制到临时目录再签名——App 自身的 bundle 是只读挂载，原地签会失败。
    public static func build(appPath: String,
                             entitlements: String? = nil,
                             outputName: String? = nil) async -> Report {
        var report = Report()
        let fm = FileManager.default
        let src = URL(fileURLWithPath: appPath)

        guard fm.fileExists(atPath: src.path) else {
            report.lines.append("ERR 路径不存在：\(appPath)")
            return report
        }
        guard src.pathExtension.lowercased() == "app" else {
            report.lines.append("ERR 不是 .app：\(appPath)")
            return report
        }

        let started = Date()
        report.lines.append("== 本地打包 tipa（不 fork）==")
        report.lines.append("源：\(src.path)")

        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tipa-build-\(UUID().uuidString)", isDirectory: true)
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let staged = payload.appendingPathComponent(src.lastPathComponent, isDirectory: true)

        defer { try? fm.removeItem(at: work) }

        do {
            try fm.createDirectory(at: payload, withIntermediateDirectories: true)
            report.lines.append("[1/4] 复制到临时目录…")
            try fm.copyItem(at: src, to: staged)
            report.lines.append("      完成（\(sizeText(staged))）")
        } catch {
            report.lines.append("ERR 复制失败：\(error.localizedDescription)")
            return report
        }

        report.lines.append("[2/4] 签名 Mach-O（codex-sign，posix_spawn）…")
        let ent = entitlements
            ?? (fm.fileExists(atPath: staged.appendingPathComponent("entitlements.plist").path)
                ? staged.appendingPathComponent("entitlements.plist").path
                : Bundle.main.bundlePath + "/entitlements.plist")
        let useEnt = fm.fileExists(atPath: ent) ? ent : nil
        report.lines.append(useEnt == nil
            ? "      没有 entitlements.plist → 全部 ad-hoc"
            : "      主程序用 \(useEnt!.split(separator: "/").last ?? "entitlements.plist")")

        let hostExecutable = executableName(in: staged)
        let targets = machOFiles(under: staged)
        report.lines.append("      发现 \(targets.count) 个 Mach-O")
        let rootPrefix = staged.path + "/"
        for file in targets {
            let relative = file.path.hasPrefix(rootPrefix)
                ? String(file.path.dropFirst(rootPrefix.count))
                : file.lastPathComponent
            let isMain = relative == hostExecutable

            // Helpers 里的 bash.real / codex-sign / ca-filetool 是原版发布时签好的：
            // 它们带着完整的巨魔权限，重签会被 codex-sign 拒绝（rc=200），
            // 而且改了反而破坏原签名。原样保留。
            if relative.hasPrefix("Helpers/") {
                report.kept += 1
                continue
            }
            // 已经有代码签名的（Xcode 产出的 dylib / appex）也不重签，
            // 只对主程序做「带 entitlements 的重签」。
            if !isMain, hasCodeSignature(file) {
                report.kept += 1
                continue
            }

            // codex-sign 的参数形态不止一种：逐个试，成功即止
            var attempts: [[String]] = []
            if isMain, let useEnt {
                attempts.append(["--entitlements", useEnt, file.path])
            }
            attempts.append(["--adhoc-only", file.path])
            attempts.append([file.path])

            var done = false
            var lastCode: Int32 = -1
            for args in attempts {
                let run = await Task.detached(priority: .userInitiated) {
                    NanoMuseHelperRunner.run("codex-sign", arguments: args, timeout: 180)
                }.value
                lastCode = run.exitCode
                if run.exitCode == 0 { done = true; break }
            }
            if done {
                report.signed += 1
            } else {
                // 签不上不阻断：原签名还在，包依然可用
                report.failed += 1
                if report.lines.count < 400 {
                    report.lines.append("      未签（rc=\(lastCode)，保留原签名）：\(relative)")
                }
            }
        }
        report.lines.append("      重签 \(report.signed)，保留原签名 \(report.kept)，未签 \(report.failed)")

        report.lines.append("[3/4] 打包 ZIP（进程内，无子进程）…")
        let name = outputName ?? "\(src.deletingPathExtension().lastPathComponent).tipa"
        let out = documentsURL().appendingPathComponent(name)
        try? fm.removeItem(at: out)
        do {
            try writeZip(root: work, to: out)
            let attrs = try? fm.attributesOfItem(atPath: out.path)
            report.bytes = (attrs?[.size] as? Int64) ?? 0
            report.lines.append("      \(out.path)")
            report.lines.append("      大小 \(sizeText(out))")
        } catch {
            report.lines.append("ERR 打包失败：\(error.localizedDescription)")
            return report
        }

        report.lines.append("[4/4] 校验…")
        let magic = (try? Data(contentsOf: out, options: .mappedIfSafe).prefix(4)) ?? Data()
        let looksZip = magic == Data([0x50, 0x4B, 0x03, 0x04])
        report.lines.append("      头部 \(looksZip ? "PK\\x03\\x04 ✓" : "异常 ✗")")
        report.ok = looksZip && report.bytes > 0
        report.tipa = report.ok ? out.path : nil
        let cost = Date().timeIntervalSince(started)
        report.lines.append(String(format: "== %@ · 用时 %.1fs ==", report.ok ? "打包完成" : "打包失败", cost))
        if report.ok {
            report.lines.append("装法：TrollStore / Filza 打开该文件即可。")
        }
        return report
    }

    // MARK: - 路径与体积

    static func documentsURL() -> URL {
        (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                      appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
    }

    private static func sizeText(_ url: URL) -> String {
        ByteCountFormatter.string(fromByteCount: directorySize(url), countStyle: .file)
    }

    /// 目录要递归求和 —— 直接读目录 inode 会得到「2 KB」这种假数字。
    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? Int64) ?? 0
        }
        var total: Int64 = 0
        if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) {
            for case let file as URL in walker {
                guard let values = try? file.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// 读 Mach-O 头判断有没有 LC_CODE_SIGNATURE。
    /// 已有签名的不去动它（codex-sign 对已签名文件返回 200，且原签名往往更好）。
    /// fat/其它容器一律保守当作「已签名」。
    private static func hasCodeSignature(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 32), head.count >= 28 else { return true }
        let bytes = [UInt8](head)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
        let magic = u32(0)
        guard magic == 0xFEEDFACF || magic == 0xFEEDFACE else { return true }
        let commandCount = u32(16)
        var offset = magic == 0xFEEDFACF ? 32 : 28
        for _ in 0..<min(commandCount, 4096) {
            guard let raw = try? handle.read(upToCount: 8), raw.count == 8 else { break }
            let cmds = [UInt8](raw)
            let command = UInt32(cmds[0]) | (UInt32(cmds[1]) << 8)
                | (UInt32(cmds[2]) << 16) | (UInt32(cmds[3]) << 24)
            let size = UInt32(cmds[4]) | (UInt32(cmds[5]) << 8)
                | (UInt32(cmds[6]) << 16) | (UInt32(cmds[7]) << 24)
            if command == 0x1d { return true }          // LC_CODE_SIGNATURE
            if size < 8 { break }
            offset += Int(size)
            try? handle.seek(toOffset: UInt64(offset))
        }
        return false
    }

    private static func executableName(in app: URL) -> String? {
        let info = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return app.deletingPathExtension().lastPathComponent }
        return plist["CFBundleExecutable"] as? String
    }

    // MARK: - Mach-O 发现

    private static let machoMagics: Set<UInt32> = [
        0xFEEDFACE, 0xFEEDFACF, 0xCEFAEDFE, 0xCFFAEDFE, 0xCAFEBABE, 0xBEBAFECA,
    ]

    /// Mach-O 判定只看前 4 字节，不读整个文件；签名前后都适用。
    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let bytes = [UInt8](head)
        // 小端拼装；magic 集合里同时含大端写法，因此 fat 也会命中
        let magic = UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
        return machoMagics.contains(magic)
    }

    /// 遍历整棵 bundle，收集所有普通文件的 Mach-O（跳过符号链接，签名跟随真实文件即可）。
    private static func machOFiles(under root: URL) -> [URL] {
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: root,
                                                         includingPropertiesForKeys: keys,
                                                         options: [],
                                                         errorHandler: nil) else { return [] }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile != true { continue }
            if isMachO(url) { result.append(url) }
        }
        return result
    }

    // MARK: - 自己写 ZIP（store + deflate），全程无子进程

    private struct Entry {
        var name: [UInt8]
        var crc: UInt32
        var compressed: UInt64
        var uncompressed: UInt64
        var method: UInt16
        var offset: UInt64
        var externalAttr: UInt32
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ bytes: UnsafeRawBufferPointer, seed: UInt32 = 0) -> UInt32 {
        var crc = seed
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc
    }

    /// 小于该阈值做 deflate；更大的直接 store，避免 128 MB 主程序把内存打满。
    private static let deflateLimit = 24 * 1024 * 1024

    private static func writeZip(root: URL, to output: URL) throws {
        let fm = FileManager.default
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw NSError(domain: "TipaBuilder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建输出文件"])
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var entries: [Entry] = []
        var offset: UInt64 = 0
        var buffer = [UInt8]()

        func emit(_ bytes: [UInt8]) throws {
            if !bytes.isEmpty {
                try handle.write(contentsOf: Data(bytes))
                offset += UInt64(bytes.count)
            }
        }

        func emitData(_ data: Data) throws {
            if !data.isEmpty {
                try handle.write(contentsOf: data)
                offset += UInt64(data.count)
            }
        }

        /// 写一个条目。大文件用 mappedIfSafe（内存映射，不整块驻留）+ store，
        /// 小文件才 deflate —— 这样 128 MB 的主程序也不会把内存打满。
        func addEntry(name: String, data: Data?, linkTarget: String?) throws {
            let nameBytes = Array(name.utf8)
            let localOffset = offset

            let raw: Data
            if let target = linkTarget {
                raw = Data(target.utf8)
            } else if let data {
                raw = data
            } else {
                return
            }

            let crc = raw.withUnsafeBytes { crc32($0, seed: 0xFFFFFFFF) ^ 0xFFFFFFFF }
            var body = raw
            var method: UInt16 = 0
            if linkTarget == nil, raw.count <= deflateLimit, let deflated = deflate(raw) {
                body = deflated
                method = 8
            }

            buffer.removeAll(keepingCapacity: true)
            appendUInt32(&buffer, 0x04034b50)
            appendUInt16(&buffer, 20)
            appendUInt16(&buffer, 0x0800)                       // UTF-8 文件名
            appendUInt16(&buffer, method)
            appendUInt16(&buffer, 0)                            // time
            appendUInt16(&buffer, 0x21)                         // date（1980-01-01）
            appendUInt32(&buffer, crc)
            appendUInt32(&buffer, UInt32(body.count))
            appendUInt32(&buffer, UInt32(raw.count))
            appendUInt16(&buffer, UInt16(nameBytes.count))
            appendUInt16(&buffer, 0)
            buffer.append(contentsOf: nameBytes)
            try emit(buffer)

            try emitData(body)

            entries.append(Entry(name: nameBytes,
                                 crc: crc,
                                 compressed: UInt64(body.count),
                                 uncompressed: UInt64(raw.count),
                                 method: method,
                                 offset: localOffset,
                                 externalAttr: linkTarget == nil ? 0x81A40000 : 0xA1FF0000))
        }

        // 先目录后文件，保持稳定顺序
        let rootName = "Payload"
        var stack: [(URL, String)] = [(root, rootName)]
        var orderedFiles: [(URL, String)] = []
        while let (dir, prefix) = stack.popLast() {
            let children = (try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: [.isDirectoryKey,
                                                                                    .isSymbolicLinkKey],
                                                       options: [])) ?? []
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let name = "\(prefix)/\(child.lastPathComponent)"
                if values?.isSymbolicLink == true {
                    orderedFiles.append((child, name))
                } else if values?.isDirectory == true {
                    stack.append((child, name))
                } else {
                    orderedFiles.append((child, name))
                }
            }
        }

        for (url, name) in orderedFiles {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                try addEntry(name: name, data: nil, linkTarget: target)
            } else {
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let data: Data?
                if (size ?? 0) <= Int64(deflateLimit) {
                    data = try? Data(contentsOf: url)
                } else {
                    // 大文件映射进地址空间，不整块驻留
                    data = try? Data(contentsOf: url, options: .mappedIfSafe)
                }
                guard data != nil else {
                    try addEntry(name: name, data: Data(), linkTarget: nil)
                    continue
                }
                try addEntry(name: name, data: data, linkTarget: nil)
            }
        }

        // 中央目录
        let cdStart = offset
        for entry in entries {
            buffer.removeAll(keepingCapacity: true)
            appendUInt32(&buffer, 0x02014b50)
            appendUInt16(&buffer, 20)                           // version made by
            appendUInt16(&buffer, 20)                           // version needed
            appendUInt16(&buffer, 0x0800)
            appendUInt16(&buffer, entry.method)
            appendUInt16(&buffer, 0)
            appendUInt16(&buffer, 0x21)
            appendUInt32(&buffer, entry.crc)
            appendUInt32(&buffer, UInt32(entry.compressed))
            appendUInt32(&buffer, UInt32(entry.uncompressed))
            appendUInt16(&buffer, UInt16(entry.name.count))
            appendUInt16(&buffer, 0)
            appendUInt16(&buffer, 0)
            appendUInt16(&buffer, 0)
            appendUInt16(&buffer, 0)
            appendUInt32(&buffer, entry.externalAttr)
            appendUInt32(&buffer, UInt32(entry.offset))
            buffer.append(contentsOf: entry.name)
            try emit(buffer)
        }
        let cdSize = offset - cdStart

        buffer.removeAll(keepingCapacity: true)
        appendUInt32(&buffer, 0x06054b50)
        appendUInt16(&buffer, 0)
        appendUInt16(&buffer, 0)
        appendUInt16(&buffer, UInt16(entries.count))
        appendUInt16(&buffer, UInt16(entries.count))
        appendUInt32(&buffer, UInt32(cdSize))
        appendUInt32(&buffer, UInt32(cdStart))
        appendUInt16(&buffer, 0)
        try emit(buffer)
        try handle.synchronize()
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let capacity = data.count + data.count / 2 + 64
        var out = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&out, capacity, src, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written < data.count else { return nil }
        return Data(out[0..<written])
    }

    private static func appendUInt16(_ buffer: inout [UInt8], _ value: UInt16) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendUInt32(_ buffer: inout [UInt8], _ value: UInt32) {
        buffer.append(UInt8(value & 0xFF))
        buffer.append(UInt8((value >> 8) & 0xFF))
        buffer.append(UInt8((value >> 16) & 0xFF))
        buffer.append(UInt8((value >> 24) & 0xFF))
    }
}
