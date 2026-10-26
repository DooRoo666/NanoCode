import Darwin
import Foundation

/// 只干一件事：验证「能不能用 root persona 拉起子进程」，
/// 因为只有这条路能让 App 写进自己的 .app、往 /var/jb 装 deb。
///
/// 上一版的两个坑（都被日志坐实了）：
/// 1. `kpersona_find` 用了 iOS 13 的两参签名，iOS 17 是五参
///    (name, type, uid, &id, &idlen)，所以 rc 恒为 -1；
/// 2. 拿 bash.real 去执行外部工具（mkdir 之类），子进程直接 SIGBUS，
///    于是"写包失败"其实是测试本身坏了，不是权限问题。
/// 这版改成：所有动作都用 bash 内建重定向完成，不再 exec 第二层。
public enum NanoMusePersona {

    // MARK: - 符号

    private typealias FindFn = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, uid_t,
                                               UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<Int>?) -> Int32
    private typealias GetFn = @convention(c) (UnsafeMutablePointer<UInt64>?) -> Int32
    private typealias SetPersonaFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, UInt64, UInt32) -> Int32

    private static let find: FindFn? = lookup("kpersona_find")
    private static let get: GetFn? = lookup("kpersona_get")
    private static let setPersona: SetPersonaFn? = lookup("posix_spawnattr_set_persona_np")

    private static func lookup<T>(_ name: String) -> T? {
        guard let handle = dlopen(nil, RTLD_NOW), let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: T.self)
    }

    /// 候选调用形态：带不带 type、uid 用 0 还是 -1。三种都试，全打 errno。
    private static var variants: [(String?, uid_t)] {
        [(nil, 0), ("PERSONA_ID", 0), (nil, uid_t.max)]
    }

    // MARK: - 查询

    public static func ownPersonaID() -> (id: UInt64?, rc: Int32) {
        guard let fn = get else { return (nil, -999) }
        var value: UInt64 = 0
        let rc = fn(&value)
        return (rc == 0 && value != 0 ? value : nil, rc)
    }

    public static func rootPersonaID64() -> (id: UInt64?, rc: Int32) {
        guard let fn = find else { return (nil, -999) }
        var last: Int32 = -1
        for variant in variants {
            var value: UInt64 = 0
            var length = MemoryLayout<UInt64>.size
            var rc: Int32 = -1
            if let type = variant.0 {
                type.withCString { pointer in
                    rc = fn("root", pointer, variant.1, &value, &length)
                }
            } else {
                rc = fn("root", nil, variant.1, &value, &length)
            }
            if rc == 0 && value != 0 { return (value, rc) }
            last = rc
        }
        return (nil, last)
    }

    public static func rootPersonaID() -> (id: Int32?, rc: Int32) {
        let (value, rc) = rootPersonaID64()
        guard let raw = value, raw <= UInt64(Int32.max) else { return (nil, rc) }
        return (Int32(raw), rc)
    }

    public static func findVariantReport() -> [String] {
        guard let fn = find else { return ["kpersona_find: 符号不存在"] }
        var lines: [String] = []
        for (index, variant) in variants.enumerated() {
            var value: UInt64 = 0
            var length = MemoryLayout<UInt64>.size
            var rc: Int32 = -1
            if let type = variant.0 {
                type.withCString { pointer in
                    rc = fn("root", pointer, variant.1, &value, &length)
                }
            } else {
                rc = fn("root", nil, variant.1, &value, &length)
            }
            let code = errno
            lines.append("find#\(index) type=\(variant.0 ?? "nil") uid=\(variant.1) → rc=\(rc) errno=\(code) id=\(rc == 0 ? String(value) : "-")")
        }
        return lines
    }

    // MARK: - 子进程

    public struct RunResult {
        public let rc: Int32
        public let output: String
    }

    public static func helper(_ name: String) -> String? {
        let path = Bundle.main.bundlePath + "/Helpers/" + name
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// 用 posix_spawn 起子进程；personaID 非空时走 POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE。
    /// stdout/stderr 一律落临时文件后再读，避免管道读空的坑。
    public static func spawn(_ path: String, args: [String], personaID: UInt64?, timeout: TimeInterval = 12) -> RunResult? {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("nm-spawn-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: temp.path) else { return nil }
        defer { try? FileManager.default.removeItem(at: temp) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, handle.fileDescriptor, STDERR_FILENO)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        if let pid = personaID, let setter = setPersona {
            let rc = setter(&attr, pid, 1) // POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
            if rc != 0 {
                return RunResult(rc: rc, output: "set_persona_np rc=\(rc) errno=\(errno)")
            }
        }

        var argv = args.map { strdup($0) }
        argv.append(nil)
        var childPID: pid_t = 0
        let spawnRC: Int32 = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&childPID, path, &actions, &attr, buffer.baseAddress, environ)
        }
        argv.forEach { free($0) }
        guard spawnRC == 0 else {
            return RunResult(rc: spawnRC, output: "posix_spawn errno=\(spawnRC)")
        }

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let waited = waitpid(childPID, &status, WNOHANG)
            if waited == childPID { break }
            if waited < 0 { break }
            if Date() > deadline {
                kill(childPID, SIGKILL)
                _ = waitpid(childPID, &status, 0)
                break
            }
            usleep(20_000)
        }

        let code: Int32
        if status & 0x7f == 0 {
            code = (status >> 8) & 0xff
        } else {
            code = 128 + (status & 0x7f)
        }

        try? handle.close()
        let data = (try? Data(contentsOf: temp)) ?? Data()
        let text = String(decoding: data.prefix(500), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " | ")
            .trimmingCharacters(in: .whitespaces)
        return RunResult(rc: code, output: text)
    }

    /// UI 里「persona 探测」用的就地提权尝试。没戏就如实说没戏，不要含糊。
    public static func tryInProcessSetuid() -> String {
        let before = getuid()
        errno = 0
        let rc = setuid(0)
        let after = geteuid()
        if rc == 0 {
            return "就地 setuid(0): 成功（uid \(before) → \(after)）"
        }
        return "就地 setuid(0): 失败 rc=\(rc) errno=\(errno)（仍是 uid \(after)）"
    }

    public static func runUidProbe(personaID: Int32?) -> String {
        guard let bash = helper("bash.real") else { return "uid 探测: 找不到 bash.real" }
        let persona = personaID.map { UInt64(bitPattern: Int64($0)) }
        guard let result = spawn(bash, args: ["bash.real", "-c", "echo UID=$UID; echo EUID=$EUID"], personaID: persona) else {
            return "uid 探测: 起进程失败"
        }
        return "uid 探测(persona=\(personaID.map(String.init) ?? "nil")): rc=\(result.rc) \(result.output)"
    }

    // MARK: - 写权限测试（全部用 bash 内建重定向，不 exec 第二层）

    public static func bundleWriteTest() -> [String] {
        guard let bash = helper("bash.real") else { return ["写包测试: 找不到 bash.real"] }
        let target = Bundle.main.bundlePath + "/.nmwrite-probe"
        var lines: [String] = []

        let script = "echo ok > '\(target)' && echo WROTE"

        if let base = spawn(bash, args: ["bash.real", "-c", script], personaID: nil) {
            let exists = FileManager.default.fileExists(atPath: target)
            lines.append("写包(基线 uid=\(getuid())): rc=\(base.rc) 存在=\(exists) \(base.output)")
        }
        try? FileManager.default.removeItem(atPath: target)

        if let root = rootPersonaID64().id,
           let elevated = spawn(bash, args: ["bash.real", "-c", script], personaID: root) {
            let exists = FileManager.default.fileExists(atPath: target)
            lines.append("写包(root persona=\(root)): rc=\(elevated.rc) 存在=\(exists) \(elevated.output)")
            try? FileManager.default.removeItem(atPath: target)
        } else {
            lines.append("写包(root persona): 未取得 persona id，跳过")
        }
        return lines
    }

    public static func jbWriteTest() -> [String] {
        guard let bash = helper("bash.real") else { return ["写越狱目录: 找不到 bash.real"] }
        let target = "/var/jb/.nmwrite-probe"
        var lines: [String] = []

        if let base = spawn(bash, args: ["bash.real", "-c", "echo ok > '\(target)' && echo WROTE"], personaID: nil) {
            let exists = FileManager.default.fileExists(atPath: target)
            lines.append("写/var/jb(基线): rc=\(base.rc) 存在=\(exists) \(base.output)")
        }
        try? FileManager.default.removeItem(atPath: target)

        if let root = rootPersonaID64().id,
           let elevated = spawn(bash, args: ["bash.real", "-c", "echo ok > '\(target)' && echo WROTE"], personaID: root) {
            let exists = FileManager.default.fileExists(atPath: target)
            lines.append("写/var/jb(root persona): rc=\(elevated.rc) 存在=\(exists) \(elevated.output)")
            try? FileManager.default.removeItem(atPath: target)
        } else {
            lines.append("写/var/jb(root persona): 未取得 persona id，跳过")
        }
        return lines
    }

    /// 真正关心的问题：能不能执行越狱侧的 dpkg（装 deb 的前提）。
    public static func jbExecTest() -> [String] {
        let dpkg = "/var/jb/usr/bin/dpkg"
        guard FileManager.default.isExecutableFile(atPath: dpkg) else {
            return ["exec \(dpkg): 文件不存在或不可执行"]
        }
        var lines: [String] = []
        for (label, persona) in [("基线", nil as UInt64?), ("root persona", rootPersonaID64().id)] {
            guard let pid = persona else { lines.append("exec dpkg(\(label)): 无 persona id"); continue }
            if let result = spawn(dpkg, args: ["dpkg", "--version"], personaID: pid) {
                lines.append("exec dpkg(\(label)): rc=\(result.rc) \(result.output)")
            }
        }
        return lines
    }

    // MARK: - 汇总落盘

    public static func diagnostics() -> [String] {
        var lines: [String] = []
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append("===== persona 探测 \(formatter.string(from: Date())) =====")
        lines.append("bundle=\(Bundle.main.bundlePath)")
        lines.append("自身 uid=\(getuid()) euid=\(geteuid())")
        lines.append("符号: find=\(find != nil) get=\(get != nil) set_persona=\(setPersona != nil)")

        let own = ownPersonaID()
        lines.append("kpersona_get: rc=\(own.rc) id=\(own.id.map(String.init) ?? "-")")
        lines.append(contentsOf: findVariantReport())

        let root = rootPersonaID64()
        lines.append("root persona: id=\(root.id.map(String.init) ?? "-") rc=\(root.rc)")
        lines.append(runUidProbe(personaID: root.id.flatMap { $0 <= UInt64(Int32.max) ? Int32($0) : nil }))
        lines.append(contentsOf: bundleWriteTest())
        lines.append(contentsOf: jbWriteTest())
        lines.append(contentsOf: jbExecTest())
        return lines
    }

    public static func probeAndWrite() {
        let lines = diagnostics()
        let target = NanoMuseAutoDiag.documentsURL().appendingPathComponent("persona-diag.txt")
        let text = lines.joined(separator: "\n") + "\n\n"
        if let handle = try? FileHandle(forWritingTo: target) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: target, atomically: true, encoding: .utf8)
        }
    }
}
