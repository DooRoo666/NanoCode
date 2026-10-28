import SwiftUI

// MARK: - 两套环境

/// 本 App 有两套互不相干的环境，工具、检测、安装进度都要分开看：
/// - host：Mach-O 运行时，装在 App 包内（NanoMuseNativeRuntime.rootDirectory）
/// - alpine：iSH 里的 Alpine 根文件系统（apk / /usr/bin）
enum NanoMuseEnvScope: String, CaseIterable, Identifiable {
    case host
    case alpine

    var id: String { rawValue }

    var title: String { self == .host ? "宿主（App 内置）" : "Alpine（iSH）" }

    var short: String { self == .host ? "宿主" : "Alpine" }

    var note: String {
        switch self {
        case .host:
            return "Mach-O 运行时，装在 App 包里、用本 App 的签名执行；不需要 iSH，也不需要 root。"
        case .alpine:
            return "Linux 工具，装在 iSH 的 Alpine 根文件系统里（apk），只有 iSH 侧的命令能调用。"
        }
    }

    var rootText: String {
        switch self {
        case .host:
            return (NanoMuseNativeRuntime.rootDirectory.path as NSString).abbreviatingWithTildeInPath
        case .alpine:
            return "/usr/bin · /usr/local/bin（iSH）"
        }
    }

    var shellHint: String {
        switch self {
        case .host:
            return "宿主可执行文件直接调用，例如 codex exec …"
        case .alpine:
            return "iSH 里执行：apk add <包名>，例如 apk add jq"
        }
    }
}

// MARK: - 宿主运行时清单

struct NanoMuseHostRuntimeEntry: Identifiable {
    let id: String
    let title: String
    let hint: String
    let installed: Bool
    let version: String?

    var statusText: String {
        guard installed else { return "未安装" }
        if let version, !version.isEmpty { return "已安装 · \(version)" }
        return "已安装"
    }
}

enum NanoMuseHostRuntimes {
    /// id / 名称 / 说明（与远端 manifest 的运行时 id 对齐）
    static let catalog: [(id: String, title: String, hint: String)] = [
        ("codex", "Codex CLI", "exec · apply_patch · goal 工具集"),
        ("core_tools", "Core Tools", "git · jq · rg · curl · zip"),
        ("build_tools", "Build Tools", "clang · ld64 · make"),
        ("python", "Python", "CPython + pip"),
        ("node", "Node.js", "node · npm"),
        ("theos", "Theos", "iOS 开发 / 注入链"),
        ("ollvm", "OLLVM", "混淆编译器"),
        ("reverse_tools", "Reverse Tools", "radare2 · mt-*")
    ]

    static func entries() -> [NanoMuseHostRuntimeEntry] {
        var rows: [NanoMuseHostRuntimeEntry] = catalog.map { item in
            let installed = NanoMuseNativeRuntime.isInstalled(item.id)
            return NanoMuseHostRuntimeEntry(
                id: item.id,
                title: item.title,
                hint: item.hint,
                installed: installed,
                version: installed ? version(for: item.id) : nil
            )
        }

        // 清单外但已装的（远端 manifest 换过 id 时也不会漏）
        let knownIDs = Set(catalog.map { $0.id })
        for extra in NanoMuseNativeRuntime.installedIDs() where !knownIDs.contains(extra) {
            rows.append(
                NanoMuseHostRuntimeEntry(
                    id: extra,
                    title: extra,
                    hint: "清单外的运行时",
                    installed: true,
                    version: version(for: extra)
                )
            )
        }
        return rows
    }

    static func version(for id: String) -> String? {
        let dir = NanoMuseNativeRuntime.directory(for: id)
        for name in ["manifest.json", "version.json", ".installed", "VERSION"] {
            let url = dir.appendingPathComponent(name)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("{"),
               let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = (object["version"] as? String) ?? (object["tag"] as? String) {
                return version
            }
            // .installed 里可能是纯版本号，也可能是 64 位哈希
            if trimmed.count <= 24, trimmed.rangeOfCharacter(from: .decimalDigits) != nil {
                return trimmed
            }
        }
        return nil
    }
}

// MARK: - 分组标题

struct NanoMuseEnvHeader: View {
    let title: String
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NanoMuseTones.action)
            Text(note)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}

// MARK: - Codex 环境选择（宿主 / Alpine 各一份）

