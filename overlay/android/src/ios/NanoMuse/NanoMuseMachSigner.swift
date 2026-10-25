import Foundation
import CryptoKit

/// 自带的 Mach-O ad-hoc 签名器（严格对齐 ldid 在本机的输出格式）。
///
/// 关键事实（从 ldid 签的、本机能跑的 nsh 上 dump 出来）：
///   · 代码签名块整体是**大端**（`fa de 0c c0` = CSMAGIC_EMBEDDED_SIGNATURE）
///   · CodeDirectory 版本 0x20500，头 96 字节
///   · hashSize 20 / hashType 1（SHA1）
///   · nSpecialSlots = 7，entitlements 在槽位 -5
///
/// 而 Mach-O 自身的头/load commands 仍是小端 —— 两者不能混。
/// 之前写成小端 + 0x20200 → AMFI 直接返回 EBADARCH（Bad executable）。
enum NanoMuseMachSigner {

    struct SignError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Mach-O（小端）
    private static let MH_MAGIC_64: UInt32 = 0xfeedfacf
    private static let MH_CIGAM_64: UInt32 = 0xcffaedfe
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1d
    private static let FAT_MAGIC: UInt32 = 0xcafebabe
    private static let FAT_CIGAM: UInt32 = 0xbebafeca

    // MARK: CodeSigning（大端）
    private static let CSMAGIC_EMBEDDED_SIGNATURE: UInt32 = 0xfade0cc0
    private static let CSMAGIC_CODEDIRECTORY: UInt32 = 0xfade0c02
    private static let CSMAGIC_EMBEDDED_ENTITLEMENTS: UInt32 = 0xfade7171
    private static let CSSLOT_CODEDIRECTORY: UInt32 = 0
    private static let CSSLOT_ENTITLEMENTS: UInt32 = 5
    private static let CD_VERSION: UInt32 = 0x20500
    private static let CS_ADHOC: UInt32 = 0x2
    private static let HASH_SIZE = 20          // SHA1，与 ldid 一致
    private static let HASH_TYPE: UInt8 = 1    // CS_HASHTYPE_SHA1
    private static let SPECIAL_SLOTS = 7
    private static let ENT_SLOT_INDEX = 2      // 文件顺序里第 3 个 = 槽位 -5
    private static let PAGE_LOG: UInt8 = 12

    /// 打 ad-hoc 签名（原地覆写）
    static func sign(path: String, entitlements: Data? = nil, identifier: String? = nil) throws {
        guard var data = FileManager.default.contents(atPath: path) else {
            throw SignError(message: "读不到 \(path)")
        }
        guard data.count >= 32 else { throw SignError(message: "文件太小") }

        let magic = data.le32(0)
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            guard let slice = arm64Slice(of: data) else {
                throw SignError(message: "FAT 里没有 arm64 片：\(path)")
            }
            try slice.write(to: URL(fileURLWithPath: path))
            data = slice
        }
        guard data.le32(0) == MH_MAGIC_64 || data.le32(0) == MH_CIGAM_64 else {
            throw SignError(message: "不是 Mach-O 64：\(path)")
        }

