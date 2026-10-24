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

        // 模型来源二选一：跟随 nanoMuse 的 provider（逐个实测挑能鉴权的那家），
        // 或用户自填的第三方。跟随模式下没填模型时，用该 provider 的第一个模型兜底。
        let resolved = await NanoMuseCodexSettings.resolvedAsync()
        let credential = (baseURL: resolved.baseURL, apiKey: resolved.apiKey)
        let model = resolved.model

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
        static let wireAPI = "nanocodex.wireAPI"
    }

    /// codex 的 wire_api：第三方网关多数是 `chat`，官方与部分网关是 `responses`
    static var wireAPI: String {
        get { UserDefaults.standard.string(forKey: Key.wireAPI) ?? "responses" }
        set { UserDefaults.standard.set(newValue, forKey: Key.wireAPI) }
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

    /// 跟随模式的强化版：挨个实测 nanoMuse 的 provider，选真的能通过鉴权的那家，
    /// 顺带带回它 `/models` 里的第一个模型（第三方网关通常没有 codex 的默认模型）。
    @MainActor
    static func resolvedAsync() async -> (baseURL: String, apiKey: String, label: String, model: String) {
        let values = current
        guard values.source == .followNano else {
            return (values.baseURL, values.apiKey, "自定义", values.model)
        }
        let (chosen, _) = await NanoMuseCodexModels.resolveBest()
        guard let chosen else {
            return (values.baseURL, values.apiKey, "手填", values.model)
        }
        let model = values.model.isEmpty ? chosen.model : values.model
        return (chosen.baseURL, chosen.apiKey, chosen.label, model)
    }

    /// 诊断：把每个 provider 的「有没有 key / 打得通不通」列出来（绝不打印 key 本身）
    @MainActor
    static func diagnoseProviders() async -> [String] {
        let (chosen, probes) = await NanoMuseCodexModels.resolveBest()
        var lines = ["===== nanoMuse 的 provider（逐个实测 /models）====="]
        if probes.isEmpty { lines.append("  （没有启用中的 provider，或都缺 Base URL）") }
        for probe in probes { lines.append("  " + probe.line) }
        if let chosen {
            lines.append("选中：\(chosen.label) · \(chosen.baseURL)")
            lines.append("模型兜底：\(chosen.model.isEmpty ? "（空）" : chosen.model)")
        } else {
            lines.append("选中：无（没有哪家既有 key 又返回 200）")
        }
        lines.append("wire_api = \(wireAPI)（可在下方切换）")
        return lines
    }
}
