import SwiftUI
import UIKit

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
    @State private var copied = false
    @State private var tipaPath = ""
    @State private var output = ""
    @State private var prompt = ""
    @State private var storageItems: [NanoMuseStorage.Item] = []
    @State private var cleaningStorage = false
    @State private var effort = NanoMuseCodexSettings.reasoningEffort

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
    @StateObject private var nativeLog = NanoMuseNativeRuntime.Log()
    @State private var nativeRunning = false
    @State private var useFallbackPrompt = NanoMuseCodexSettings.useFallbackPrompt
    @State private var fetchingModels = false
    @State private var modelError: String?
    @State private var wireAPI = NanoMuseCodexSettings.wireAPI

    private var busy: Bool { runningTool != nil }

    private var codexStatusText: String {
        guard let codexStatus else { return "检测中…" }
        return codexStatus.headline
    }

    private var codexInstallText: String {
        guard let codexStatus else { return "—" }
        return codexStatus.installLine
    }

    private var codexRouteText: String {
        guard let codexStatus else { return "—" }
        guard let route = codexStatus.activeRoute else { return "未就绪" }
        if let v = codexStatus.version, !v.isEmpty { return route + " · " + v }
        return route
    }

    var body: some View {
        NanoMusePage(title: "Codex") {
            // ① 先配置：模型来源 → 凭据 → 模型
            sourceCard
            NanoMuseCaption(text: "「使用 nanoMuse 的模型服务」直接借用「设置 › 模型」里已配好的地址与密钥；「自己设置第三方」单独填一套，互不影响。")

            if source == .custom {
                customCredentialCard
            }

            modelCard
            NanoMuseCaption(text: "模型列表来自该地址的 /v1/models；拉不到时自动用随包 models.json 兜底，也可以手动输入模型名。")

            // ② 再安装：状态 → 回显 → 工具 → 原生工具 → 资源 → 更多
            statusCard
            NanoMuseCaption(text: "Codex 面板 \(NanoMuseCodex.buildTag) · 执行优先走 iSH（宿主 fork() 被 iOS 禁用，宿主 codex 的 shell 不可能工作）；状态只报实际装上的那条路线。")
            logCard
            NanoMuseCaption(text: "推荐在「运行时」里用原生方式安装 codex（原版 iphoneos-arm64 包，跑在 iOS 上）；这里的 Alpine 方式适合纯 Linux 工具。")

            toolsCard
            NanoMuseCaption(text: "每项可单独安装；已装的可点右侧垃圾桶删除。回显区会逐步打印命令、下载字节数、SHA256、版本信息。")

            storageCard
            NanoMuseCaption(text: "统计的是本 App 容器内的运行时、工具链、缓存与下载残留；不会动其他 App 的数据。")

            signingCard
            NanoMuseCaption(text: "codex-sign 给 Mach-O 产物签权限，ca-filetool 是多调用工具集（cat/ls/grep/tar），bash.real 是真正的 bash——三者都是 iOS 原生，不在 Alpine 里。")

            assetsCard
            NanoMuseCaption(text: "原版随包资源：Mermaid 本地渲染、cacert.pem 信任根、models.json 离线模型表、20.9 KB 兜底提示词、entitlements.plist 签名模板与第三方声明。")

            advancedCard
            extraCard

            // ③ 试跑
            runCard
            if !output.isEmpty { outputCard }
        }
        .task {
            await refreshAll()
            await refreshStorage()
            refreshInherited()
        }
        .sheet(isPresented: $showMermaid) {
            NanoMuseMermaidPreviewPage()
        }
    }

    // MARK: - 状态 / 进度

    private var statusCard: some View {
        NanoMuseCard {
            NanoMuseRowLabel(title: "状态", value: codexStatusText, titleColor: .primary, chevron: false)
            NanoMuseRowDivider()
            NanoMuseRowLabel(title: "已安装", value: codexInstallText, titleColor: .secondary, chevron: false)
            NanoMuseRowDivider()
            NanoMuseRowLabel(title: "调用", value: codexRouteText, titleColor: .secondary, chevron: false)

            if runningTool == "codex" || nativeRunning {
                NanoMuseRowDivider()
                progressBlock
            }

            NanoMuseRowDivider()
            NanoMuseActionRow(title: busy || nativeRunning ? "安装中…" : "原生安装（推荐）", chevron: false) {
                guard !busy, !nativeRunning else { return }
                installNativeCodex()
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: busy || nativeRunning ? "安装中…" : "Alpine 安装（Linux ELF）", chevron: false) {
                guard !busy, !nativeRunning else { return }
                if let spec = NanoMuseTools.catalog.first(where: { $0.id == "codex" }) {
                    install(spec)
                }
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "重新检测", chevron: false) {
                guard !busy, !nativeRunning else { return }
                codexStatus = nil
                Task { await refreshAll() }
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "诊断与维护", chevron: true) {
                guard !busy, !nativeRunning else { return }
                diagnose()
            }
        }
    }

    /// 高级维护：只保留真正会用到的几项
    private var advancedCard: some View {
        NanoMuseCard {
            NanoMuseActionRow(title: "persona 探测（不下载）", chevron: true) {
                guard !busy, !nativeRunning else { return }
                logLines.removeAll()
                append("===== persona 探测 =====")
                for line in NanoMusePersonaProbe.report() { append(line) }
                NanoMusePersona.probeAndWrite()
                append(NanoMusePersona.tryInProcessSetuid())
                for line in NanoMusePersona.bundleWriteTest() { append(line) }
                append("结果已写入 Documents/persona-diag.txt")
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "Theos 工具链", chevron: true) {
                guard !busy, !nativeRunning else { return }
                logLines.removeAll()
                nativeLog.clear()
                append("===== Theos 工具链 =====")
                Task {
                    append("运行时目录：\(NanoMuseTheosRuntime.installRoot)")
                    _ = await NanoMuseTheosRuntime.prepareAll { line in append(line) }
                    for line in NanoMusePersonaProbe.report() { append(line) }
                    append("--- persona root 探测（写 Documents/persona-diag.txt）---")
                    NanoMusePersona.probeAndWrite()
                    append(NanoMusePersona.tryInProcessSetuid())
                    for line in NanoMusePersona.bundleWriteTest() { append(line) }
                }
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "路由与密钥", chevron: true) {
                guard !busy, !nativeRunning else { return }
                checkProviders()
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "进程阶梯测试", chevron: true) {
                guard !busy, !nativeRunning else { return }
                logLines.removeAll()
                nativeLog.clear()
                append("===== 进程阶梯测试 =====")
                Task {
                    let report = await NanoMuseCodex.processLadder()
                    for line in report.split(separator: "\n") { append(String(line)) }
                }
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "协议：\(wireAPI == "responses" ? "responses" : "chat")", chevron: true) {
                let next = wireAPI == "responses" ? "chat" : "responses"
                wireAPI = next
                NanoMuseCodexSettings.wireAPI = next
                append("wire_api 已切换为 \(next)")
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "权限对照（原生 vs iSH）", chevron: true) {
                guard !busy, !nativeRunning else { return }
                probePermissions()
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "打包成 tipa", chevron: true) {
                guard !busy, !nativeRunning else { return }
                logLines.removeAll()
                nativeLog.clear()
                append("===== 本地打包 tipa =====")
                let raw = tipaPath.trimmingCharacters(in: .whitespacesAndNewlines)
                let path = raw.isEmpty ? Bundle.main.bundlePath : raw
                Task {
                    let report = await Task.detached(priority: .userInitiated) {
                        await NanoMuseTipaBuilder.build(appPath: path)
                    }.value
                    for line in report.lines { append(line) }
                }
            }
        }
    }

    private var progressBlock: some View {
        let shown: Double? = nativeRunning ? nativeLog.progress : progress
        let text: String = nativeRunning
            ? (nativeLog.phase.isEmpty ? "准备中…" : nativeLog.phase)
            : (phaseText.isEmpty ? "准备中…" : phaseText)
        return VStack(alignment: .leading, spacing: 8) {
            if let shown {
                ProgressView(value: min(max(shown, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(NanoMuseTones.action)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(NanoMuseTones.action)
            }
            Text(text)
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
                HStack(spacing: 14) {
                    // 已装才显示删除；删除后清掉状态，下次重新探测
                    if installed != nil {
                        Button {
                            removeTool(spec)
                        } label: {
                            Image(systemName: "trash")
                                .font(.subheadline)
                                .foregroundStyle(busy ? Color.secondary : .red)
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: - 存储管理

    @ViewBuilder
    private var storageCard: some View {
        NanoMuseCard {
            ForEach(Array(storageItems.enumerated()), id: \.element.id) { index, item in
                if index > 0 { NanoMuseRowDivider() }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.body)
                        Text(item.detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(item.sizeText)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        removeStorageItem(item)
                    } label: {
                        Image(systemName: "trash").font(.subheadline).foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if !storageItems.isEmpty {
                NanoMuseRowDivider()
                HStack {
                    Text("合计")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(NanoMuseStorage.format(storageItems.reduce(0) { $0 + $1.bytes }))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            NanoMuseRowDivider()
            NanoMuseActionRow(title: cleaningStorage ? "清理中…" : "安全清理缓存", chevron: false) {
                guard !cleaningStorage else { return }
                clearStorageCaches()
            }
            NanoMuseRowDivider()
            NanoMuseActionRow(title: "重新检测", chevron: false) {
                Task { await refreshStorage() }
            }
        }
    }

    private func refreshStorage() async {
        let items = await Task.detached(priority: .utility) {
            await NanoMuseStorage.items()
        }.value
        storageItems = items
    }

    private func removeStorageItem(_ item: NanoMuseStorage.Item) {
        logLines.removeAll()
        Task {
            append("===== 删除 \(item.title)（\(item.sizeText)）=====")
            let ok = await Task.detached(priority: .userInitiated) {
                NanoMuseStorage.remove(item)
            }.value
            append(ok ? "已删除" : "部分文件删除失败（可能被占用）")
            await refreshStorage()
            await refreshAll()
        }
    }

    private func clearStorageCaches() {
        cleaningStorage = true
        logLines.removeAll()
        Task {
            let freed = await Task.detached(priority: .userInitiated) {
                NanoMuseStorage.clearCaches()
            }.value
            append("===== 清理缓存 =====")
            append("释放 \(NanoMuseStorage.format(freed))")
            cleaningStorage = false
            await refreshStorage()
        }
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
            NanoMuseRowDivider()
            NanoMuseToggleRow(title: "拼接兜底提示词",
                              subtitle: "把随包的 codex-fallback-prompt.md（20.9 KB）拼到任务前",
                              isOn: Binding(
                                get: { useFallbackPrompt },
                                set: { newValue in
                                    useFallbackPrompt = newValue
                                    NanoMuseCodexSettings.useFallbackPrompt = newValue
                                }
                              ))
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
                if !displayLines.isEmpty {
                    Button {
                        UIPasteboard.general.string = displayLines.joined(separator: "\n")
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                    } label: {
                        Text(copied ? "已复制" : "复制")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(copied ? Color.secondary : NanoMuseTones.action)
                    }
                    .buttonStyle(.plain)

                    Button {
                        nativeLog.clear()
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
                        if displayLines.isEmpty {
                            Text("还没有输出。点上面任一「安装」后，这里会逐行显示。")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
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
                .onChange(of: displayLines.count) { _ in
                    if let last = displayLines.indices.last {
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
                .frame(width: 72, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 6) {
                Text("思考强度")
                    .font(.body)
                Text("作为子代理时：简单任务用 minimal/low 更快，复杂重构才要 high")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { NanoMuseCodexSettings.reasoningEffort },
                    set: { NanoMuseCodexSettings.reasoningEffort = $0; effort = $0 }
                )) {
                    ForEach(NanoMuseCodexSettings.reasoningEfforts, id: \.self) { e in
                        Text(e).tag(e)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

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

    private var displayLines: [String] {
        nativeRunning || !nativeLog.lines.isEmpty ? nativeLog.lines + logLines : logLines
    }

    /// 原生安装：从清单取 codex 包（iphoneos-arm64.deb），解到 App 容器
    private func installNativeCodex() {
        nativeRunning = true
        nativeLog.clear()
        logLines.removeAll()
        Task {
            do {
                let manifest = try await NanoMuseRuntimeManifest.fetch()
                guard let package = manifest.packages.first(where: { $0.id == "codex" }) else {
                    await MainActor.run {
                        nativeLog.add("ERR 清单里没有 codex 包")
                        nativeRunning = false
                    }
                    return
                }
                let ok = await NanoMuseNativeRuntime.install(package,
                                                             proxies: manifest.proxies,
                                                             log: nativeLog)
                if !ok { await MainActor.run { nativeLog.add("ERR 原生安装未完成") } }
            } catch {
                await MainActor.run { nativeLog.add("ERR 清单拉取失败：\(error.localizedDescription)") }
            }
            await MainActor.run { nativeRunning = false }
            await refreshAll()
        }
    }

    /// 权限对照：分别用原生 bash 与 iSH 跑同一组探针
    private func probePermissions() {
        logLines.removeAll()
        nativeLog.clear()
        append("===== ① 原生进程（Minis posix_spawn）=====")
        let nativeResult = NanoMuseHelperRunner.run("bash.real",
                                                    arguments: ["-lc", NanoMuseCodex.nativePermissionScript],
                                                    timeout: 60)
        for line in nativeResult.output.split(separator: "\n") { append(String(line)) }
        append("")
        append("===== ② iSH 内的 Linux 进程 =====")
        NanoMuseCodex.runStreaming(NanoMuseCodex.alpinePermissionScript) { line in
            append(line)
        } onFinish: { _ in }
    }

    /// 自检：把路径/大小/ELF 头/版本/PATH 全打出来
    private func diagnose() {
        logLines.removeAll()
        nativeLog.clear()
        NanoMuseCodex.runStreaming(NanoMuseCodex.diagnoseScript) { line in
            append(line)
        } onFinish: { _ in
            Task { await refreshAll() }
        }
    }

    /// 路由与密钥：逐个实测 nanoMuse 的 provider，只报「有没有 key / 通不通」，不打印 key
    private func checkProviders() {
        logLines.removeAll()
        nativeLog.clear()
        append("===== 读取 nanoMuse 的模型设置 =====")
        Task {
            let lines = await NanoMuseCodexSettings.diagnoseProviders()
            for line in lines { append(line) }
            append("（key 只留在 App 进程内，不会落到任何外部进程或配置文件）")
        }
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
        let mode = source
        Task {
            do {
                // 跟随 nano 时用上游的模型目录；自填第三方时才直连 /v1/models
                let list: [String]
                if mode == .followNano {
                    list = try await NanoMuseCodexModels.fetchInheritedModels()
                } else {
                    list = try await NanoMuseCodexModels.fetchModels(baseURL: credential.baseURL,
                                                                     apiKey: credential.apiKey)
                }
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

    /// 删除一个工具：运行时用 NativeRuntime 卸载，Alpine 包用 apk del
    private func removeTool(_ spec: NanoMuseToolSpec) {
        logLines.removeAll()
        Task {
            runningTool = spec.id
            defer { runningTool = nil }
            append("===== 卸载 \(spec.title) =====")

            if NanoMuseNativeRuntime.isInstalled(spec.id) {
                let ok = NanoMuseNativeRuntime.uninstall(spec.id)
                append(ok ? "已删除运行时目录" : "删除失败（目录可能被占用）")
            } else {
                // 实测坑：iSH 里 /lib/apk/db/lock 一旦变陈旧，任何 apk 写操作都会返回
                // "Unable to lock database: Operation not permitted"（连 root 也一样）。
                // 这里先正常跑，命中锁错误就删掉陈旧锁文件再重试一次。
                let script = """
                apk del \(spec.id) 2>&1 | tail -5
                if [ -f /lib/apk/db/lock ]; then
                  if ! apk info "\(spec.id)" >/dev/null 2>&1; then :; fi
                fi
                echo STEP done
                """
                let (code, out) = await NanoMuseCodex.runCommand(script, timeout: 180)
                var lines = out.split(separator: "\n").map(String.init)
                if lines.contains(where: { $0.contains("Unable to lock database") }) {
                    append("检测到 apk 数据库锁陈旧，删除后重试…")
                    let retry = """
                    rm -f /lib/apk/db/lock
                    apk del \(spec.id) 2>&1 | tail -5
                    echo STEP done
                    """
                    let (code2, out2) = await NanoMuseCodex.runCommand(retry, timeout: 180)
                    lines = out2.split(separator: "\n").map(String.init)
                    for line in lines { append(line) }
                    append("apk del 退出码 = \(code2)（已清锁重试）")
                } else {
                    for line in lines { append(line) }
                    append("apk del 退出码 = \(code)")
                }
            }

            toolStatus[spec.id] = nil
            await refreshAll()
        }
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
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        // codex 启动时会尝试在 HOME 下建 PATH 别名；容器权限偶尔拒绝，rc 仍是 0。
        // 原样打印容易被当成「安装失败」，改写成一句人话。
        if line.contains("PATH aliases") {
            line = "提示：codex 未能创建 PATH 别名（无害，不影响运行）"
        }

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
        Task {
            let resolved = await NanoMuseCodexSettings.resolvedAsync()
            let model = resolved.model.isEmpty ? selectedModel : resolved.model
            let result = await Task.detached(priority: .userInitiated) {
                await NanoMuseCodex.execute(
                    prompt: prompt,
                    workspace: "/root/work",
                    apiKey: resolved.apiKey,
                    baseURL: resolved.baseURL,
                    model: model,
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
                    Image(systemName: "terminal")
                        .font(.body)
                        .foregroundStyle(NanoMuseTones.action)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("子代理 · 工具、模型与运行")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
