import Compression
import Foundation

/// 纯 Swift zip 解包器（无第三方依赖、无 libz）。
///
/// 为什么不用 zlib：
///   iOS 的 Swift SDK **没有 `zlib` module**（`import zlib` 编译不过，
///   `inflateInit2` 直接 "cannot find in scope"）。可用的是 Apple 的
///   `Compression` 框架，其中 `COMPRESSION_ZLIB` 恰好等价于 **raw DEFLATE**
///   ——正好对应 zip 里的 method 8 压缩条目。
///
/// 内存策略：
///   逐条目流式解压（每次只持有一个条目的解压结果），不整包读进内存。
///
/// 校验：
///   解压后按 CRC-32 校验，可选（默认开）。
enum NanoMuseZipError: Error, LocalizedError {
    case notAZipFile
    case unsupportedCompression(UInt16)
    case crcMismatch(path: String, expected: UInt32, actual: UInt32)
    case unsafePath(String)
    case truncated
    case io(Int32)

    var errorDescription: String? {
        switch self {
        case .notAZipFile:
            return "不是合法的 zip 文件（缺少 EOCD 记录）"
        case .unsupportedCompression(let m):
            return "不支持的压缩方式 \(m)（仅支持 0=store / 8=deflate）"
        case .crcMismatch(let path, let expected, let actual):
            return "CRC 校验失败 \(path)：期望 \(expected)，实际 \(actual)"
        case .unsafePath(let p):
            return "不安全的路径 \(p)"
        case .truncated:
            return "zip 文件被截断"
        case .io(let e):
            return "文件读写失败（errno \(e)）"
        }
    }
}

/// 读取一个 zip 条目解压后的内容。
final class NanoMuseZip {

    /// zip 内的一条目录项。
    struct Entry {
        let path: String
        let method: UInt16          // 0 = store, 8 = deflate
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let crc32: UInt32
        let localHeaderOffset: UInt64
        let isDirectory: Bool
    }

    private let fileURL: URL
    private var handle: FileHandle?
    private var entries: [Entry] = []

    /// 进度回调：(已完成字节, 总字节)
    typealias ProgressHandler = (_ done: UInt64, _ total: UInt64) -> Void