        let ncmds = Int(data.le32(16))
        let sizeofcmds = Int(data.le32(20))
        let headerSize = 32
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
                let nsects = Int(data.le32(off + 64))
                if segname != "__PAGEZERO" && nsects > 0, off + 72 + 44 <= data.count {
                    let sectOffset = Int(data.le32(off + 72 + 40))
                    if sectOffset > 0 && sectOffset < firstSectionOffset { firstSectionOffset = sectOffset }
                }
            } else if cmd == LC_CODE_SIGNATURE {
                sigCmd = (off, Int(data.le32(off + 8)), Int(data.le32(off + 12)))
            }
            off += cmdsize
        }

        // 不裁剪：旧签名原样留在文件里，新签名追加到末尾（重复签名安全）
        var base = data
        while base.count % 16 != 0 { base.append(0) }
        let codeLimit = base.count

        let ident = (identifier ?? URL(fileURLWithPath: path).lastPathComponent)
        let identData = Data(ident.utf8) + Data([0])

        // 代码页哈希（SHA1）
        var codeHashes = Data()
        var pageOff = 0
        let pageSize = 1 << Int(PAGE_LOG)
        while pageOff < codeLimit {
            let end = min(pageOff + pageSize, codeLimit)
            codeHashes.append(Data(Insecure.SHA1.hash(data: base.subdata(in: pageOff..<end))))
            pageOff = end
        }
        let nCodeSlots = codeHashes.count / HASH_SIZE

        // 特殊槽位（仅在有 entitlements 时用）
        var specialHashes = Data()
        var nSpecial = 0
        if let ents = entitlements {
            nSpecial = SPECIAL_SLOTS
            for i in 0..<SPECIAL_SLOTS {
                if i == ENT_SLOT_INDEX {
                    specialHashes.append(Data(Insecure.SHA1.hash(data: ents)))
                } else {
                    specialHashes.append(Data(repeating: 0, count: HASH_SIZE))
                }
            }
        }

        // ---- CodeDirectory v0x20500（大端，头 96 字节）----
        var cd = Data()
        cd.appendBE32(CSMAGIC_CODEDIRECTORY)
        cd.appendBE32(0)                       // length（回填）
        cd.appendBE32(CD_VERSION)
        cd.appendBE32(CS_ADHOC)
        cd.appendBE32(0)                       // hashOffset（回填）
        cd.appendBE32(0)                       // identOffset（回填）
        cd.appendBE32(UInt32(nSpecial))
        cd.appendBE32(UInt32(nCodeSlots))
        cd.appendBE32(UInt32(codeLimit))
        cd.append(UInt8(HASH_SIZE))
        cd.append(HASH_TYPE)
        cd.append(UInt8(0))                    // platform
        cd.append(PAGE_LOG)
        cd.appendBE32(0)                       // spare2
        cd.appendBE32(0)                       // scatterOffset
        cd.appendBE32(0)                       // teamOffset
        cd.appendBE32(0)                       // spare3
        cd.appendBE64(0)                       // codeLimit64
        cd.appendBE64(0)                       // execSegBase
        cd.appendBE64(0)                       // execSegLimit
        cd.appendBE64(0)                       // execSegFlags
        cd.appendBE32(0)                       // runtime
        cd.appendBE32(0)                       // preEncryptOffset
        guard cd.count == 96 else { throw SignError(message: "CD 头长度不对：\(cd.count)") }

        let identOffset = UInt32(cd.count)
        cd.append(identData)
        while cd.count % 4 != 0 { cd.append(0) }
        cd.append(specialHashes)
        let hashOffset = UInt32(cd.count)      // 指向 code slot 0
        cd.append(codeHashes)
        cd.setBE32(4, UInt32(cd.count))
        cd.setBE32(16, hashOffset)
        cd.setBE32(20, identOffset)

        // ---- SuperBlob（大端）----
        var blobs: [(UInt32, Data)] = [(CSSLOT_CODEDIRECTORY, cd)]
        if let ents = entitlements {
            var entBlob = Data()
            entBlob.appendBE32(CSMAGIC_EMBEDDED_ENTITLEMENTS)
            entBlob.appendBE32(UInt32(ents.count + 8))
            entBlob.append(ents)
            while entBlob.count % 4 != 0 { entBlob.append(0) }
            blobs.append((CSSLOT_ENTITLEMENTS, entBlob))
        }

        var superBlob = Data()
        superBlob.appendBE32(CSMAGIC_EMBEDDED_SIGNATURE)
        superBlob.appendBE32(0)                // length（回填）
        superBlob.appendBE32(UInt32(blobs.count))
        var cursor = 12 + 8 * blobs.count
        var offsets: [UInt32] = []
        for (_, blob) in blobs {
            offsets.append(UInt32(cursor))
            cursor += blob.count
        }
        for (i, item) in blobs.enumerated() {
            superBlob.appendBE32(item.0)
            superBlob.appendBE32(offsets[i])
        }
        for (_, blob) in blobs { superBlob.append(blob) }
        superBlob.setBE32(4, UInt32(superBlob.count))
        while superBlob.count % 16 != 0 { superBlob.append(0) }

        var out = base
        let dataoff = out.count
        out.append(superBlob)

        // 更新 __LINKEDIT 与 LC_CODE_SIGNATURE
        if let sig = sigCmd {
            out.setLE32(sig.cmdOff + 8, UInt32(dataoff))
            out.setLE32(sig.cmdOff + 12, UInt32(superBlob.count))
        } else {
            guard sizeofcmds + 16 <= firstSectionOffset - headerSize else {
                throw SignError(message: "header 空间不足，无法插入 LC_CODE_SIGNATURE")
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
        }

        // 重新定位 __LINKEDIT（插入命令后偏移可能变化）
        var off2 = 32
        let ncmds2 = Int(out.le32(16))
        var fixed = false
        for _ in 0..<ncmds2 {
            guard off2 + 72 <= out.count else { break }
            let cmd = out.le32(off2)
            let cmdsize = Int(out.le32(off2 + 4))
            if cmdsize <= 0 { break }
            if cmd == LC_SEGMENT_64 && out.str(off2 + 8, 16) == "__LINKEDIT" {
                let fileoff = Int(out.le64(off2 + 40))
                let newFileSize = out.count - fileoff
                let newVMSize = (newFileSize + pageSize - 1) / pageSize * pageSize
                out.setLE64(off2 + 48, UInt64(newFileSize))
                out.setLE64(off2 + 32, UInt64(newVMSize))
                fixed = true
                break
            }
            off2 += cmdsize
        }
        if !fixed { throw SignError(message: "找不到 __LINKEDIT") }

        guard out.count > codeLimit,
              out.le32(0) == MH_MAGIC_64 || out.le32(0) == MH_CIGAM_64 else {
            throw SignError(message: "签名后结构异常：\(path)")
        }
        try out.write(to: URL(fileURLWithPath: path))
    }

    /// 从 FAT 里取出 arm64 片
    private static func arm64Slice(of data: Data) -> Data? {
        guard data.count >= 8 else { return nil }
        let nArch = Int(data.be32(4))
        guard nArch > 0 && nArch < 32 else { return nil }
        for i in 0..<nArch {
            let base = 8 + i * 20
            guard base + 20 <= data.count else { break }
            let cputype = Int32(bitPattern: data.be32(base))
            let offset = Int(data.be32(base + 8))
            let size = Int(data.be32(base + 12))
            guard offset > 0, size > 0, offset + size <= data.count else { continue }
            if cputype == 0x0100_000c { return data.subdata(in: offset..<(offset + size)) }
        }
        return nil
    }

    static func hasSignature(path: String) -> Bool {
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

// MARK: - 字节序小工具

private extension Data {
    func le32(_ o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        let i = startIndex + o
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }
    func le64(_ o: Int) -> UInt64 {
        guard o + 8 <= count else { return 0 }
        var v: UInt64 = 0
        for k in (0..<8).reversed() { v = (v << 8) | UInt64(self[startIndex + o + k]) }
        return v
    }
    func be32(_ o: Int) -> UInt32 {
        guard o + 4 <= count else { return 0 }
        let i = startIndex + o
        return (UInt32(self[i]) << 24) | (UInt32(self[i + 1]) << 16)
            | (UInt32(self[i + 2]) << 8) | UInt32(self[i + 3])
    }
    func str(_ o: Int, _ len: Int) -> String {
        guard o + len <= count else { return "" }
        let bytes = self[(startIndex + o)..<(startIndex + o + len)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
    mutating func setLE32(_ o: Int, _ v: UInt32) {
        guard o + 4 <= count else { return }
        let i = startIndex + o
        for k in 0..<4 { self[i + k] = UInt8((v >> (8 * UInt32(k))) & 0xff) }
    }
    mutating func setLE64(_ o: Int, _ v: UInt64) {
        guard o + 8 <= count else { return }
        let i = startIndex + o
        for k in 0..<8 { self[i + k] = UInt8((v >> (8 * UInt64(k))) & 0xff) }
    }
    mutating func setBE32(_ o: Int, _ v: UInt32) {
        guard o + 4 <= count else { return }
        let i = startIndex + o
        self[i] = UInt8((v >> 24) & 0xff)
        self[i + 1] = UInt8((v >> 16) & 0xff)
        self[i + 2] = UInt8((v >> 8) & 0xff)
        self[i + 3] = UInt8(v & 0xff)
    }
    mutating func appendLE32(_ v: UInt32) {
        for k in 0..<4 { append(UInt8((v >> (8 * UInt32(k))) & 0xff)) }
    }
    mutating func appendBE32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }
    mutating func appendBE64(_ v: UInt64) {
        for k in (0..<8).reversed() { append(UInt8((v >> (8 * UInt64(k))) & 0xff)) }
    }
}
