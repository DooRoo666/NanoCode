import SwiftUI

/// 设置 › Codex —— 与 nanoMuse 其它设置页同一套观感：
/// `NanoMusePage` 画布 + `NanoMuseCard` 卡片 + `NanoMuseRowLabel`/`NanoMuseActionRow` 行
/// + `NanoMuseCaption` 说明 + `NanoMuseTones` 取色。
///
/// 内容顺序：状态与安装 → 工具清单 → 安装回显 → 模型来源（两种）→ 凭据 → 模型列表 → 试跑。
struct NanoMuseCodexView: View {

    @State private var codexStatus: NanoMuseCodex.Status?
    @State private var toolStatus: [String: String] = [:]
    @State private var runningTool: String?
    @State private var phaseText = ""
    @State private var progress: Double?
    @State private var logLines: [String] = []
    @State private var output = ""
    @State private var prompt = ""

    // 模型来源
    @State private var source: NanoMuseCodexSource = NanoMuseCodexSettings.current.source
    @State private var apiKey = NanoMuseCodexSettings.current.apiKey
    @State private var baseURL = NanoMuseCodexSettings.current.baseURL
    @State private var selectedModel = NanoMuseCodexSettings.current.model
    @State private var inheritedLabel: String?
    @State private var inheritedBase: String?

    // 在线模型
    @State private var models: [String] = []
    @State private var showMermaid = false
    @State private var fetchingModels = false
    @State private var modelError: String?

    private var busy: Bool { runningTool != nil }

    private var codexStatusText: String {
        guard let codexStatus else { return "检测中…" }
        return codexStatus.installed ? "已安装 \(codexStatus.version ?? "")" : "未安装"
    }

    var body: some View {
        NanoMusePage(title: "Codex") {
            statusCard
            NanoMuseCaption(text: "在手机本地的 Alpine（aarch64）里安装官方 codex 二进制。装好后 Agent 就能用 codex_exec 工具自主改代码。")

            toolsCard
            NanoMuseCaption(text: "每项可单独下载；点「安装」后下面的回显区会逐步打印命令、下载字节数、SHA256、ELF 头与版本。")

            signingCard
            NanoMuseCaption(text: "这三个是 MT-Agent 随包带的原生工具（Mach-O，跑在 iOS 上，不在 Alpine 里）：codex-sign 给编译产物签权限，ca-filetool 是多调用工具集，bash.real 是真正的 bash。")

            assetsCard
            extraCard
            NanoMuseCaption(text: "这些是原版随包的资源：Mermaid 本地渲染、cacert.pem 信任根、models.json 离线模型表、20.9 KB 兜底提示词、entitlements.plist 签名模板与第三方声明。")

            logCard

            sourceCard
            NanoMuseCaption(text: "「使用 nanoMuse 的模型服务」= 直接借用你在「设置 › 模型」里配好的地址与密钥；「自己设置第三方」= 单独填一套，互不影响。")

            if source == .custom {
                customCredentialCard
            }

            modelCard
            NanoMuseCaption(text: "模型列表来自该地址的 /v1/models；也可以手动输入模型名。")

            runCard
            if !output.isEmpty { outputCard }
        }
        .task {
            await refreshAll()
            refreshInherited()
        }
        .sheet(isPresented: $showMermaid) {
            NanoMuseMermaidPreviewPage()
        }
    }

    // MARK: - 状态 / 进度

    private var statusCard: some View {
        NanoMuseCard {
            NanoMuseRowLabel(title: "Codex", value: codexStatusText, titleColor: .primary, chevron: false)

            if runningTool == "codex" {
                NanoMuseRowDivider()
                progressBlock
            }

            NanoMuseRowDivider()
            NanoMuseActionRow(title: busy ? "安装中…" : "安装 / 更新 Codex", chevron: false) {
                guard !busy else { return }
                if let spec = NanoMuseTools.catalog.first(where: { $0.id == "codex" }) {
                    install(spec)
                }
            }
        }
    }

