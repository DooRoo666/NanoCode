//
//  NanoMuseZip.swift
//  NanoMuse
//
//  流式 ZIP 解包器。
//
//  ★ 用途：从公开开源源 xybp888/iOS-SDKs 的 Release 资产解出 iPhoneOS SDK。
//    该源每个 SDK 一个独立 .zip（26.5 → 48.9MB），远优于整仓 575MB。
//
//  设计要点：
//   1. 流式处理 —— 解压后的 SDK 约 327MB，**绝不整体进内存**，边解边写盘。
//   2. 用 libz 的 inflateInit2(-MAX_WBITS) 解 raw deflate —— 语义确定无歧义。
//      （Compression 框架的 COMPRESSION_ZLIB 对 raw deflate 的语义未文档化，故不用）
//   3. 每个条目校验 CRC32 + 尺寸，任何不匹配立即中止，避免静默产出坏文件。
//   4. 自动跳过 __MACOSX/ 等 macOS 打包冗余目录（占条目数 37%，纯浪费）。
//

import Foundation
import zlib

enum NanoMuseZipError: Error {
    case notZip
    case unsupportedMethod(UInt16)
    case badHeader
    case crcMismatch(name: String)
    case sizeMismatch(name: String)
    case inflateFailed(name: String, code: Int32)
}

struct NanoMuseZipEntry {
    let name: String
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt32
    let uncompressedSize: UInt32
    let localHeaderOffset: UInt32
}

final class NanoMuseZip {
    private let file: FileHandle
    private let entries: [NanoMuseZipEntry]
    private let skipPrefixes: [String]

    /// - Parameter skipPrefixes: 以这些前缀开头的条目将被跳过（用于剔除 __MACOSX）
    init(path: String, skipPrefixes: [String] = ["__MACOSX/"]) throws {
        self.skipPrefixes = skipPrefixes
        self.file = try FileHandle(forReadingAtPath: path)
        guard let file else {
            throw NanoMuseZipError.notZip
        }
        self.entries = try Self.readCentralDirectory(file: file)
    }

    deinit {
        try? file.close()
    }

    var entryCount: Int { entries.count }

    /// 解出全部条目到目标目录。返回实际写入的文件数与总字节数。
    @discardableResult
    func extract(to destination: String, progress: ((Int, Int) -> Void)? = nil) throws -> (files: Int, bytes: Int64) {
        let destURL = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: destURL, withIntermediateDirectories: true)

        var files = 0
        var bytes: Int64 = 0

