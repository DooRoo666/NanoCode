import Foundation
import CryptoKit

/// 自带的 Mach-O ad-hoc 签名器（ldid 风格：SHA256 CodeDirectory + SuperBlob，不写 CMS）。
///
/// 为什么必须自己做：
///   · 随包的 `codex-sign` 用 "App Store code directory"（带 CMS）签名，AMFI 在**加载**时
///     按 Apple 锚点校验 → `code signature invalid`；
///   · 它的 `--adhoc-only` 分支在本机直接失败（NSOSStatusErrorDomain -67048）。
///   · 因此 TheosRuntime 里的 clang-16 / make / ldid / dpkg-deb 都起不来。
///
/// 本实现只做 iOS 上真正需要的那一套：
///   1. 计算每 4 KB 页的 SHA256（code slots）
///   2. 生成 CodeDirectory（flags = CS_ADHOC，hashType = SHA256）
///   3. 可选 entitlements（特殊槽位 5 存它的哈希，blob 本身放进 SuperBlob）
///   4. 把 SuperBlob 追加到文件末尾，扩展 __LINKEDIT，改写/新增 LC_CODE_SIGNATURE
///
/// 只支持 thin Mach-O 64（arm64）；遇到 FAT 会直接抛错（调用方回退）。
enum NanoMuseMachSigner {

    struct SignError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // Mach-O 常量
    private static let MH_MAGIC_64: UInt32 = 0xfeedfacf
    private static let MH_CIGAM_64: UInt32 = 0xcffaedfe
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1d
    private static let FAT_MAGIC: UInt32 = 0xcafebabe
    private static let FAT_CIGAM: UInt32 = 0xbebafeca

    // CodeDirectory 常量
    private static let CSMAGIC_EMBEDDED_SIGNATURE: UInt32 = 0xfade0cc0
    private static let CSMAGIC_CODEDIRECTORY: UInt32 = 0xfade0c02
    private static let CSMAGIC_EMBEDDED_ENTITLEMENTS: UInt32 = 0xfade7171
    private static let CSSLOT_CODEDIRECTORY: UInt32 = 0
    private static let CSSLOT_ENTITLEMENTS: UInt32 = 5
    private static let CD_VERSION: UInt32 = 0x20200
    private static let CS_ADHOC: UInt32 = 0x2
    private static let HASH_SIZE = 32
    private static let PAGE_LOG = 12            // 4096

    /// 给一个 thin Mach-O 打 ad-hoc 签名（原地覆写）
    /// - Parameters:
    ///   - path: 目标文件
    ///   - entitlements: 可选的 entitlements plist 原始字节
    ///   - identifier: CodeDirectory 里的标识名（一般用文件名）
    static func sign(path: String, entitlements: Data? = nil, identifier: String? = nil) throws {
        guard var data = FileManager.default.contents(atPath: path) else {
            throw SignError(message: "读不到 \(path)")
        }
        guard data.count >= 32 else { throw SignError(message: "文件太小") }

        let magic = data.le32(0)
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            throw SignError(message: "FAT 二进制暂不支持：\(path)")
        }
        guard magic == MH_MAGIC_64 || magic == MH_CIGAM_64 else {
            throw SignError(message: "不是 Mach-O 64：\(path)")
        }

        let ncmds = Int(data.le32(16))
        let sizeofcmds = Int(data.le32(20))
        let headerSize = 32
        var linkset: (index: Int, cmdOff: Int, fileoff: Int, filesize: Int, vmsize: Int, vmaddr: Int)?
        var sigCmd: (cmdOff: Int, dataoff: Int, datasize: Int)?
        var firstSectionOffset = data.count
        var off = headerSize
        for _ in 0..<ncmds {
            guard off + 8 <= data.count else { break }
            let cmd = data.le32(off)
            let cmdsize = Int(data.le32(off + 4))
            if cmdsize <= 0 { break }
            if cmd == LC_SEGMENT_64 {
                let segname = data.str(off + 8, 16)
                let vmaddr = Int(data.le64(off + 24))
                let vmsize = Int(data.le64(off + 32))
                let fileoff = Int(data.le64(off + 40))
                let filesize = Int(data.le64(off + 48))
                let nsects = Int(data.le32(off + 64))
                if segname == "__LINKEDIT" {
                    linkset = (off, off, fileoff, filesize, vmsize, vmaddr)
                }
                if segname != "__PAGEZERO" && nsects > 0 {
                    // 第一个 section 的 offset 是 header 之后可用的空洞上界
                    let sectOff = off + 72
                    if sectOff + 48 <= data.count {
                        let addr = Int(data.le32(sectOff + 40))   // section offset 字段
                        if addr > 0 && addr < firstSectionOffset { firstSectionOffset = addr }
                    }
                }
            } else if cmd == LC_CODE_SIGNATURE {
                sigCmd = (off, Int(data.le32(off + 8)), Int(data.le32(off + 12)))
            }
            off += cmdsize
        }
        guard let linkedit = linkset else { throw SignError(message: "没有 __LINKEDIT") }

