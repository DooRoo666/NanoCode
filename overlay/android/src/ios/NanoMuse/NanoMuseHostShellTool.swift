import Foundation

/// 原生执行工具：**绕开 iSH**，用随包的 `bash.real` 在宿主进程里跑命令。
///
/// 为什么需要它：iSH 里的 Linux 是 fake fs + 用户态 syscall 层，
/// TrollStore 给 Minis 的 entitlements（no-sandbox / platform-application …）
/// 只作用于 Minis 自己 spawn 出来的原生子进程，**不会**进入 iSH 的 Linux 世界。
/// 所以要读宿主任意路径（其他 App 容器、/private/var/mobile…），必须走这里。
enum NanoMuseHostShellTool {

    static let toolName = "host_exec"

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: toolName,
            description: """
            Run a shell command on the HOST (iOS) side, outside the iSH Linux sandbox, using the app's own \
            TrollStore entitlements. Use it when you need real device paths (e.g. /private/var/mobile/..., \
            other apps' containers), real /dev nodes, or anything iSH's fake filesystem cannot see. \
            The shell is nsh (forkless, posix_spawn based): pipes `a | b`, redirections `> >> < 2> 2>&1`, \
            `;` `&&` `||`, leading `!`, `$VAR` `${VAR}` `$?` `$$`, `VAR=value`, `$( )`, globs, `cd`, `export`, \
            `test` / `[`, plus onPath helpers (cat, ls, grep, tar, xxd, sed … from ca-filetool) and codex-sign \
            are all supported; `for` / `while` / `if` / `case` scripts are delegated to bash.real internally. \
            Not supported: `( )` subshell and `&` background jobs. \
            For Linux tooling (git/python/apk) keep using shell_execute instead.
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user. Use the user's language."),
                "command": AgentToolParam(type: .string, description: "Shell command to run on the host, e.g. `ls -l /private/var/mobile/Containers`."),
                "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default 60)."),
            ],
            required: ["tool_title", "command"],
            propertyOrdering: ["tool_title", "command", "timeout"]
        )
    }

    struct Outcome: Sendable {
        let exitCode: Int32
        let text: String
    }

    static func execute(command: String, timeout: TimeInterval) async -> Outcome {
        let nsh = NanoMuseHelperRunner.path("nsh")
        let bash = NanoMuseHelperRunner.path("bash.real")
        let hasNsh = FileManager.default.isExecutableFile(atPath: nsh)
        let hasBash = FileManager.default.isExecutableFile(atPath: bash)
        guard hasNsh || hasBash else {
            return Outcome(exitCode: 127,
                           text: "缺少随包的 nsh / bash.real（构建时需要 vendor/helpers），无法在宿主层执行。")
        }
        // 为什么优先 nsh：
        // bash.real 执行管道 `|`、重定向 `>`、子 shell `( )`、命令替换 `$( )`、后台 `&`
        // 全靠 fork()，而 iOS 上这条路径必然 SIGBUS（Bus error 10）。
        // 结果就是 host_exec 只要命令里有 `| head` 就整个崩掉。
        // nsh 用 posix_spawn 实现同样的语义，全程不 fork，所以默认走它。
        let shell = hasNsh ? nsh : bash
        let result = await Task.detached(priority: .userInitiated) {
            NanoMuseHelperRunner.run(shell, arguments: ["-lc", command], timeout: timeout)
        }.value
        let body = result.output.isEmpty ? "（无输出）" : result.output
        return Outcome(exitCode: result.exitCode, text: body)
    }
}
