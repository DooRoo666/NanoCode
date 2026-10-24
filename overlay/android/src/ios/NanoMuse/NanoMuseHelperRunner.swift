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

    static func run(_ name: String,
                    arguments: [String] = [],
                    timeout: TimeInterval = 60,
                    extraEnvironment: [String: String] = [:],
                    workingDirectory: String? = nil) -> Result {
        _ = workingDirectory   // iOS 没有 addchdir_np；需要 cwd 时用 bash.real -lc 包一层
        let started = Date()
        let executable = name.hasPrefix("/") ? name : path(name)
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
        var envp = cStrings(environment(extra: extraEnvironment))
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
        let signal = status & 0x7f
        let code: Int32 = signal == 0 ? (status >> 8) & 0xff : 128 + signal
        var header = ""
        if killed {
            header = "[超时 \(Int(timeout))s，已终止]\n"
        } else if signal != 0 {
            header = "[被信号 \(signal) 终止：\(signalName(signal))]\n"
        }
        return Result(exitCode: code, output: header + output,
                      duration: Date().timeIntervalSince(started))
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case 4: return "SIGILL（非法指令，常见于架构不匹配）"
        case 5: return "SIGTRAP"
        case 6: return "SIGABRT"
        case 9: return "SIGKILL（可能被 AMFI/看门狗杀掉，常见于签名不被接受）"
        case 10: return "SIGBUS"
        case 11: return "SIGSEGV"
        case 12: return "SIGSYS（系统调用被拒）"
        case 31: return "SIGSYS(31)"
        default: return "signal \(signal)"
        }
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

    private static func environment(extra: [String: String] = [:]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = helpersDirectory + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = NSHomeDirectory()
        for (key, value) in extra { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
