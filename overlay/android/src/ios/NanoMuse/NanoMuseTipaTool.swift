import Foundation

/// `tipa_build`：把 .app 打包成可安装的 .tipa —— 让 Agent 写完代码后直接产出安装包。
///
/// 关键点：**全程不 fork**。复制用 Foundation、签名用 `codex-sign` 的 posix_spawn、
/// 压缩用 Compression、打包用自写 ZIP。所以它在「宿主 fork 被 iOS 禁用」的设备上
/// 照样能用 —— 这也正是 MT-Agent 能在本地出包的原因（打包本来就不需要 fork）。
enum NanoMuseTipaTool {

    static let toolName = "tipa_build"

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: toolName,
            description: """
            Package a .app bundle into an installable .tipa WITHOUT forking: it copies the bundle, \
            re-signs the main executable with the entitlements plist, keeps existing nested \
            signatures (Helpers / dylibs / appex), compresses in-process and writes the ZIP itself. \
            Use it when you generated or patched an app and want a file the user can install with \
            TrollStore. Leave `app` empty to package the running app. The result is written to the \
            app's Documents folder and the absolute path is returned.
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user. Use the user's language."),
                "app": AgentToolParam(type: .string, description: "Absolute path of the .app bundle to package. Empty = package the running app."),
                "output": AgentToolParam(type: .string, description: "Optional output file name, e.g. MyApp.tipa. Defaults to <app name>.tipa."),
            ],
            required: ["tool_title"],
            propertyOrdering: ["tool_title", "app", "output"]
        )
    }

    struct Outcome: Sendable {
        let exitCode: Int32
        let text: String
    }

    static func execute(app: String, output: String?) async -> Outcome {
        let trimmed = app.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? Bundle.main.bundlePath : trimmed
        let name = (output?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let report = await NanoMuseTipaBuilder.build(appPath: path, outputName: name)
        var text = report.text
        if report.ok, let tipa = report.tipa {
            text += "\n结果：\(tipa)"
        }
        return Outcome(exitCode: report.ok ? 0 : 1, text: text)
    }
}
