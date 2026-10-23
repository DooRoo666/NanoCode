import SwiftUI

/// 设置 › Codex：装、配、跑，一页搞定。
/// 挂在 `NanoMuseSettingsHomeView` 的卡片里（见文件末尾的 extension）。
struct NanoMuseCodexView: View {

    @State private var status: NanoMuseCodex.Status?
    @State private var busy = false
    @State private var output = ""
    @State private var prompt = ""

    @State private var apiKey = NanoMuseCodexSettings.current.apiKey
    @State private var baseURL = NanoMuseCodexSettings.current.baseURL
    @State private var model = NanoMuseCodexSettings.current.model

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("状态")
                    Spacer()
                    if let status {
                        Text(status.installed ? "已安装 \(status.version ?? "")" : "未安装")
                            .foregroundStyle(status.installed ? .green : .secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let status, !status.installed, !status.rawOutput.isEmpty {
                    Text(status.rawOutput)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Button {
                    install(force: false)
                } label: {
                    if busy { ProgressView() } else { Text("安装 / 更新 Codex") }
                }
                .disabled(busy)
            } header: {
                Text("Codex")
            } footer: {
                Text("在手机本地的 Alpine（aarch64）里安装官方 codex 二进制，约 100 MB。安装后 Agent 就能用 codex_exec 工具。")
            }

            Section {
                TextField("Base URL（可选，如 https://api.openai.com/v1）", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("模型（可选，如 gpt-5-codex）", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("保存") {
                    NanoMuseCodexSettings.save(apiKey: apiKey, baseURL: baseURL, model: model)
                    output = "已保存。"
                }
            } header: {
                Text("凭据")
            } footer: {
                Text("留空则使用 Codex 自己的默认配置（环境变量或 ~/.codex/config.toml）。")
            }

            Section {
                TextEditor(text: $prompt)
                    .frame(minHeight: 80)
                    .font(.body.monospaced())
                Button {
                    run()
                } label: {
                    if busy { ProgressView() } else { Text("运行 Codex") }
                }
                .disabled(busy || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("试跑")
            }

            if !output.isEmpty {
                Section("输出") {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Codex")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
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

// MARK: - 设置页上的入口卡片

extension NanoMuseSettingsHomeView {
    var codexCard: some View {
        NanoMuseCard {
            NavigationLink {
                NanoMuseCodexView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("本地 AI 编码器 · 在终端里自主改代码")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
