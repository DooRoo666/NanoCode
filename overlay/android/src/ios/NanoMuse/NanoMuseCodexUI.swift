import SwiftUI

/// 设置 › Codex —— 用 nanoMuse 自己的设计系统写，不另造一套：
/// `NanoMusePage` 画布 + `NanoMuseCard` 卡片 + `NanoMuseRowLabel/ActionRow` 行
/// + `NanoMuseCaption` 说明 + `NanoMuseTones` 取色，与「模型」「设备」等页一致。
struct NanoMuseCodexView: View {

    @State private var status: NanoMuseCodex.Status?
    @State private var busy = false
    @State private var output = ""
    @State private var prompt = ""

    @State private var apiKey = NanoMuseCodexSettings.current.apiKey
    @State private var baseURL = NanoMuseCodexSettings.current.baseURL
    @State private var model = NanoMuseCodexSettings.current.model

    private var statusText: String {
        guard let status else { return "检测中…" }
        return status.installed ? "已安装 \(status.version ?? "")" : "未安装"
    }

    private var statusTint: Color {
        guard let status else { return .secondary }
        return status.installed ? NanoMuseTones.action : .secondary
    }

    var body: some View {
        NanoMusePage(title: "Codex") {
            installCard
            NanoMuseCaption(text: "在手机本地的 Alpine（aarch64）里安装官方 codex 二进制，约 100 MB。装好后 Agent 就能用 codex_exec 工具自主改代码。")

            credentialsCard
            NanoMuseCaption(text: "留空则沿用 Codex 自己的配置（环境变量或 ~/.codex/config.toml）。")

            runCard
            if !output.isEmpty {
                outputCard
            }
        }
        .task { await refresh() }
    }

    // MARK: - 安装

    private var installCard: some View {
        NanoMuseCard {
            NanoMuseRowLabel(title: "状态", value: statusText, titleColor: .primary, chevron: false)
            NanoMuseRowDivider()
            NanoMuseActionRow(title: busy ? "正在安装…" : "安装 / 更新 Codex",
                              value: nil,
                              chevron: false) {
                guard !busy else { return }
                install(force: false)
            }
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
                .frame(width: 92, alignment: .leading)
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

    private func install(force: Bool) {
        busy = true
        Task {
            let installed = await Task.detached(priority: .userInitiated) {
                NanoMuseCodex.install(force: force)
            }.value
            status = installed
            if !installed.installed {
                output = installed.rawOutput
            }
            busy = false
        }
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

// MARK: - 设置页上的入口卡片（与「模型」卡片同写法）

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
