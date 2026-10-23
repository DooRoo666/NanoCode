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
            Available binaries: bash builtins plus onPath helpers (cat, ls, grep, tar, xxd, sed … from ca-filetool) \
            and codex-sign. For Linux tooling (git/python/apk) keep using shell_execute instead.
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
        guard NanoMuseHelperRunner.exists("bash.real") else {
            return Outcome(exitCode: 127,
                           text: "缺少随包的 bash.real（构建时需要 vendor/helpers），无法在宿主层执行。")
        }
        let result = await Task.detached(priority: .userInitiated) {
            NanoMuseHelperRunner.run("bash.real", arguments: ["-lc", command], timeout: timeout)
        }.value
        let body = result.output.isEmpty ? "（无输出）" : result.output
        return Outcome(exitCode: result.exitCode, text: body)
    }
}
