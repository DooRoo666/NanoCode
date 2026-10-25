import Foundation

/// 把 Mach-O 里对第三方 dylib 的依赖**重定向到系统库**。
///
/// 为什么需要：
///   TheosRuntime 里的 clang-16 / make / ld64 / ldid 都链接了 Procursus 的
///   `@rpath/libiosexec.1.dylib`（一个把 /usr 重定向到 /var/jb 的兼容层）。
///   而这台设备上，从 App 里 spawn 出去的进程**不允许 mmap 执行第三方 dylib**
///   （`file system sandbox blocked mmap()`），于是工具全部起不来。
///
///   libiosexec 导出的其实就是 `posix_spawn` / `execve` / `fopen` 这些系统函数，
///   所以把这条依赖改成 `/usr/lib/libSystem.B.dylib` 后：
///     · 不再需要加载任何第三方 dylib
///     · 符号照样能从 libSystem 解析
///   字符串长度刚好一样（都是 26 字符），可以原地覆盖，不动文件大小。
enum NanoMuseMachPatcher {

    struct PatchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let LC_LOAD_DYLIB: UInt32 = 0x0c
    private static let LC_LOAD_WEAK_DYLIB: UInt32 = 0x8000_0018
    private static let LC_REEXPORT_DYLIB: UInt32 = 0x8000_001f
    private static let MH_MAGIC_64: UInt32 = 0xfeedfacf
    private static let FAT_MAGIC_BE: UInt32 = 0xcafebabe

    /// 把 path 里所有指向 needle 的 dylib 依赖改成 replacement。
    /// - Returns: 改动了几处（0 表示没匹配到）
    @discardableResult
    static func repoint(path: String, matching needle: String, to replacement: String) throws -> Int {
        guard var data = FileManager.default.contents(atPath: path) else {
            throw PatchError(message: "读不到 \(path)")
        }
        var total = 0

        // FAT：逐片处理
        if data.be32(0) == FAT_MAGIC_BE || data.le32(0) == FAT_MAGIC_BE {
            let nArch = Int(data.be32(4))
            guard nArch > 0 && nArch < 32 else { return 0 }
            for i in 0..<nArch {
                let base = 8 + i * 20
                guard base + 20 <= data.count else { break }
                let offset = Int(data.be32(base + 8))
                let size = Int(data.be32(base + 12))
                guard offset > 0, size > 0, offset + size <= data.count else { continue }
                var slice = data.subdata(in: offset..<(offset + size))
                let n = patchSlice(&slice, needle: needle, replacement: replacement)
                if n > 0 {
                    data.replaceSubrange(offset..<(offset + size), with: slice)
                    total += n
                }
            }
        } else {
            total = patchSlice(&data, needle: needle, replacement: replacement)
        }

        if total > 0 {
            try data.write(to: URL(fileURLWithPath: path))
        }
        return total
    }

    /// 处理单个 thin Mach-O
    private static func patchSlice(_ data: inout Data, needle: String, replacement: String) -> Int {
        guard data.le32(0) == MH_MAGIC_64 || data.le32(0) == 0xcffaedfe else { return 0 }
        let ncmds = Int(data.le32(16))
        var off = 32
        var patched = 0
        for _ in 0..<ncmds {
            guard off + 8 <= data.count else { break }
            let cmd = data.le32(off)
            let cmdsize = Int(data.le32(off + 4))
            if cmdsize <= 0 || off + cmdsize > data.count { break }
            if cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB {
                let strOff = Int(data.le32(off + 8))
                let abs = off + strOff
                if abs > 0 && abs < data.count {
                    let old = readCString(data, at: abs)
                    if old.contains(needle) {
                        let newBytes = Array(replacement.utf8)
                        let room = old.utf8.count            // 可写入的字节数（不含结尾 NUL 的余量）
                        if newBytes.count <= room {
                            for k in 0..<room { data[abs + k] = 0 }
                            for (k, b) in newBytes.enumerated() { data[abs + k] = b }
                            // 结尾保持 NUL
                            patched += 1
                        }
                    }
                }
            }
            off += cmdsize
        }
        return patched
    }

    private static func readCString(_ data: Data, at offset: Int) -> String {
        var bytes: [UInt8] = []
        var i = offset
        while i < data.count && data[i] != 0 && bytes.count < 512 {
            bytes.append(data[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - 本地字节序工具（与其它文件互不影响）

private extension Data {
    func le32(_ o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        let i = startIndex + o
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
    func be32(_ o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        let i = startIndex + o
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16)
            | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }
}
