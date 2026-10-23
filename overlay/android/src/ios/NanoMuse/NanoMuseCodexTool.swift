import Foundation

/// Codex 作为 Agent 工具：让 nanoMuse 的对话自己调用 Codex 干编码任务。
///
/// 执行路径是 App 自带的 Alpine（aarch64）→ `/usr/local/bin/codex exec …`，
/// 因此不需要额外 entitlement，也不需要把 codex 交叉编译进 App。
enum NanoMuseCodexTool {

    static let toolName = "codex_exec"

    // MARK: - 给模型的工具声明

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: toolName,
            description: """
            Run the Codex coding agent inside the local Linux environment (aarch64 Alpine). \
            Use it for multi-step coding work in a workspace: it reads and edits files, runs commands \
            and reports back. Prefer it over shell_execute when the task is "write/fix a program" \
            rather than "run this one command". Requires Codex to be installed (Settings → Codex).
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user (e.g. 'Scaffold a Rust CLI', 'Fix the failing unit test'). Use the user's language."),
                "prompt": AgentToolParam(type: .string, description: "The task for Codex in natural language. Be specific about files and expected outcome."),
                "workspace": AgentToolParam(type: .string, description: "Absolute Linux path Codex may work in (default /root/work)."),
                "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default 900)."),
            ],
            required: ["tool_title", "prompt"],
            propertyOrdering: ["tool_title", "prompt", "workspace", "timeout"]
        )
    }

    // MARK: - 执行

    struct Outcome: Sendable {
        let exitCode: Int32
        let text: String
    }

    static func execute(prompt: String, workspace: String, timeout: TimeInterval) async -> Outcome {
        let status = NanoMuseCodex.status()
        guard status.installed else {
            return Outcome(
                exitCode: 127,
                text: "Codex 尚未安装。请到 设置 → Codex 点「安装 Codex」（约 100 MB，装在本地 Alpine 里），或先运行 shell_execute 安装。"
            )
        }

        let settings = NanoMuseCodexSettings.current
        let result = await Task.detached(priority: .userInitiated) {
            NanoMuseCodex.execute(
                prompt: prompt,
                workspace: workspace,
                apiKey: settings.apiKey,
                baseURL: settings.baseURL,
                model: settings.model,
                timeout: timeout
            )
        }.value

        let text = result.output.isEmpty ? result.errorOutput : result.output
        return Outcome(exitCode: result.exitCode, text: text)
    }
}

// MARK: - 用户设置（Key / 地址 / 模型）持久化

enum NanoMuseCodexSettings {

    struct Values: Sendable {
        let apiKey: String
        let baseURL: String
        let model: String
    }

    private enum Key {
        static let apiKey = "nanocodex.apiKey"
        static let baseURL = "nanocodex.baseURL"
        static let model = "nanocodex.model"
    }

    static var current: Values {
        let defaults = UserDefaults.standard
        return Values(
            apiKey: defaults.string(forKey: Key.apiKey) ?? "",
            baseURL: defaults.string(forKey: Key.baseURL) ?? "",
            model: defaults.string(forKey: Key.model) ?? ""
        )
    }

    static func save(apiKey: String, baseURL: String, model: String) {
        let defaults = UserDefaults.standard
        defaults.set(apiKey, forKey: Key.apiKey)
        defaults.set(baseURL, forKey: Key.baseURL)
        defaults.set(model, forKey: Key.model)
    }

    /// 复用已经配置好的 OpenAI 兼容 provider：省得用户在 Codex 里再填一遍
    static var inheritedFromProvider: Values? {
        let defaults = UserDefaults.standard
        guard let base = defaults.string(forKey: Key.baseURL), !base.isEmpty else { return nil }
        return Values(apiKey: defaults.string(forKey: Key.apiKey) ?? "", baseURL: base,
                      model: defaults.string(forKey: Key.model) ?? "")
    }
}