        // 截掉旧签名（如果有），从干净的尾部开始
        var base = data
        if let sig = sigCmd, sig.dataoff > 0, sig.dataoff <= base.count {
            base = base.subdata(in: 0..<sig.dataoff)
        }
        // 按 16 字节对齐放置签名
        while base.count % 16 != 0 { base.append(0) }
        let codeLimit = base.count

        let ident = (identifier ?? URL(fileURLWithPath: path).lastPathComponent)
        let identData = Data(ident.utf8) + Data([0])

        // 代码页哈希
        var codeHashes = Data()
        var pageOff = 0
        while pageOff < codeLimit {
            let end = min(pageOff + (1 << PAGE_LOG), codeLimit)
            let chunk = base.subdata(in: pageOff..<end)
            codeHashes.append(Data(SHA256.hash(data: chunk)))
            pageOff = end
        }
        let nCodeSlots = codeHashes.count / HASH_SIZE

        // 特殊槽位：只在有 entitlements 时才用（slot 5）
        var specialHashes = Data()
        var nSpecialSlots = 0
        if let ents = entitlements {
            nSpecialSlots = 5
            // 槽位从 5 递减到 1；只有 5 有值，其余填 0
            specialHashes.append(Data(SHA256.hash(data: ents)))
            for _ in 1..<5 {
                specialHashes.append(Data(repeating: 0, count: HASH_SIZE))
            }
        }

        // 组装 CodeDirectory（version 0x20200，固定头 52 字节）
        var cd = Data()
        cd.appendLE32(CSMAGIC_CODEDIRECTORY)
        cd.appendLE32(0)                       // length，稍后回填
        cd.appendLE32(CD_VERSION)
        cd.appendLE32(CS_ADHOC)
        cd.appendLE32(0)                       // hashOffset，稍后回填
        cd.appendLE32(0)                       // identOffset，稍后回填
        cd.appendLE32(UInt32(nSpecialSlots))
        cd.appendLE32(UInt32(nCodeSlots))
        cd.appendLE32(UInt32(codeLimit))
        cd.append(UInt8(HASH_SIZE))
        cd.append(UInt8(2))                    // hashType = SHA256
        cd.append(UInt8(0))                    // platform
        cd.append(UInt8(PAGE_LOG))
        cd.appendLE32(0)                       // spare2
        cd.appendLE32(0)                       // scatterOffset
        cd.appendLE32(0)                       // teamOffset

        let identOffset = UInt32(cd.count)
        cd.append(identData)
        // 特殊槽位必须 4 字节对齐
        while cd.count % 4 != 0 { cd.append(0) }
        let hashOffset = UInt32(cd.count)
        cd.append(specialHashes)
        cd.append(codeHashes)
        cd.setLE32(4, UInt32(cd.count))
        cd.setLE32(16, hashOffset)
        cd.setLE32(20, identOffset)

        // SuperBlob
        var blobs: [(UInt32, Data)] = [(CSSLOT_CODEDIRECTORY, cd)]
        if let ents = entitlements {
            var entBlob = Data()
            entBlob.appendLE32(CSMAGIC_EMBEDDED_ENTITLEMENTS)
            entBlob.appendLE32(UInt32(ents.count + 8))
            entBlob.append(ents)
            while entBlob.count % 4 != 0 { entBlob.append(0) }
            blobs.append((CSSLOT_ENTITLEMENTS, entBlob))
        }

        var superBlob = Data()
        superBlob.appendLE32(CSMAGIC_EMBEDDED_SIGNATURE)
        superBlob.appendLE32(0)                       // length，稍后回填
        superBlob.appendLE32(UInt32(blobs.count))
        var cursor = 12 + 8 * blobs.count
        var offsets: [UInt32] = []
        for (_, blob) in blobs {
            offsets.append(UInt32(cursor))
            cursor += blob.count
        }
        for (i, item) in blobs.enumerated() {
            superBlob.appendLE32(item.0)
            superBlob.appendLE32(offsets[i])
        }
        for (_, blob) in blobs { superBlob.append(blob) }
        superBlob.setLE32(4, UInt32(superBlob.count))
        while superBlob.count % 16 != 0 { superBlob.append(0) }

