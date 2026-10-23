import SwiftUI

/// 设置 › Codex —— 全部用 nanoMuse 自己的设计系统：
/// `NanoMusePage` 画布、`NanoMuseCard` 卡片、`NanoMuseRowLabel` / `NanoMuseActionRow` 行、
/// `NanoMuseCaption` 说明、`NanoMuseTones` 取色。和「模型」「设备」等页同一套观感。
struct NanoMuseCodexView: View {

    @State private var status: NanoMuseCodex.Status?
    @State private var busy = false
    @State private var phaseText = ""
    @State private var progress: Double?
    @State private var output = ""
    @State private var prompt = ""

    @State private var apiKey = NanoMuseCodexSettings.current.apiKey
    @State private var baseURL = NanoMuseCodexSettings.current.baseURL
    @State private var model = NanoMuseCodexSettings.current.model

    private var statusText: String {
        guard let status else { return "检测中…" }
        return status.installed ? "已安装 \(status.version ?? "")" : "未安装"
    }

    var body: some View {
        NanoMusePage(title: "Codex") {
            installCard
            NanoMuseCaption(text: "在手机本地的 Alpine（aarch64）里安装官方 codex 二进制，约 100 MB。装好后 Agent 就能用 codex_exec 工具自主改代码。")

            toolsCard
            NanoMuseCaption(text: "工具由模型在对话里自行调用：说要「写个程序」「修这个 bug」时它会用 codex_exec，只想跑一条命令时用 shell_execute。")

            credentialsCard
            NanoMuseCaption(text: "留空则沿用 Codex 自己的配置（环境变量或 ~/.codex/config.toml）。")

            runCard
            if !output.isEmpty {
                outputCard
            }
        }
        .task { await refresh() }
    }

    // MARK: - 安装（带下载进度）

    private var installCard: some View {
        NanoMuseCard {
            NanoMuseRowLabel(title: "状态", value: statusText, titleColor: .primary, chevron: false)

            if busy {
                NanoMuseRowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    if let progress {
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                            .tint(NanoMuseTones.action)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(NanoMuseTones.action)
                    }
                    Text(phaseText.isEmpty ? "准备中…" : phaseText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            NanoMuseRowDivider()
            NanoMuseActionRow(title: busy ? "安装中…" : "安装 / 更新 Codex", chevron: false) {
                guard !busy else { return }
                install()
            }
        }
    }

    // MARK: - 工具

    private var toolsCard: some View {
        NanoMuseCard {
            NanoMuseRowLabel(title: "codex_exec", value: "Agent 工具 · 已注册", titleColor: .primary, chevron: false)
            NanoMuseRowDivider()
            NanoMuseRowLabel(title: "codex 二进制",
                             value: (status?.installed ?? false) ? (status?.version ?? "已安装") : "未安装",
                             titleColor: .primary, chevron: false)
            NanoMuseRowDivider()
            NanoMuseRowLabel(title: "app-server 引擎", value: "已编译", titleColor: .primary, chevron: false)
        }
    }

    // MARK: - 凭据

    private var credentialsCard: some View {
        NanoMuseCard {
            field("Base URL", placeholder: "https://api.openai.com/v1", text: $baseURL, secure: false)
            NanoMuseRowDivider()
            field("API Key", placeholder: "sk-…", text: $apiKey, secure: true)
            NanoMuseRowDivider()
            field("模型", placeholder: "gpt-5-codex（可留空）", text: $model, secure: false)
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "保存", chevron: false) {
                NanoMuseCodexSettings.save(apiKey: apiKey, baseURL: baseURL, model: model)
                output = "已保存。"
            }
        }
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>,
                       secure: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(width: 84, alignment: .leading)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .font(.body)
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 试跑

    private var runCard: some View {
        NanoMuseCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("任务")
                    .font(.body)
                    .foregroundStyle(.primary)
                TextEditor(text: $prompt)
                    .font(.body.monospaced())
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .background(NanoMuseTones.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("例如：把这个目录整理成一个可运行的 Python CLI")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 6)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            NanoMuseRowDivider()
            NanoMuseActionRow(title: busy ? "运行中…" : "运行 Codex", chevron: false) {
                guard !busy,
                      !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                run()
            }
        }
    }

    private var outputCard: some View {
        NanoMuseCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("输出")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - 动作

    private func refresh() async {
        let current = await Task.detached(priority: .userInitiated) { NanoMuseCodex.status() }.value
        status = current
    }

    private func install() {
        busy = true
        progress = 0
        phaseText = "准备中…"
        NanoMuseCodex.installStreaming(force: false) { line in
            handle(line)
        } onFinish: { ok in
            if !ok { phaseText = "安装未完成，稍后重试或查看下方输出。" }
            busy = false
            Task { await refresh() }
        }
    }

    /// 行回调（主队列）：`PHASE …` 是阶段，`BYTES 已下载 总大小` 用来算百分比。
    private func handle(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.hasPrefix("BYTES ") {
            let parts = trimmed.split(separator: " ")
            if parts.count >= 3,
               let done = Double(parts[1]), let total = Double(parts[2]), total > 0 {
                progress = done / total
                phaseText = String(format: "下载中 %.0f%% · %.1f / %.1f MB",
                                   (done / total) * 100, done / 1048576, total / 1048576)
            } else if parts.count >= 2, let done = Double(parts[1]) {
                phaseText = String(format: "下载中 · %.1f MB", done / 1048576)
            }
            return
        }

        if trimmed.hasPrefix("PHASE ") {
            let phase = String(trimmed.dropFirst(6))
            switch true {
            case phase.hasPrefix("prepare"):   phaseText = "准备环境…"; progress = 0.02
            case phase.hasPrefix("download"):  phaseText = "开始下载…"; progress = 0.05
            case phase.hasPrefix("extract"):   phaseText = "解包…"; progress = 0.85
            case phase.hasPrefix("verify"):    phaseText = "校验版本…"; progress = 0.95
            case phase.hasPrefix("done"):      phaseText = "完成"; progress = 1
            default: phaseText = phase
            }
            return
        }

        if trimmed.hasPrefix("ERR ") {
            phaseText = "失败：\(trimmed.dropFirst(4))"
            return
        }

        phaseText = trimmed
    }

    private func run() {
        busy = true
        output = ""
        NanoMuseCodexSettings.save(apiKey: apiKey, baseURL: baseURL, model: model)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                NanoMuseCodex.execute(
                    prompt: prompt,
                    workspace: "/root/work",
                    apiKey: apiKey,
                    baseURL: baseURL,
                    model: model,
                    timeout: 900
                )
            }.value
            output = result.output.isEmpty ? result.errorOutput : result.output
            busy = false
            await refresh()
        }
    }
}

// MARK: - 设置页入口卡片（与「模型」卡片同写法）

extension NanoMuseSettingsHomeView {
    var codexCard: some View {
        NanoMuseCard {
            NavigationLink {
                NanoMuseCodexView()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("本地 AI 编码器 · 自主改代码")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text("打开")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(NanoMuseTones.action)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