struct NanoMuseCodexEnvPickerCard: View {
    var body: some View {
        NanoMuseCard {
            NanoMuseEnvHeader(
                title: "Codex 装在哪套环境里",
                note: "两套是独立的：宿主 Codex 走 App 包内的 Mach-O 运行时，Alpine Codex 走 iSH 里 apk 装的 Linux 版。点进哪一条就只显示哪一套。"
            )
            NanoMuseLinkRow(title: "宿主 Codex", value: hostState) {
                NanoMuseCodexScopePage(scope: .host)
            }
            NanoMuseRowDivider()
            NanoMuseLinkRow(title: "Alpine Codex", value: "iSH · apk") {
                NanoMuseCodexScopePage(scope: .alpine)
            }
        }
    }

    private var hostState: String {
        NanoMuseNativeRuntime.isInstalled("codex") ? "已安装" : "未安装"
    }
}

struct NanoMuseCodexScopePage: View {
    let scope: NanoMuseEnvScope

    @State private var report: [String] = []
    @State private var busy = false
    @State private var checkedAt: Date?

    var body: some View {
        NanoMusePage(title: "Codex · \(scope.short)") {
            NanoMuseCard {
                NanoMuseEnvHeader(title: scope.title, note: scope.note)
                NanoMuseRowLabel(title: "安装位置", value: scope.rootText)
                NanoMuseRowDivider()
                NanoMuseRowLabel(title: "调用方式", value: scope.shellHint)
                NanoMuseRowDivider()
                NanoMuseRowLabel(title: "状态", value: statusText)
            }

            NanoMuseCard {
                NanoMuseEnvHeader(
                    title: "本环境检测",
                    note: "只检查 \(scope.short) 这一套，不会去碰另一套。"
                )
                NanoMuseActionRow(title: busy ? "检测中…" : "开始检测") {
                    Task { await run() }
                }
                if let checkedAt {
                    NanoMuseCaption(text: "上次检测：\(Self.timeText(checkedAt))")
                }
                if !report.isEmpty {
                    NanoMuseRowDivider()
                    ForEach(Array(report.enumerated()), id: \.offset) { item in
                        NanoMuseCaption(text: item.element)
                    }
                }
            }
        }
        .task { if report.isEmpty { await run() } }
    }

    private var statusText: String {
        switch scope {
        case .host:
            if NanoMuseNativeRuntime.isInstalled("codex") {
                let version = NanoMuseHostRuntimes.version(for: "codex")
                return version.map { "已安装 · \($0)" } ?? "已安装"
            }
            return "未安装"
        case .alpine:
            return "见下方检测结果"
        }
    }

    private func run() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        switch scope {
        case .host:
            report = hostReport()
        case .alpine:
            let (code, output) = await NanoMuseCodex.runCommand(
                "echo \"PATH=$PATH\"; command -v codex || echo 'codex: 未安装'; "
                + "codex --version 2>&1 | head -2; echo '--- 配置 ---'; "
                + "ls -1 ~/.codex 2>/dev/null | head -12 || echo '无 ~/.codex'",
                timeout: 90
            )
            var lines = ["退出码：\(code)"]
            lines.append(contentsOf: output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            report = lines
        }
        checkedAt = Date()
    }

    private func hostReport() -> [String] {
        var lines: [String] = []
        let root = NanoMuseNativeRuntime.rootDirectory
        lines.append("运行时根目录：\(root.path)")

        let codexDir = NanoMuseNativeRuntime.directory(for: "codex")
        if NanoMuseNativeRuntime.isInstalled("codex") {
            lines.append("codex 运行时目录：\(codexDir.path)")
            if let binary = NanoMuseNativeRuntime.codexBinary(in: codexDir) {
                lines.append("codex 二进制：\(binary.path)")
                lines.append("大小：\(Self.byteText(binary.size))")
            } else {
                lines.append("codex 二进制：未找到（运行时目录不完整，建议重装）")
            }
        } else {
            lines.append("codex 运行时未安装 → 运行时 → 原生 → 安装 Codex")
        }

        var others: [String] = []
        for id in NanoMuseNativeRuntime.installedIDs() where id != "codex" {
            others.append("\(id)\(NanoMuseHostRuntimes.version(for: id).map { " \($0)" } ?? "")")
        }
        lines.append("其它宿主运行时：" + (others.isEmpty ? "无" : others.joined(separator: "、")))
        lines.append("这套环境不经过 iSH；Swift 进程直接调用这里的 Mach-O。")
        return lines
    }

    private static func byteText(_ bytes: Int) -> String {
        if bytes > 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / 1048576.0) }
        if bytes > 1024 { return String(format: "%.0f KB", Double(bytes) / 1024.0) }
        return "\(bytes) B"
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