        for (index, entry) in entries.enumerated() {
            if skipPrefixes.contains(where: { entry.name.hasPrefix($0) }) { continue }
            if entry.name.hasSuffix("/") { continue }

            let outURL = destURL.appendingPathComponent(entry.name)
            let outDir = outURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            // 防止路径穿越（../）
            let resolved = outURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(destURL.standardizedFileURL.path) else { continue }

            let data = try readEntryData(entry)
            try data.write(to: outURL, options: .atomic)
            files += 1
            bytes += Int64(data.count)

            progress?(index + 1, entries.count)
        }
        return (files, bytes)
    }

    // MARK: - Central directory

    private struct EOCD {
        let entryCount: Int
        let centralDirectorySize: UInt32
        let centralDirectoryOffset: UInt32
    }

    /// 从文件尾部回溯找到 EOCD（End of Central Directory）记录。
    private static func findEOCD(file: FileHandle) throws -> EOCD {
        let fileSize = try file.seekToEnd()
        try file.seek(toOffset: 0)

        // EOCD 固定 22 字节，注释最长 65535，故最多回看 65557 字节。
        let tailSize = min(fileSize, 65557)
        try file.seek(toOffset: fileSize - tailSize)
        let tail = try file.read(upToCount: Int(tailSize)) ?? Data()

        // 签名 0x06054b50。必须找**最后一个**匹配：
        // 文件内容里可能先出现同样的 4 字节序列。
        let signature = Data([0x50, 0x4b, 0x05, 0x06])
        guard let range = tail.range(of: signature, options: .backwards) else {
            throw NanoMuseZipError.notZip
        }
        let eocd = tail[range.lowerBound...]
        guard eocd.count >= 22 else { throw NanoMuseZipError.notZip }

        let entryCount = Int(eocd.u16(at: 10))
        let cdSize = eocd.u32(at: 12)
        let cdOffset = eocd.u32(at: 16)
        return EOCD(entryCount: entryCount,
                    centralDirectorySize: cdSize,
                    centralDirectoryOffset: cdOffset)
    }

    private static func readCentralDirectory(file: FileHandle) throws -> [NanoMuseZipEntry] {
        let eocd = try findEOCD(file: file)

        try file.seek(toOffset: eocd.centralDirectoryOffset)
        let cd = try file.read(upToCount: Int(eocd.centralDirectorySize)) ?? Data()
        guard cd.count == Int(eocd.centralDirectorySize) else {
            throw NanoMuseZipError.badHeader
        }

        var entries: [NanoMuseZipEntry] = []
        entries.reserveCapacity(eocd.entryCount)

        var cursor = 0
        while cursor + 46 <= cd.count {
            // 中央目录文件头签名 0x02014b50
            guard cd.u32(at: cursor) == 0x0201_4b50 else { break }

            let method = cd.u16(at: cursor + 10)
            let crc = cd.u32(at: cursor + 16)
            let compressedSize = cd.u32(at: cursor + 20)
            let uncompressedSize = cd.u32(at: cursor + 24)
            let nameLength = Int(cd.u16(at: cursor + 28))
            let extraLength = Int(cd.u16(at: cursor + 30))
            let commentLength = Int(cd.u16(at: cursor + 32))
            let localOffset = cd.u32(at: cursor + 42)

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= cd.count else { break }
            let name = String(data: cd[nameStart..<nameEnd], encoding: .utf8)
                ?? String(decoding: cd[nameStart..<nameEnd], as: UTF8.self)

            entries.append(NanoMuseZipEntry(name: name,
                                             method: method,
                                             crc32: crc,
                                             compressedSize: compressedSize,
                                             uncompressedSize: uncompressedSize,
                                             localHeaderOffset: localOffset))

            cursor = nameEnd + extraLength + commentLength
        }
        return entries
    }

    // MARK: - Entry data

    private func readEntryData(_ entry: NanoMuseZipEntry) throws -> Data {
        try file.seek(toOffset: entry.localHeaderOffset)
        guard let header = try file.read(upToCount: 30), header.count == 30 else {
            throw NanoMuseZipError.badHeader
        }
        // 本地文件头签名 0x04034b50
        guard header.u32(at: 0) == 0x0403_4b50 else { throw NanoMuseZipError.badHeader }

        let nameLength = Int(header.u16(at: 26))
        let extraLength = Int(header.u16(at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt32(nameLength + extraLength)

        try file.seek(toOffset: dataOffset)
        let compressed = try file.read(upToCount: Int(entry.compressedSize)) ?? Data()

        let plain: Data
        switch entry.method {
        case 0:
            // Store：未压缩
            plain = compressed
        case 8:
            // Deflate：用 libz 解 raw deflate（windowBits = -MAX_WBITS）
            plain = try Self.inflateRaw(compressed, expectedSize: Int(entry.uncompressedSize),
                                        name: entry.name)
        default:
            throw NanoMuseZipError.unsupportedMethod(entry.method)
        }

        guard plain.count == Int(entry.uncompressedSize) else {
            throw NanoMuseZipError.sizeMismatch(name: entry.name)
        }
        // CRC32 校验：确保字节与官方完全一致
        let actual = Self.crc32(plain)
        guard actual == entry.crc32 else {
            throw NanoMuseZipError.crcMismatch(name: entry.name)
        }
        return plain
    }

    /// 用 libz inflate 解压 raw deflate 数据。
    private static func inflateRaw(_ data: Data, expectedSize: Int, name: String) throws -> Data {
        var stream = z_stream()
        // windowBits 传 -MAX_WBITS 表示 raw deflate（无 zlib/gzip 头）
        let initCode = inflateInit2(&stream, -MAX_WBITS)
        guard initCode == Z_OK else {
            throw NanoMuseZipError.inflateFailed(name: name, code: initCode)
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        if expectedSize > 0 {
            output.reserveCapacity(expectedSize)
        }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let chunkSize = buffer.count

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer(mutating: base)
            stream.avail_in = uInt(data.count)

            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                    stream.next_out = ptr.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }

                if status == Z_STREAM_END { break }
                if status != Z_OK {
                    throw NanoMuseZipError.inflateFailed(name: name, code: status)
                }
                if produced == 0 && stream.avail_in == 0 {
                    throw NanoMuseZipError.inflateFailed(name: name, code: Z_BUF_ERROR)
                }
            }
        }
        return output
    }

    /// CRC32（IEEE 802.3，多项式 0xEDB88320），与 ZIP 规范一致。
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    let mask = UInt32(bitPattern: -Int32(crc & 1))
                    crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Little-endian byte access

extension Data {
    /// 读取小端 UInt16。
    func u16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    /// 读取小端 UInt32。
    func u32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
