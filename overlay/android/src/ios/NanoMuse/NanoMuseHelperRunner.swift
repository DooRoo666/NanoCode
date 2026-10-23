import Foundation
import Darwin

/// 运行 App 包内 `Helpers/` 里的 Mach-O 工具（MT-Agent 的 codex-sign / ca-filetool / bash.real）。
///
/// 这些是 **iOS 原生** 二进制，不能在 Alpine 里跑，所以用 posix_spawn 直接起，
/// stdout/stderr 重定向到临时文件（避免管道读满死锁），退出后一次读回。
enum NanoMuseHelperRunner {

    struct Result: Sendable {
        let exitCode: Int32
        let output: String
        let duration: TimeInterval
    }

    static var helpersDirectory: String {
        Bundle.main.bundlePath + "/Helpers"
    }

    static func path(_ name: String) -> String {
        helpersDirectory + "/" + name
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path(name))
    }

    /// 已随包进来的几个关键工具
    static var bundled: [(name: String, present: Bool)] {
        ["codex-sign", "ca-filetool", "bash.real"].map { ($0, exists($0)) }
    }

    static func run(_ name: String, arguments: [String] = [], timeout: TimeInterval = 60) -> Result {
        let started = Date()
        let executable = path(name)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return Result(exitCode: -1,
                          output: "未找到可执行文件：\(executable)\n（构建时需要 vendor/helpers，见 make_tipa.sh 第 0 步）",
                          duration: 0)
        }

        let logPath = NSTemporaryDirectory() + "nanocodex-helper-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: logPath) else {
            return Result(exitCode: -1, output: "无法创建日志文件", duration: 0)
        }
        defer { try? FileManager.default.removeItem(atPath: logPath) }

        let fd = handle.fileDescriptor
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fd, 1)
        posix_spawn_file_actions_adddup2(&actions, fd, 2)

        var argv = cStrings([executable] + arguments)
        var envp = cStrings(environment())
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable, &actions, nil, &argv, &envp)

        freeCStrings(&argv)
        freeCStrings(&envp)
        posix_spawn_file_actions_destroy(&actions)
        handle.closeFile()

        guard rc == 0 else {
            return Result(exitCode: -1,
                          output: "posix_spawn 失败：\(String(cString: strerror(rc)))",
                          duration: Date().timeIntervalSince(started))
        }

        var status: Int32 = 0
        let deadline = Date().addingTimeInterval(timeout)
        var killed = false
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if Date() >= deadline {
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                killed = true
                break
            }
            usleep(50_000)
        }

        let output = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : -1
        let header = killed ? "[超时 \(Int(timeout))s，已终止]\n" : ""
        return Result(exitCode: code, output: header + output,
                      duration: Date().timeIntervalSince(started))
    }

    // MARK: - C 字符串

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var out = strings.map { strdup($0) }
        out.append(nil)
        return out
    }

    private static func freeCStrings(_ array: inout [UnsafeMutablePointer<CChar>?]) {
        for pointer in array where pointer != nil { free(pointer) }
        array.removeAll()
    }

    private static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = helpersDirectory + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = NSHomeDirectory()
        return env.map { "\($0.key)=\($0.value)" }
    }
}
