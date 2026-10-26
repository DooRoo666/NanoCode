import Foundation
import Compression

/// 纯 Swift 的 `.tar.gz` 解包器。
///
/// 为什么不用系统 `tar`：第一版 App 还没装任何运行时，命 system("tar") 直接失败，
/// 形成"要先有 tar 才能装 tar"的死结。gz 用 Apple 的 Compression 框架解，
/// tar 格式自己解析（ustar/GNU 长文件名都支持）。
enum NanoMuseTarGz {

    enum TarError: LocalizedError {
        case gzip(String)
        case badHeader(String)
        case pathEscape(String)
        var errorDescription: String? {
            switch self {
            case .gzip(let m): return "解压失败：\(m)"
            case .badHeader(let m): return "tar 头损坏：\(m)"
            case .pathEscape(let p): return "拒绝写入越界路径：\(p)"
            }
        }
    }

    // MARK: - gzip

    /// 用 Compression 框架解 gzip（去掉 18 字节头，跳过尾部 8 字节 CRC/ISIZE）。
    static func gunzip(_ data: Data) throws -> Data {
        guard data.count > 18 else { throw TarError.gzip("数据太短") }
        let magic = [UInt8](data.prefix(2))
        guard magic == [0x1f, 0x8b] else { throw TarError.gzip("不是 gzip") }

        let flag = data[data.startIndex + 3]
        var offset = 10
        // FEXTRA
        if flag & 0x04 != 0 {
            guard data.count > offset + 2 else { throw TarError.gzip("FEXTRA 越界") }
            let xlen = Int(data[data.startIndex + offset])
                | (Int(data[data.startIndex + offset + 1]) << 8)
            offset += 2 + xlen
        }
        // FNAME
        if flag & 0x08 != 0 {
            while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        // FCOMMENT
        if flag & 0x10 != 0 {
            while offset < data.count, data[data.startIndex + offset] != 0 { offset += 1 }
            offset += 1
        }
        // FHCRC
        if flag & 0x02 != 0 { offset += 2 }
        guard offset < data.count else { throw TarError.gzip("头越界") }

        let payload = data.subdata(in: offset..<(data.count - 8))
        return try inflate(payload)
    }

    private static func inflate(_ input: Data) throws -> Data {
        // 解压尺寸未知，按 1MB 起步翻倍重试。
        var capacity = max(1 << 20, input.count * 4)
        let limit = 1 << 31
        while capacity <= limit {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return input.withUnsafeBytes { src -> Int in
                    guard let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(d, capacity, s, input.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < capacity {
                out.removeSubrange(written..<capacity)
                return out
            }
            capacity *= 2
        }
        throw TarError.gzip("解压缓冲区不足")
    }

    // MARK: - tar

    private static let chunk = 512

    private static func octal(_ bytes: ArraySlice<UInt8>) -> Int {
        var v = 0
        for b in bytes {
            if b == 0 || b == 0x20 { continue }
            if b < 0x30 || b > 0x37 { return v }
            v = v * 8 + Int(b - 0x30)
        }
        return v
    }

    private static func str(_ bytes: ArraySlice<UInt8>) -> String {
        var out: [UInt8] = []
        for b in bytes {
            if b == 0 { break }
            out.append(b)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 解包到 dir。返回解出的文件数。
    @discardableResult
    static func unpack(archive: URL, into dir: URL) throws -> Int {
        let raw = try Data(contentsOf: archive)
        // 转成零基数组：tar 切片全部基于 0 起算，避免 Data 的 startIndex 干扰
        let tar = [UInt8](try gunzip(raw))
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = dir.standardizedFileURL
        var pos = 0
        var count = 0
        var pendingLongName: String?

        while pos + chunk <= tar.count {
            let header = tar[pos..<(pos + chunk)]
            // 全零块 = 结束
            if header.allSatisfy({ $0 == 0 }) { break }

            var name = str(header[0..<100])
            let mode = octal(header[100..<108])
            let size = octal(header[124..<136])
            let type = header[156]
            let prefix = str(header[345..<500])

            if !prefix.isEmpty, type != 0x4c { name = prefix + "/" + name }
            if let long = pendingLongName { name = long; pendingLongName = nil }

            pos += chunk
            let dataLen = size
            let padded = ((size + chunk - 1) / chunk) * chunk

            // GNU 长文件名
            if type == 0x4c {
                if dataLen <= tar.count - pos {
                    pendingLongName = str(tar[pos..<(pos + dataLen)])
                }
                pos += padded
                continue
            }
            // pax 扩展头：跳过，正文在下一块
            if type == 0x78 || type == 0x67 {
                pos += padded
                continue
            }

            guard dataLen <= tar.count - pos else {
                throw TarError.badHeader("条目 \(name) 长度越界")
            }
            let body = Data(tar[pos..<(pos + dataLen)])
            pos += padded

            let target = base.appendingPathComponent(name).standardizedFileURL
            guard target.path.hasPrefix(base.path) else {
                throw TarError.pathEscape(name)
            }

            switch type {
            case 0x35, 0x33:   // '5' 目录, '3' 字符设备（当目录）
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case 0x32:         // '2' 符号链接
                let link = str(header[157..<257])
                try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try? fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
                count += 1
            case 0x31:         // '1' 硬链接 → 退化成复制
                let link = str(header[157..<257])
                let srcFile = base.appendingPathComponent(link).standardizedFileURL
                try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                if fm.fileExists(atPath: srcFile.path) {
                    try? fm.copyItem(at: srcFile, to: target)
                }
                count += 1
            default:           // 普通文件
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try body.write(to: target)
                // 还原可执行位
                if mode & 0o111 != 0 {
                    _ = chmod(target.path, mode_t(mode & 0o777))
                }
                count += 1
            }
        }
        return count
    }
}