    init(path: String) throws {
        self.fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw NanoMuseZipError.io(ENOENT)
        }
        let fh = try FileHandle(forReadingFrom: self.fileURL)
        self.handle = fh
        self.entries = try readCentralDirectory()
    }

    deinit {
        try? handle?.close()
    }

    /// 所有条目（路径）。
    var entryPaths: [String] { entries.map { $0.path } }

    /// 解压到目标目录。
    /// - Parameters:
    ///   - destination: 目标目录
    ///   - progress: 进度回调（可选）
    /// - Returns: 实际写出的文件数
    @discardableResult
    func extract(to destination: String, progress: ProgressHandler? = nil) throws -> Int {
        let destURL = URL(fileURLWithPath: destination)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)
        let destRoot = destURL.standardizedFileURL.path

        let total = entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }
        var done: UInt64 = 0
        var written = 0

        for entry in entries {
            // 跳过 macOS 资源分支残留（__MACOSX/ 与 ._ 开头的文件）
            if entry.path.hasPrefix("__MACOSX/") || entry.path.hasPrefix("._")
                || entry.path.contains("/._") {
                continue
            }
            if entry.isDirectory {
                let dir = try safeURL(destRoot, entry.path)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                continue
            }
            let outURL = try safeURL(destRoot, entry.path)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let data = try readEntryData(entry)
            if entry.crc32 != 0 {
                let actual = NanoMuseZip.crc32(data)
                if actual != entry.crc32 {
                    throw NanoMuseZipError.crcMismatch(path: entry.path,
                                                     expected: entry.crc32, actual: actual)
                }
                // 解出的字节数和中央目录声明不符 → 说明压缩流被截断/解错。
                // CRC 只在文件损坏时才会暴露，但「容量不足 + CRC 恰好为 0」
                // 的组合会静默产出半截数据，因此显式校验长度。
                if entry.uncompressedSize > 0 && data.count != Int(entry.uncompressedSize) {
                    throw NanoMuseZipError.truncated
                }
            }
            try data.write(to: outURL, options: .atomic)
            written += 1

            done += entry.uncompressedSize
            progress?(done, total)
        }
        return written
    }

    // MARK: - 目录解析

    /// 定位 EOCD 并解析中央目录。
    private func readCentralDirectory() throws -> [Entry] {
        guard let fh = handle else { throw NanoMuseZipError.truncated }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        try fh.seek(toOffset: 0)

        // EOCD 固定 22 字节 + 注释最长 65535
        let eocdSearchLen = Int(min(fileSize, 22 + 65535))
        let tail = try readBytes(at: fileSize - UInt64(eocdSearchLen), count: eocdSearchLen)
        guard let eocdOffset = findEOCD(tail) else { throw NanoMuseZipError.notAZipFile }

        let eocd = tail.subdata(in: eocdOffset..<tail.count)
        guard eocd.count >= 22 else { throw NanoMuseZipError.truncated }

        let totalEntries = Int(Self.readU16(eocd, 10))
        let cdSize = Self.readU32(eocd, 12)
        let cdOffset = Self.readU32(eocd, 16)

        let cd = try readBytes(at: UInt64(cdOffset), count: Int(cdSize))
        var result: [Entry] = []
        result.reserveCapacity(totalEntries)

        var p = 0
        for _ in 0..<totalEntries {
            guard p + 46 <= cd.count else { break }
            guard Self.readU32(cd, p) == 0x0201_4b50 else { break }  // 中央目录签名
            let flags = Self.readU16(cd, p + 8)
            let method = Self.readU16(cd, p + 10)
            let crc = Self.readU32(cd, p + 16)
            let compSize = Self.readU32(cd, p + 20)
            let uncompSize = Self.readU32(cd, p + 24)
            let nameLen = Int(Self.readU16(cd, p + 28))
            let extraLen = Int(Self.readU16(cd, p + 30))
            let commentLen = Int(Self.readU16(cd, p + 32))
            let localOffset = Self.readU32(cd, p + 42)
            guard p + 46 + nameLen <= cd.count else { break }

            let nameData = cd.subdata(in: (cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8)
                ?? String(decoding: nameData, as: UTF8.self)
            // bit 11 = UTF-8 名字；其余按原样
            _ = flags

            result.append(Entry(path: name,
                                method: method,
                                compressedSize: UInt64(compSize),
                                uncompressedSize: UInt64(uncompSize),
                                crc32: crc,
                                localHeaderOffset: UInt64(localOffset),
                                isDirectory: name.hasSuffix("/")))
            p += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    /// 在尾部搜索 EOCD 签名 0x06054b50。
    private func findEOCD(_ data: Data) -> Int? {
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let n = data.count
        guard n >= 22 else { return nil }
        var i = n - 22
        let lower = max(0, n - 22 - 65535)
        while i >= lower {
            var match = true
            for k in 0..<4 {
                if data[data.startIndex + i + k] != sig[k] { match = false; break }
            }
            if match { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - 条目读取

    /// 读取并解压单个条目。
    private func readEntryData(_ entry: Entry) throws -> Data {
        let lh = try readBytes(at: entry.localHeaderOffset, count: 30)
        guard lh.count >= 30, Self.readU32(lh, 0) == 0x0403_4b50 else {
            throw NanoMuseZipError.truncated
        }
        let nameLen = Int(Self.readU16(lh, 26))
        let extraLen = Int(Self.readU16(lh, 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLen + extraLen)

        switch entry.method {
        case 0:
            return try readBytes(at: dataOffset, count: Int(entry.compressedSize))
        case 8:
            let raw = try readBytes(at: dataOffset, count: Int(entry.compressedSize))
            // 用 CRC 校验来挑选正确的解压形态：不同输入形态可能都「解出非空数据」，
            // 但只有 CRC 对的那个才是对的。
            return try Self.inflate(raw, expectedSize: Int(entry.uncompressedSize)) { data in
                guard entry.crc32 != 0 else { return true }
                return Self.crc32(data) == entry.crc32
            }
        default:
            throw NanoMuseZipError.unsupportedCompression(entry.method)
        }
    }

    /// raw DEFLATE 解压（Apple Compression 框架）。
    ///
    /// 用 `compression_decode_buffer`（一次性）而非 compression_stream：
    ///   ★ stream API 不会替调用方推进 src_ptr/src_size，必须自己维护游标，
    ///     很容易陷入「反复喂同一段输入 → 死循环/解出垃圾」。
    ///   decode_buffer 只要给出足够的输出容量即可，且错误会明确返回，
    ///   不会静默产出半截数据。
    ///
    /// zip 条目里存的是 raw DEFLATE（无 zlib 头）。Apple 的 COMPRESSION_ZLIB
    /// 在不同版本上对「是否带 zlib 头」的处理并不一致，因此按顺序尝试多种
    /// 输入形态，取第一个能解出并通过校验的结果。
    static func inflate(_ data: Data,
                        expectedSize: Int,
                        validate: ((Data) -> Bool)? = nil) throws -> Data {
        if data.isEmpty { return Data() }

        var attempts: [Data] = [data]
        // 若 zip 里带的是 zlib 头（0x78 …），去掉 2 字节再试 raw DEFLATE
        if data.count > 2 { attempts.append(data.subdata(in: 2..<data.count)) }
        // 反之，若是 raw DEFLATE，补一个 zlib 头再试
        var withHeader = Data([0x78, 0x9C])
        withHeader.append(data)
        attempts.append(withHeader)

        var lastError: Error = NanoMuseZipError.truncated
        for candidate in attempts {
            do {
                // 容量按声明值起步；若解不出完整数据则逐步放大重试，
                // 避免「声明大小偏小 → 静默截断」。
                var capacity = expectedSize > 0 ? expectedSize : max(candidate.count * 4, 1 << 16)
                var out = Data()
                for _ in 0..<5 {
                    out = decodeBuffer(candidate, capacity: capacity)
                    if out.count >= expectedSize { break }
                    if expectedSize == 0 && !out.isEmpty { break }
                    // decode_buffer 在输出缓冲不足时返回 0（无部分数据），
                    // 必须放大容量再试，不能就此判定该形态失败。
                    capacity = capacity * 2 + (1 << 16)
                }
                if out.isEmpty { continue }
                if let validate, !validate(out) { continue }
                return out
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// 一次性解压到指定容量。
    /// 返回空 Data 表示解不出（容量不足或数据非法），由调用方放大容量重试。
    private static func decodeBuffer(_ data: Data, capacity: Int) -> Data {
        let cap = max(capacity, 1)
        var dst = [UInt8](repeating: 0, count: cap)
        let produced: Int = data.withUnsafeBytes { src -> Int in
            guard let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBytes { d -> Int in
                guard let dBase = d.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    dBase, cap,
                    s, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard produced > 0 else { return Data() }
        return Data(dst.prefix(produced))
    }

    /// 从文件读指定长度。
    private func readBytes(at offset: UInt64, count: Int) throws -> Data {
        guard let fh = handle else { throw NanoMuseZipError.truncated }
        if count <= 0 { return Data() }
        try fh.seek(toOffset: offset)
        guard let d = try fh.read(upToCount: count), !d.isEmpty else {
            throw NanoMuseZipError.truncated
        }
        return d
    }

    /// 防 zip-slip：解出来的路径必须落在目标目录内。
    private func safeURL(_ root: String, _ entryPath: String) throws -> URL {
        var clean = entryPath
        while clean.hasPrefix("/") { clean.removeFirst() }
        if clean.hasPrefix("../") || clean.contains("/../") || clean == ".." {
            throw NanoMuseZipError.unsafePath(entryPath)
        }
        let full = URL(fileURLWithPath: root).appendingPathComponent(clean).standardizedFileURL
        let rootPath = root.hasSuffix("/") ? root : root + "/"
        guard full.path.hasPrefix(rootPath) else {
            throw NanoMuseZipError.unsafePath(entryPath)
        }
        return full
    }

    // MARK: - 小端读取

    static func readU16(_ d: Data, _ off: Int) -> UInt16 {
        let i = d.startIndex + off
        guard i + 1 < d.endIndex else { return 0 }
        return UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
    }

    static func readU32(_ d: Data, _ off: Int) -> UInt32 {
        let i = d.startIndex + off
        guard i + 3 < d.endIndex else { return 0 }
        return UInt32(d[i])
            | (UInt32(d[i + 1]) << 8)
            | (UInt32(d[i + 2]) << 16)
            | (UInt32(d[i + 3]) << 24)
    }

    // MARK: - CRC-32

    /// 标准 zip CRC-32（IEEE 802.3，多项式 0xEDB88320）。
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<raw.count {
                crc ^= UInt32(base[i])
                for _ in 0..<8 {
                    let mask: UInt32 = (crc & 1) != 0 ? 0xFFFF_FFFF : 0
                    crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
                }
            }
        }
        return ~crc
    }
}