        // 写入：先补签名区，再改 __LINKEDIT / LC_CODE_SIGNATURE
        var out = base
        let dataoff = out.count
        out.append(superBlob)

        let linkeditEnd = dataoff + superBlob.count
        let newFileSize = linkeditEnd - linkedit.fileoff
        let pageSize = 1 << PAGE_LOG
        let newVMSize = (newFileSize + pageSize - 1) / pageSize * pageSize

        if let sig = sigCmd {
            out.setLE32(sig.cmdOff + 8, UInt32(dataoff))
            out.setLE32(sig.cmdOff + 12, UInt32(superBlob.count))
        } else {
            // 需要在 header 里插入一条 LC_CODE_SIGNATURE
            guard sizeofcmds + 16 <= firstSectionOffset - headerSize else {
                throw SignError(message: "header 没有空间插入 LC_CODE_SIGNATURE")
            }
            let insertAt = headerSize + sizeofcmds
            var cmdData = Data()
            cmdData.appendLE32(LC_CODE_SIGNATURE)
            cmdData.appendLE32(16)
            cmdData.appendLE32(UInt32(dataoff))
            cmdData.appendLE32(UInt32(superBlob.count))
            out.insert(contentsOf: cmdData, at: insertAt)
            out.setLE32(16, UInt32(ncmds + 1))
            out.setLE32(20, UInt32(sizeofcmds + 16))
            // __LINKEDIT 的命令偏移没变（在 header 之后、插入点之后的话会变）
            if linkedit.cmdOff >= insertAt {
                // 插入点在 sizeofcmds 末尾，__LINKEDIT 在其后 → 需要整体后移
                // 简化：重新解析（此时 offsets 已变化）
                throw SignError(message: "需要移动 __LINKEDIT，暂不支持该布局")
            }
        }

        // 更新 __LINKEDIT 的 filesize / vmsize（注意插入后偏移可能变化，重新定位）
        var off2 = 32
        let ncmds2 = Int(out.le32(16))
        var fixed = false
        for _ in 0..<ncmds2 {
            let cmd = out.le32(off2)
            let cmdsize = Int(out.le32(off2 + 4))
            if cmd == LC_SEGMENT_64 && out.str(off2 + 8, 16) == "__LINKEDIT" {
                out.setLE64(off2 + 32, UInt64(newVMSize))          // vmsize
                out.setLE64(off2 + 48, UInt64(newFileSize))        // filesize
                fixed = true
                break
            }
            off2 += cmdsize
        }
        if !fixed { throw SignError(message: "找不到 __LINKEDIT") }

        try out.write(to: URL(fileURLWithPath: path))
    }

    /// 只读取 ad-hoc 签名是否已经存在（用于增量判断）
    static func hasAdhocSignature(path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        let magic = data.le32(0)
        guard magic == MH_MAGIC_64 || magic == MH_CIGAM_64 else { return false }
        let ncmds = Int(data.le32(16))
        var off = 32
        for _ in 0..<ncmds {
            guard off + 8 <= data.count else { break }
            let cmd = data.le32(off)
            let cmdsize = Int(data.le32(off + 4))
            if cmdsize <= 0 { break }
            if cmd == LC_CODE_SIGNATURE { return true }
            off += cmdsize
        }
        return false
    }
}

// MARK: - 小工具

private extension Data {
    func le32(_ offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[startIndex + offset])
            | (UInt32(self[startIndex + offset + 1]) << 8)
            | (UInt32(self[startIndex + offset + 2]) << 16)
            | (UInt32(self[startIndex + offset + 3]) << 24)
    }
    func le64(_ offset: Int) -> UInt64 {
        guard offset + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for i in (0..<8).reversed() {
            v = (v << 8) | UInt64(self[startIndex + offset + i])
        }
        return v
    }
    func str(_ offset: Int, _ len: Int) -> String {
        guard offset + len <= count else { return "" }
        let slice = self[(startIndex + offset)..<(startIndex + offset + len)]
        let bytes = slice.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
    mutating func setLE32(_ offset: Int, _ value: UInt32) {
        guard offset + 4 <= count else { return }
        let i = startIndex + offset
        self[i] = UInt8(value & 0xff)
        self[i + 1] = UInt8((value >> 8) & 0xff)
        self[i + 2] = UInt8((value >> 16) & 0xff)
        self[i + 3] = UInt8((value >> 24) & 0xff)
    }
    mutating func setLE64(_ offset: Int, _ value: UInt64) {
        guard offset + 8 <= count else { return }
        let i = startIndex + offset
        for k in 0..<8 {
            self[i + k] = UInt8((value >> (8 * UInt64(k))) & 0xff)
        }
    }
    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
