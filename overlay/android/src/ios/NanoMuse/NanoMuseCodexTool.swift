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
        let status = await NanoMuseCodex.status()
        guard status.installed else {
            return Outcome(
                exitCode: 127,
                text: "Codex 尚未安装。到 设置 → Codex 点「原生安装（推荐）」（原版 iphoneos-arm64 包，约 95 MB），装完点「重新检测」。"
            )
        }

        // 模型来源二选一：跟随 nanoMuse 的 provider，或用户自填的第三方
        let credential = await MainActor.run { NanoMuseCodexSettings.resolved() }
        let model = NanoMuseCodexSettings.current.model

        let result = await Task.detached(priority: .userInitiated) {
            await NanoMuseCodex.execute(
                prompt: prompt,
                workspace: workspace,
                apiKey: credential.apiKey,
                baseURL: credential.baseURL,
                model: model,
                timeout: timeout
            )
        }.value

        let text = result.output.isEmpty ? result.errorOutput : result.output
        return Outcome(exitCode: result.exitCode, text: text)
    }
}

// MARK: - 用户设置（来源 / Key / 地址 / 模型）持久化

enum NanoMuseCodexSettings {

    struct Values: Sendable {
        let source: NanoMuseCodexSource
        let apiKey: String
        let baseURL: String
        let model: String
    }

    private enum Key {
        static let source = "nanocodex.source"
        static let apiKey = "nanocodex.apiKey"
        static let baseURL = "nanocodex.baseURL"
        static let model = "nanocodex.model"
    }

    static var current: Values {
        let defaults = UserDefaults.standard
        let raw = defaults.string(forKey: Key.source) ?? NanoMuseCodexSource.followNano.rawValue
        // 旧版本把 Key 明文存在 UserDefaults，读到就迁到 Keychain 并清掉
        var key = NanoMuseCodexKeychain.load() ?? ""
        if key.isEmpty, let legacy = defaults.string(forKey: Key.apiKey), !legacy.isEmpty {
            NanoMuseCodexKeychain.save(legacy)
            defaults.removeObject(forKey: Key.apiKey)
            key = legacy
        }
        return Values(
            source: NanoMuseCodexSource(rawValue: raw) ?? .followNano,
            apiKey: key,
            baseURL: defaults.string(forKey: Key.baseURL) ?? "",
            model: defaults.string(forKey: Key.model) ?? ""
        )
    }

    /// 是否把随包的 codex-fallback-prompt.md 拼进任务前面（20.9 KB 工作准则）
    static var useFallbackPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: "nanocodex.fallbackPrompt") }
        set { UserDefaults.standard.set(newValue, forKey: "nanocodex.fallbackPrompt") }
    }

    static func save(source: NanoMuseCodexSource, apiKey: String, baseURL: String, model: String) {
        let defaults = UserDefaults.standard
        defaults.set(source.rawValue, forKey: Key.source)
        NanoMuseCodexKeychain.save(apiKey)
        defaults.set(baseURL, forKey: Key.baseURL)
        defaults.set(model, forKey: Key.model)
    }

    /// 真正拿去请求的地址与密钥：
    /// 跟随模式优先用 nanoMuse 已配好的 provider；读不到时退回用户手填值。
    @MainActor
    static func resolved() -> (baseURL: String, apiKey: String, label: String) {
        let values = current
        switch values.source {
        case .followNano:
            if let inherited = NanoMuseCodexModels.inherited() {
                return (inherited.baseURL, inherited.apiKey, inherited.label)
            }
            return (values.baseURL, values.apiKey, "手填")
        case .custom:
            return (values.baseURL, values.apiKey, "自定义")
        }
    }
}
