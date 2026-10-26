import Darwin
import Foundation

/// 照 MT-Agent 的做法拿「root persona」：进程在 root 的 persona 里派生子进程，
/// 子进程 effective uid = 0，从而能写进自己的 .app 目录、也能 mmap 已签名文件。
///
/// 用到的都是 libsystem_kernel 的私有符号，只能 dlsym：
///   kpersona_find / kpersona_palloc / kpersona_dealloc
///   posix_spawnattr_set_persona_np
/// 权限来自 entitlements 里的 com.apple.private.persona-mgmt。
public enum NanoMusePersona {

    private typealias FindFn   = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias PallocFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>?) -> Int32
    private typealias DeallocFn = @convention(c) (Int32) -> Int32
    private typealias SetPersonaFn = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>?, Int32, UInt32) -> Int32

    /// POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE
    public static let overrideFlag: UInt32 = 1

    private static func sym<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = dlopen(nil, RTLD_NOW), let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    public static var hasPersonaSymbols: Bool {
        sym("kpersona_find", FindFn.self) != nil
            && sym("posix_spawnattr_set_persona_np", SetPersonaFn.self) != nil
    }

    /// 找 "root" persona 的 id
    public static func rootPersonaID() -> (id: Int32?, rc: Int32) {
        guard let find = sym("kpersona_find", FindFn.self) else { return (nil, -999) }
        var id: Int32 = -1
        let rc = "root".withCString { find($0, &id) }
        return (rc == 0 && id >= 0 ? id : nil, rc)
    }

    /// 给 spawnattr 设 persona
    public static func setPersona(_ attr: inout posix_spawnattr_t?, id: Int32, flags: UInt32) -> Int32 {
        guard let fn = sym("posix_spawnattr_set_persona_np", SetPersonaFn.self) else { return -999 }
        return fn(&attr, id, flags)
    }
}

extension NanoMusePersona {

    private static func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func log(_ lines: [String]) {
        let text = lines.joined(separator: "\n") + "\n"
        let url = documentsURL().appendingPathComponent("persona-diag.txt")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            if let d = text.data(using: .utf8) { h.write(d) }
            try? h.close()
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// 用一个子进程验证 root persona 是否真的生效：
    /// bash 的 $UID 是 readonly 的 real uid，能反映子进程身份。
    public static func probeAndWrite() {
        var out: [String] = []
        out.append("===== persona 探测 \(Date()) =====")
        out.append("bundle=\(Bundle.main.bundlePath)")
        out.append("自身 uid=\(getuid()) euid=\(geteuid())")
        out.append("persona 符号: \(hasPersonaSymbols ? "有" : "无")")

        let (rid, rrc) = rootPersonaID()
        out.append("kpersona_find(root) rc=\(rrc) id=\(rid.map(String.init) ?? "-")")

        if !hasPersonaSymbols {
            let rc = setuid(0)
            out.append("setuid(0) rc=\(rc) 之后 uid=\(getuid())")
            log(out)
            return
        }

        if let r = runUidProbe(personaID: nil) {
            out.append("基线 spawn: rc=\(r.rc) uid=\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let pid = rid, let r = runUidProbe(personaID: pid) {
            out.append("root persona spawn: rc=\(r.rc) uid=\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        out.append(contentsOf: bundleWriteTest())
        log(out)
    }

    public static func tryInProcessSetuid() -> String {
        let rc = setuid(0)
        return "setuid(0) rc=\(rc) uid=\(getuid()) euid=\(geteuid())"
    }

    public static func runUidProbe(personaID: Int32?) -> (rc: Int32, output: String)? {
        guard let bash = bundledHelper("bash.real") else { return nil }
        return spawn(bash, args: ["bash.real", "-c", "echo $UID"], personaID: personaID)
    }

    /// 用 root persona 往 bundle 里建目录 + 写文件，验证「写进自己包内」可行性
    public static func bundleWriteTest() -> [String] {
        var out: [String] = []
        let dir = Bundle.main.bundlePath + "/.nmwrite"
        let (rid, _) = rootPersonaID()
        guard let bash = bundledHelper("bash.real") else {
            out.append("写包测试: 找不到 bash.real")
            return out
        }
        let script = "mkdir -p '\(dir)' && echo hello > '\(dir)/t.txt' && ls -ld '\(dir)'"
        let r1 = spawn(bash, args: ["bash.real", "-c", script], personaID: nil)
        out.append("写包(基线 mobile): rc=\(r1?.rc ?? -1) \(r1?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
        if let pid = rid {
            let r2 = spawn(bash, args: ["bash.real", "-c", script], personaID: pid)
            out.append("写包(root persona): rc=\(r2?.rc ?? -1) \(r2?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
        }
        return out
    }

    public static func bundledHelper(_ name: String) -> String? {
        let p = Bundle.main.bundlePath + "/Helpers/" + name
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// forkless posix_spawn，可选 persona
    public static func spawn(_ path: String, args: [String], personaID: Int32?) -> (rc: Int32, output: String)? {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)

        let outURL = documentsURL().appendingPathComponent("spawn-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let fd = open(outURL.path, O_WRONLY | O_TRUNC)
        if fd >= 0 { posix_spawn_file_actions_adddup2(&actions, fd, 1) }

        if let pid = personaID {
            let rc = setPersona(&attr, id: pid, flags: overrideFlag)
            if rc != 0 {
                if fd >= 0 { close(fd) }
                posix_spawnattr_destroy(&attr)
                posix_spawn_file_actions_destroy(&actions)
                return (rc, "set_persona_np rc=\(rc)")
            }
        }

        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
        argv.append(nil)
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, environ)
        for a in argv { free(a) }
        if fd >= 0 { close(fd) }
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&actions)

        let text = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outURL)
        if rc != 0 { return (rc, text) }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return ((status >> 8) & 0xff, text)
    }
}
