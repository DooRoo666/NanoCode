import Foundation
import Darwin

/// 探测「以 root persona 运行子进程」的可行性（对应 MT-Agent 的
/// `persona API ✓ / root persona ✓ / effective uid=0 ✓`）。
///
/// 为什么需要它：
///   MT 的运行时是**下载到自己的 .app 目录里**、再用包内 ldid 签名的。
///   而 App 以 mobile 身份跑时写不进自己的 bundle（Permission denied），
///   所以它靠 persona API 把自己切成 root（effective uid=0）。
///
/// 本文件只做探测，不改变运行行为——先拿到数据再决定实现。
enum NanoMusePersonaProbe {

    /// 返回可读的诊断行
    static func report() -> [String] {
        var lines: [String] = ["== persona / root 探测 =="]

        lines.append("  uid=\(getuid()) euid=\(geteuid()) gid=\(getgid())")

        // 1) 关键私有符号是否存在
        let handle = dlopen(nil, RTLD_NOW)
        let names = [
            "kpersona_alloc", "kpersona_palloc", "kpersona_dealloc",
            "kpersona_find", "kpersona_find_by_type", "kpersona_get",
            "kpersona_info", "posix_spawnattr_set_persona_np",
            "posix_spawnattr_set_persona_id",
        ]
        var found: [String] = []
        for name in names {
            if dlsym(handle, name) != nil { found.append(name) }
        }
        lines.append("  符号: " + (found.isEmpty ? "（一个都没有）" : found.joined(separator: ", ")))

        // 2) 试着找 root persona
        typealias FindFn = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> Int32
        typealias PAllocFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>?) -> Int32

        var rootPersona: Int32 = -1
        if let sym = dlsym(handle, "kpersona_find") {
            let fn = unsafeBitCast(sym, to: FindFn.self)
            let rc = "root".withCString { fn($0, &rootPersona) }
            lines.append("  kpersona_find(\"root\") rc=\(rc) id=\(rootPersona)")
        } else {
            lines.append("  kpersona_find: 无此符号")
        }

        var pallocPersona: Int32 = -1
        if let sym = dlsym(handle, "kpersona_palloc") {
            let fn = unsafeBitCast(sym, to: PAllocFn.self)
            let rc = fn(0, &pallocPersona)
            lines.append("  kpersona_palloc(0) rc=\(rc) id=\(pallocPersona)")
        }

        // 3) 直接 setuid(0) 行不行（platform-application 有时允许）
        errno = 0
        let rcSet = setuid(0)
        lines.append("  setuid(0) rc=\(rcSet) errno=\(errno) → uid 现在=\(getuid())")
        if rcSet == 0 && getuid() == 0 {
            lines.append("  ✅ 已经是 root：可以写自己的 .app 目录")
        } else {
            lines.append("  ⚠️ 不是 root：需要 persona 方案")
        }

        // 4) 能不能写自己的 bundle（这是"下载到包内"的前提）
        let probe = Bundle.main.bundlePath + "/.nm_write_probe"
        let okWrite = FileManager.default.createFile(atPath: probe, contents: Data("x".utf8))
        lines.append("  写 App 包: \(okWrite ? "✅ 可以" : "❌ 不行") （\(probe)）")
        if okWrite { try? FileManager.default.removeItem(atPath: probe) }

        // 5) 关键路径确认：MT 的 clang 在 llvm-16/bin
        let llvmClang = "/var/mobile/Library/TheosRuntime/usr/lib/llvm-16/bin/clang-16"
        lines.append("  我们 runtime 里的 llvm clang: \(FileManager.default.isExecutableFile(atPath: llvmClang) ? "存在" : "不存在")")

        return lines
    }
}
