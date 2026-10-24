import Foundation

/// 宿主文件系统工具：**完全不创建进程**，只用 Foundation 读写。
///
/// 为什么需要它：有些设备上「创建进程」本身是坏的（连 bash 的 `( exit 1 )` 都 SIGBUS /
/// os error 85），`host_exec`、`codex`、Theos 这些要 spawn 的东西全都起不来；
/// 但读文件、列目录不涉及 fork，依旧正常。这个工具就是那条“不 fork 也能看系统数据”的路。
enum NanoMuseHostFileTool {

    static let toolName = "host_fs"

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: toolName,
            description: """
            Inspect the HOST (iOS) filesystem in-process with Foundation — no shell, no fork, no child \
            process. Use it when process creation is unavailable or when you need real device paths \
            (e.g. /private/var/mobile/..., other apps' containers, /System/Library/...). \
            `op=list` lists a directory with type and size, `op=read` returns text (or a hex preview for \
            binary), `op=stat` returns attributes. Paths must be absolute.
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user. Use the user's language."),
                "op": AgentToolParam(type: .string, description: "One of: list, read, stat."),
                "path": AgentToolParam(type: .string, description: "Absolute host path, e.g. /private/var/mobile/Library/Preferences."),
                "max_bytes": AgentToolParam(type: .integer, description: "For read: max bytes to return (default 65536)."),
            ],
            required: ["tool_title", "op", "path"],
            propertyOrdering: ["tool_title", "op", "path", "max_bytes"]
        )
    }

    struct Outcome: Sendable {
        let exitCode: Int32
        let text: String
    }

    static func execute(op: String, path: String, maxBytes: Int) async -> Outcome {
        let fm = FileManager.default
        let clean = (path as NSString).expandingTildeInPath
        guard clean.hasPrefix("/") else {
            return Outcome(exitCode: 1, text: "需要绝对路径，收到：\(path)")
        }

        switch op.lowercased() {
        case "list", "ls", "dir":
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: clean, isDirectory: &isDir) else {
                return Outcome(exitCode: 1, text: "不存在：\(clean)")
            }
            if !isDir.boolValue {
                return Outcome(exitCode: 0, text: statLine(clean))
            }
            let names = (try? fm.contentsOfDirectory(atPath: clean)) ?? []
            if names.isEmpty { return Outcome(exitCode: 0, text: "（空目录或不可读）\(clean)") }
            var lines = ["\(clean)  共 \(names.count) 项"]
            for name in names.sorted().prefix(500) {
                lines.append(statLine(clean + "/" + name))
            }
            return Outcome(exitCode: 0, text: lines.joined(separator: "\n"))

        case "read", "cat":
            guard let attrs = try? fm.attributesOfItem(atPath: clean) else {
                return Outcome(exitCode: 1, text: "读不到：\(clean)")
            }
            let size = (attrs[.size] as? Int) ?? 0
            let limit = max(1, min(maxBytes <= 0 ? 65_536 : maxBytes, 4 * 1_048_576))
            guard let handle = FileHandle(forReadingAtPath: clean) else {
                return Outcome(exitCode: 1, text: "打不开：\(clean)")
            }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: min(size, limit))) ?? Data()
            if let text = String(data: data, encoding: .utf8) {
                return Outcome(exitCode: 0, text: "\(clean)  \(size) B\n" + text)
            }
            let preview = data.prefix(4096).map { String(format: "%02x", $0) }.joined(separator: " ")
            return Outcome(exitCode: 0, text: "\(clean)  \(size) B（非 UTF-8，十六进制预览前 \(min(size, 4096)) B）\n" + preview)

        case "stat":
            return Outcome(exitCode: 0, text: statLine(clean))

        default:
            return Outcome(exitCode: 1, text: "未知 op=\(op)，可用：list / read / stat")
        }
    }

    private static func statLine(_ path: String) -> String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            return "不存在  \(path)"
        }
        let type = (attrs[.type] as? FileAttributeType) == .typeDirectory ? "d" : "-"
        let size = (attrs[.size] as? Int) ?? 0
        let mode = (attrs[.posixPermissions] as? Int) ?? 0
        let readable = fm.isReadableFile(atPath: path) ? "r" : "-"
        let writable = fm.isWritableFile(atPath: path) ? "w" : "-"
        let owner = (attrs[.ownerAccountName] as? String) ?? "?"
        return String(format: "%@ %@%@ %8d  %@  %@", type, readable, writable, size, owner, path)
            + (mode == 0 ? "" : String(format: "  (0%o)", mode))
    }
}
