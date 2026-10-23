import Foundation

/// 子代理工具：让主 Agent（nanoMuse 的对话）派活给 Codex，并在稍后取结果。
/// 与 MT-Agent 一致的心智模型：**派出去立刻返回**，不阻塞当前对话。
enum NanoMuseSubagentTool {

    static let dispatchName = "subagent_dispatch"
    static let resultName = "subagent_result"

    // MARK: - 工具声明

    static var dispatchDefinition: AgentToolDefinition {
        AgentToolDefinition(
            name: dispatchName,
            description: """
            Hand a coding task to the background Codex subagent. Returns immediately with a job id; \
            the subagent keeps working while the conversation continues, then reports back. \
            Use it for multi-step coding work that would otherwise block the chat \
            (write a program, refactor files, fix a test suite). Call subagent_result later to collect the answer.
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user. Use the user's language."),
                "prompt": AgentToolParam(type: .string, description: "The task for the subagent, in natural language. Be specific about files and the expected outcome."),
                "workspace": AgentToolParam(type: .string, description: "Absolute Linux path the subagent may work in (default /root/work)."),
                "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default 1800)."),
            ],
            required: ["tool_title", "prompt"],
            propertyOrdering: ["tool_title", "prompt", "workspace", "timeout"]
        )
    }

    static var resultDefinition: AgentToolDefinition {
        AgentToolDefinition(
            name: resultName,
            description: """
            Collect results of background subagent jobs started with subagent_dispatch. \
            Returns each finished job's output once; already-delivered results are not repeated. \
            If nothing has finished yet, say so and keep talking — do not block.
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise summary for the user. Use the user's language."),
            ],
            required: ["tool_title"],
            propertyOrdering: ["tool_title"]
        )
    }

    // MARK: - 执行

    static func dispatch(prompt: String, workspace: String, timeout: TimeInterval) async -> String {
        let status = NanoMuseCodex.status()
        guard status.installed else {
            return "Codex 尚未安装，子代理无法启动。请到 设置 → Codex 安装（或先用 shell_execute 装）。"
        }
        let job = await MainActor.run {
            NanoMuseSubagentCenter.shared.dispatch(kind: .codex,
                                                   prompt: prompt,
                                                   workspace: workspace,
                                                   timeout: timeout)
        }
        return """
        已在后台启动 Codex 子代理：作业 \(job.id)
        - 工作目录：\(job.workspace)
        - 任务：\(String(prompt.prefix(120)))
        我先继续对话；稍后用 subagent_result 取结果（完成时也会发本地通知）。
        """
    }

    static func collect() async -> String {
        let jobs = await MainActor.run { NanoMuseSubagentCenter.shared.pendingForAgent() }
        guard !jobs.isEmpty else {
            return "暂无已完成的子代理结果。任务仍在后台运行时，可以先继续别的步骤。"
        }
        var lines: [String] = []
        for job in jobs {
            let ok = job.exitCode == 0
            lines.append("""
            === 作业 \(job.id) · \(ok ? "成功" : "失败") · 退出码 \(job.exitCode) · \(job.durationText) ===
            任务：\(String(job.prompt.prefix(160)))
            \(String(job.output.suffix(3000)))
            """)
        }
        return lines.joined(separator: "\n\n")
    }
}