    private var progressBlock: some View {
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

    // MARK: - 工具清单

    private var toolsCard: some View {
        NanoMuseCard {
            ForEach(Array(NanoMuseTools.catalog.enumerated()), id: \.element.id) { index, spec in
                if index > 0 { NanoMuseRowDivider() }
                toolRow(spec)
            }
        }
    }

    private func toolRow(_ spec: NanoMuseToolSpec) -> some View {
        let installed = toolStatus[spec.id]
        let isRunning = runningTool == spec.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(installed ?? "\(spec.subtitle) · \(spec.sizeHint)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    install(spec)
                } label: {
                    Text(installed == nil ? "安装" : "重装")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(busy ? Color.secondary : NanoMuseTones.action)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - 签名与构建工具（随包的 Mach-O Helpers）

    private var signingCard: some View {
        NanoMuseCard {
            ForEach(Array(["codex-sign", "ca-filetool", "bash.real"].enumerated()), id: \.element) { index, name in
                if index > 0 { NanoMuseRowDivider() }
                NanoMuseRowLabel(title: name,
                                 value: NanoMuseHelperRunner.exists(name) ? "已随包" : "缺失",
                                 titleColor: .primary, chevron: false)
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: busy ? "忙…" : "测试 codex-sign", chevron: false) {
                guard !busy else { return }
                testSigner()
            }
            if let theos = NanoMuseTools.catalog.first(where: { $0.id == "theos" }) {
                NanoMuseRowDivider()
                NanoMuseActionRow(title: busy ? "忙…" : (toolStatus["theos"] ?? "安装 Theos（Alpine）"),
                                  chevron: false) {
                    guard !busy else { return }
                    install(theos)
                }
            }
        }
    }

    private func testSigner() {
        runningTool = "codex-sign"
        logLines.removeAll()
        phaseText = "运行 codex-sign…"
        progress = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run("codex-sign", arguments: ["--help"], timeout: 20)
            }.value
            append(String(format: "[codex-sign] exit=%d 用时 %.2fs", result.exitCode, result.duration))
            for line in result.output.split(separator: "\n").prefix(60) {
                append(String(line))
            }
            phaseText = "codex-sign 退出码 \(result.exitCode)"
            runningTool = nil
        }
    }

    // MARK: - 随包资源（对齐 MT-Agent）

    private var assetsCard: some View {
        NanoMuseCard {
            ForEach(Array(NanoMuseCodexAssets.inventory().enumerated()), id: \.element.name) { index, item in
                if index > 0 { NanoMuseRowDivider() }
                NanoMuseRowLabel(title: item.name,
                                 value: item.present ? "已随包" : "缺失",
                                 titleColor: .primary, chevron: false)
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "Mermaid 渲染预览", chevron: false) {
                showMermaid = true
            }
            if let hint = NanoMuseCodexAssets.codexVersionHint() {
                NanoMuseRowDivider()
                NanoMuseRowLabel(title: "原版 codex 版本参照", value: hint, titleColor: .primary, chevron: false)
            }
        }
    }

    // MARK: - 完整回显

    private var logCard: some View {
        NanoMuseCard {
            HStack {
                Text("安装回显")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !logLines.isEmpty {
                    Button {
                        logLines.removeAll()
                    } label: {
                        Text("清空")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(NanoMuseTones.action)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if logLines.isEmpty {
                            Text("还没有输出。点上面任一「安装」后，这里会逐行显示。")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(color(for: line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .frame(minHeight: 140, maxHeight: 260)
                .background(NanoMuseTones.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .onChange(of: logLines.count) { _ in
                    if let last = logLines.indices.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("ERR ") { return .red }
        if line.hasPrefix("STEP ") { return .primary }
        return .secondary
    }

    // MARK: - 模型来源（两种选择）

    private var sourceCard: some View {
        NanoMuseCard {
            ForEach(Array(NanoMuseCodexSource.allCases.enumerated()), id: \.element.id) { index, option in
                if index > 0 { NanoMuseRowDivider() }
                Button {
                    source = option
                    persist()
                    refreshInherited()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(option.subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if source == option {
                            Image(systemName: "checkmark")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(NanoMuseTones.action)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if source == .followNano {
                NanoMuseRowDivider()
                NanoMuseRowLabel(title: "取自",
                                 value: inheritedLabel ?? "尚未配置 provider",
                                 titleColor: .primary, chevron: false)
                if let inheritedBase, !inheritedBase.isEmpty {
                    NanoMuseRowDivider()
                    NanoMuseRowLabel(title: "地址", value: inheritedBase, titleColor: .primary, chevron: false)
                }
            }
        }
    }

    private var customCredentialCard: some View {
        NanoMuseCard {
            field("Base URL", placeholder: "https://api.openai.com/v1", text: $baseURL, secure: false)
            NanoMuseRowDivider()
            field("API Key", placeholder: "sk-…", text: $apiKey, secure: true)
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "保存", chevron: false) {
                persist()
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

    // MARK: - 在线模型

    private var modelCard: some View {
        NanoMuseCard {
            NanoMuseRowLabel(title: "当前模型",
                             value: selectedModel.isEmpty ? "未选择" : selectedModel,
                             titleColor: .primary, chevron: false)

            NanoMuseRowDivider()
            HStack {
                Button {
                    fetchModels()
                } label: {
                    HStack(spacing: 6) {
                        if fetchingModels {
                            ProgressView().controlSize(.small)
                        }
                        Text(fetchingModels ? "获取中…" : "在线获取模型")
                            .font(.body)
                            .foregroundStyle(NanoMuseTones.action)
                    }
                }
                .buttonStyle(.plain)
                .disabled(fetchingModels)
                Spacer()
                if !models.isEmpty {
                    Text("\(models.count) 个")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if let modelError {
                Text(modelError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if !models.isEmpty {
                NanoMuseRowDivider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(models, id: \.self) { name in
                            Button {
                                selectedModel = name
                                persist()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(name)
                                        .font(.subheadline.monospaced())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    if selectedModel == name {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(NanoMuseTones.action)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 220)
            }

            NanoMuseRowDivider()
            field("手动输入", placeholder: "例如 gpt-5-codex", text: $selectedModel, secure: false)
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "保存模型", chevron: false) {
                persist()
                output = "模型已保存：\(selectedModel)"
            }
        }
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
            NanoMuseActionRow(title: busy ? "忙…" : "运行 Codex", chevron: false) {
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

    private func persist() {
        NanoMuseCodexSettings.save(source: source, apiKey: apiKey, baseURL: baseURL, model: selectedModel)
    }

    private func refreshInherited() {
        let inherited = NanoMuseCodexModels.inherited()
        inheritedLabel = inherited?.label
        inheritedBase = inherited?.baseURL
    }

    private func fetchModels() {
        modelError = nil
        fetchingModels = true
        let credential = NanoMuseCodexSettings.resolved()
        Task {
            do {
                let list = try await NanoMuseCodexModels.fetchModels(baseURL: credential.baseURL,
                                                                     apiKey: credential.apiKey)
                models = list
                if selectedModel.isEmpty, let first = list.first {
                    selectedModel = first
                    persist()
                }
            } catch {
                let fallback = NanoMuseCodexAssets.bundledModels()
                if !fallback.isEmpty {
                    models = fallback
                    modelError = "在线获取失败（\(error.localizedDescription)），已用随包 models.json 的 \(fallback.count) 个模型兜底。"
                } else {
                    modelError = error.localizedDescription
                }
            }
            fetchingModels = false
        }
    }

    private func refreshAll() async {
        let codex = await Task.detached(priority: .userInitiated) { await NanoMuseCodex.status() }.value
        codexStatus = codex

        let specs = NanoMuseTools.catalog
        let statuses = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            var result: [String: String] = [:]
            for spec in specs {
                if let value = await NanoMuseTools.status(of: spec) { result[spec.id] = value }
            }
            return result
        }.value
        toolStatus = statuses
    }

    private func install(_ spec: NanoMuseToolSpec) {
        runningTool = spec.id
        progress = 0
        phaseText = "准备中…"
        logLines.removeAll()

        NanoMuseCodex.runStreaming(spec.installScript) { line in
            append(line)
        } onFinish: { ok in
            if !ok { append("ERR 安装未完成（退出码非 0）") }
            runningTool = nil
            Task { await refreshAll() }
        }
    }

    /// 逐行回显：`STEP`/`BYTES`/`ERR` 解析成进度，其余原样收下。
    private func append(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if line.hasPrefix("BYTES ") {
            let parts = line.split(separator: " ")
            if parts.count >= 3, let done = Double(parts[1]), let total = Double(parts[2]), total > 0 {
                progress = done / total
                phaseText = String(format: "下载中 %.0f%% · %.1f / %.1f MB",
                                   (done / total) * 100, done / 1048576, total / 1048576)
            } else if parts.count >= 2, let done = Double(parts[1]) {
                phaseText = String(format: "下载中 · %.1f MB", done / 1048576)
            }
        } else if line.hasPrefix("STEP ") {
            phaseText = String(line.dropFirst(5))
            let lowered = line.lowercased()
            if lowered.contains("1/7") { progress = 0.02 }
            if lowered.contains("3/7") { progress = 0.05 }
            if lowered.contains("4/7") { progress = 0.08 }
            if lowered.contains("5/7") { progress = 0.86 }
            if lowered.contains("6/7") { progress = 0.92 }
            if lowered.contains("7/7") { progress = 0.98 }
            if lowered.hasSuffix("done") { progress = 1 }
        } else if line.hasPrefix("ERR ") {
            phaseText = line
        }

        logLines.append(line)
        if logLines.count > 500 {
            logLines.removeFirst(logLines.count - 500)
        }
    }

    private func run() {
        output = ""
        persist()
        let credential = NanoMuseCodexSettings.resolved()
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                await NanoMuseCodex.execute(
                    prompt: prompt,
                    workspace: "/root/work",
                    apiKey: credential.apiKey,
                    baseURL: credential.baseURL,
                    model: selectedModel,
                    timeout: 900
                )
            }.value
            output = result.output.isEmpty ? result.errorOutput : result.output
            await refreshAll()
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
                        Text("本地 AI 编码器 · 工具、模型与安装")
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
