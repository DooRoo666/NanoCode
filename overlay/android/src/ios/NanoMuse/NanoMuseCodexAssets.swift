import Foundation

/// 原版 MT-Agent 随包的 5 个资源，现在都在 App 根目录（make_tipa.sh 第 0b 步拷进来）：
/// `Mermaid/`、`cacert.pem`、`models.json`、`codex-fallback-prompt.md`、`codex-version.txt`。
enum NanoMuseCodexAssets {

    static var bundlePath: String { Bundle.main.bundlePath }

    // MARK: - 兜底提示词

    /// 20.9 KB 的 `codex-fallback-prompt.md`：Codex 缺省系统提示（原版用于首轮）
    static func fallbackPrompt() -> String? {
        let path = bundlePath + "/codex-fallback-prompt.md"
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - 离线模型表

    /// `models.json` 里的 slug 列表（`{ "models": [ { "slug": … } ] }`）
    static func bundledModels() -> [String] {
        let path = bundlePath + "/models.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return [] }
        return rows.compactMap { $0["slug"] as? String }
    }

    /// 离线模型表里带上下文窗口的完整条目，供界面显示「272k」这类提示
    static func bundledModelDetail() -> [(slug: String, context: Int, reasoning: Bool)] {
        let path = bundlePath + "/models.json"
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["models"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let slug = row["slug"] as? String else { return nil }
            return (slug, row["context_window"] as? Int ?? 0, row["supports_reasoning"] as? Bool ?? false)
        }
    }

    // MARK: - TLS 信任根

    /// 188 KB 的 `cacert.pem`。Alpine 侧另有 `ca-certificates` 包；
    /// 这份随包副本用于「不想装包」或给自带 curl 指定 `--cacert` 的场景。
    static var caBundlePath: String? {
        let path = bundlePath + "/cacert.pem"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: - 原版 Codex 版本参照

    static func codexVersionHint() -> String? {
        let path = bundlePath + "/codex-version.txt"
        return (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Mermaid

    static var mermaidDirectory: String? {
        let path = bundlePath + "/Mermaid"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return path
    }

    /// 资源自检，界面上一行显示
    static func inventory() -> [(name: String, present: Bool)] {
        [
            ("Mermaid/mermaid.min.js", FileManager.default.fileExists(atPath: bundlePath + "/Mermaid/mermaid.min.js")),
            ("cacert.pem", caBundlePath != nil),
            ("models.json", !bundledModels().isEmpty),
            ("codex-fallback-prompt.md", fallbackPrompt() != nil),
            ("entitlements.plist", FileManager.default.fileExists(atPath: bundlePath + "/entitlements.plist")),
            ("ThirdPartyNotices", FileManager.default.fileExists(atPath: bundlePath + "/ThirdPartyNotices")),
        ]
    }
}
