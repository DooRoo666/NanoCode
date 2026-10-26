import SwiftUI

// MARK: - Codex 页里的「更多」入口卡

extension NanoMuseCodexView {
    var extraCard: some View {
        NanoMuseCard {
            NavigationLink { NanoMuseRuntimePage() } label: {
                row(title: "运行时（原版清单）", subtitle: "codex · ollvm · node · python · 逆向工具")
            }
            .buttonStyle(.plain)
            NanoMuseRowDivider()
            NavigationLink { NanoMuseSubagentPage() } label: {
                row(title: "子代理", subtitle: "后台跑 Codex，完成后回投结果")
            }
            .buttonStyle(.plain)
            NanoMuseRowDivider()
            NavigationLink { NanoMuseWorktreePage() } label: {
                row(title: "工作树", subtitle: "为 Codex 建独立 git worktree")
            }
            .buttonStyle(.plain)
            NanoMuseRowDivider()
            NavigationLink { NanoMuseSignerPage() } label: {
                row(title: "签名工具", subtitle: "codex-sign：给 Mach-O 产物签权限")
            }
            .buttonStyle(.plain)
            NanoMuseRowDivider()
            NavigationLink { NanoMuseNativeShellPage() } label: {
                row(title: "原生 Shell", subtitle: "bash.real + ca-filetool（iOS 本机执行）")
            }
            .buttonStyle(.plain)
        }
    }

    private func row(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - 运行时（manifest）

struct NanoMuseRuntimePage: View {

    /// 安装目标有两种：原生（App 容器，Mach-O，推荐）与 Alpine（Linux ELF）。
    enum Mode: String, CaseIterable, Identifiable {
        case native, alpine
        var id: String { rawValue }
        var title: String { self == .native ? "原生（推荐）" : "Alpine" }
        var hint: String {
            switch self {
            case .native: return "解到 App 容器，Mach-O 由 posix_spawn 直接跑"
            case .alpine: return "解到 iSH 的 /opt/runtimes，适合纯 Linux 工具"
            }
        }
    }

    @State private var mode: Mode = .native
    @State private var packages: [NanoMuseRuntimeManifest.Package] = []
    @State private var proxies: [String] = []
    @State private var installed: [String: Bool] = [:]
    @State private var manifestError: String?
    @State private var runningID: String?
    @State private var logLines: [String] = []
    @StateObject private var nativeLog = NanoMuseNativeRuntime.Log()

    var body: some View {
        NanoMusePage(title: "运行时") {
            NanoMuseCard {
                Picker("安装目标", selection: $mode) {
                    ForEach(Mode.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Text(mode.hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)

                NanoMuseRowDivider()
                NanoMuseRowLabel(title: "清单", value: packages.isEmpty ? "未加载" : "\(packages.count) 个包",
                                 titleColor: .primary, chevron: false)
                NanoMuseRowDivider()
                NanoMuseRowLabel(title: "已安装",
                                 value: "\(installed.values.filter { $0 }.count) / \(packages.count)",
                                 titleColor: .primary, chevron: false)
                if mode == .native {
                    NanoMuseRowDivider()
                    NanoMuseRowLabel(title: "安装位置",
                                     value: NanoMuseNativeRuntime.rootDirectory.lastPathComponent,
                                     titleColor: .primary, chevron: false)
                }
                NanoMuseRowDivider()
                NanoMuseActionRow(title: "刷新清单", chevron: false) { Task { await load() } }
                if let manifestError {
                    Text(manifestError)
                        .font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
            NanoMuseCaption(text: "与 MT-Agent 同一份清单。原生包是 iOS 产物（codex 是 iphoneos-arm64.deb），装到 App 容器；Alpine 包才是 Linux 工具。")

            if !packages.isEmpty {
                NanoMuseCard {
                    ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                        if index > 0 { NanoMuseRowDivider() }
                        packageRow(package)
                    }
                }
            }

            let displayLines = mode == .native ? nativeLog.lines : logLines
            if !displayLines.isEmpty {
                NanoMuseCard {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(displayLines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(line.hasPrefix("ERR") ? .red : .secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                            .padding(12)
                        }
                        .frame(maxHeight: 240)
                        .onChange(of: displayLines.count) { _ in
                            if let last = displayLines.indices.last {
                                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func packageRow(_ package: NanoMuseRuntimeManifest.Package) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(package.displayName).font(.body).foregroundStyle(.primary)
                Text("\(package.group) · \(package.sizeText) · \(package.capabilities.prefix(2).joined(separator: ", "))")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if let ios = package.minimumIOS {
                    Text("最低 iOS \(ios)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            if runningID == package.id {
                ProgressView().controlSize(.small)
            } else if installed[package.id] == true {
                Menu {
                    Button("卸载", role: .destructive) {
                        Task {
                            NanoMuseNativeRuntime.uninstall(package.id)
                            await load()
                        }
                    }
                } label: {
                    Text("已安装").font(.footnote).foregroundStyle(NanoMuseTones.action)
                }
            } else {
                Button {
                    Task { await install(package) }
                } label: {
                    Text("安装").font(.subheadline.weight(.semibold)).foregroundStyle(NanoMuseTones.action)
                }
                .buttonStyle(.plain)
                .disabled(runningID != nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func load() async {
        manifestError = nil
        do {
            let manifest = try await NanoMuseRuntimeManifest.fetch()
            packages = manifest.packages
            proxies = manifest.proxies
            var state: [String: Bool] = [:]
            switch mode {
            case .native:
                for package in manifest.packages {
                    state[package.id] = NanoMuseNativeRuntime.isInstalled(package.id)
                }
            case .alpine:
                let script = NanoMuseRuntimeManifest.statusScript(manifest.packages.map(\.id))
                let (_, output) = await NanoMuseCodex.runCommand(script, timeout: 60)
                state = NanoMuseRuntimeManifest.parseStatus(output)
            }
            installed = state
        } catch {
            manifestError = error.localizedDescription
        }
    }

    private func install(_ package: NanoMuseRuntimeManifest.Package) async {
        runningID = package.id
        logLines.removeAll()

        switch mode {
        case .native:
            nativeLog.clear()
            let ok = await NanoMuseNativeRuntime.install(package, proxies: proxies, log: nativeLog)
            if !ok { await MainActor.run { nativeLog.add("ERR 安装未完成") } }
        case .alpine:
            let script = NanoMuseRuntimeManifest.installScript(package, proxies: proxies)
            _ = await NanoMuseCodex.runStreamingAwait(script, timeout: 3600)
            append("Alpine 安装流程结束")
        }

        runningID = nil
        await load()
    }

    private func append(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }
}

// MARK: - 子代理

struct NanoMuseSubagentPage: View {
    @ObservedObject private var center = NanoMuseSubagentCenter.shared
    @State private var showDispatch = false
    @State private var draftPrompt = ""
    @State private var draftWorkspace = "/root/work"

    var body: some View {
        NanoMusePage(title: "子代理") {
            NanoMuseCard {
                NanoMuseRowLabel(title: "作业数", value: "\(center.recent().count)", titleColor: .primary, chevron: false)
                NanoMuseRowDivider()
                NanoMuseActionRow(title: "手动派一个任务", chevron: false) { showDispatch = true }
                NanoMuseRowDivider()
                NanoMuseActionRow(title: "清除已结束", chevron: false) { center.clearFinished() }
            }
            NanoMuseCaption(text: "主 Agent 用 subagent_dispatch 把编码任务派给后台 Codex，subagent_result 取回结果；完成时发本地通知。也可以在这里手动派一个。")
            .sheet(isPresented: $showDispatch) { dispatchSheet }

            let jobs = center.recent()
            if jobs.isEmpty {
                NanoMuseCard {
                    NanoMuseRowLabel(title: "还没有作业", value: nil, titleColor: .primary, chevron: false)
                }
            } else {
                NanoMuseCard {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                        if index > 0 { NanoMuseRowDivider() }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("#\(job.id) · \(job.kind.rawValue)").font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                                Spacer()
                                Text(job.status == "running" ? "运行中" : (job.exitCode == 0 ? "成功" : "失败"))
                                    .font(.footnote)
                                    .foregroundStyle(job.status == "running" ? .secondary : (job.exitCode == 0 ? NanoMuseTones.action : .red))
                            }
                            Text(job.prompt).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            if !job.output.isEmpty {
                                Text(String(job.output.suffix(400)))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(6)
                            }
                            Text("\(job.durationText) · \(job.delivered ? "已回投" : "待取")")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }
    private var dispatchSheet: some View {
        NanoMusePage(title: "派发任务") {
            NanoMuseCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("任务").font(.body)
                    TextEditor(text: $draftPrompt)
                        .font(.body.monospaced())
                        .frame(minHeight: 96)
                        .scrollContentBackground(.hidden)
                        .background(NanoMuseTones.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topLeading) {
                            if draftPrompt.isEmpty {
                                Text("例如：把这个目录改成可运行的 Python CLI")
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .padding(.top, 8).padding(.leading, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                NanoMuseRowDivider()
                HStack(spacing: 12) {
                    Text("目录").font(.body).frame(width: 72, alignment: .leading)
                    TextField("/root/work", text: $draftWorkspace)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                NanoMuseRowDivider()
                NanoMuseActionRow(title: "派发到后台", chevron: false) {
                    let prompt = draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !prompt.isEmpty else { return }
                    center.dispatch(kind: .codex, prompt: prompt, workspace: draftWorkspace)
                    draftPrompt = ""
                    showDispatch = false
                }
            }
            NanoMuseCaption(text: "派发后立刻返回，任务在后台跑；完成时回到这个页面看输出。")
        }
    }
}

// MARK: - Git Worktree

struct NanoMuseWorktreePage: View {
    @State private var workspace = "/root/work"
    @State private var entries: [NanoMuseGitWorktree.Entry] = []
    @State private var newPath = ""
    @State private var newBranch = ""
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        NanoMusePage(title: "工作树") {
            NanoMuseCard {
                HStack(spacing: 12) {
                    Text("工作区").font(.body).frame(width: 72, alignment: .leading)
                    TextField("/root/work", text: $workspace)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                NanoMuseRowDivider()
                NanoMuseActionRow(title: busy ? "读取中…" : "刷新列表", chevron: false) { refresh() }
            }

            if !entries.isEmpty {
                NanoMuseCard {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { NanoMuseRowDivider() }
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.branch.isEmpty ? "（主工作树）" : entry.branch)
                                    .font(.body).foregroundStyle(.primary)
                                Text(entry.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if !entry.branch.isEmpty {
                                Button {
                                    remove(entry)
                                } label: {
                                    Text("删除").font(.footnote.weight(.semibold)).foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }
            }

            NanoMuseCard {
                HStack(spacing: 12) {
                    Text("新路径").font(.body).frame(width: 72, alignment: .leading)
                    TextField("/root/work-feature", text: $newPath)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                NanoMuseRowDivider()
                HStack(spacing: 12) {
                    Text("新分支").font(.body).frame(width: 72, alignment: .leading)
                    TextField("feature-x（可留空复用已有）", text: $newBranch)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                NanoMuseRowDivider()
                NanoMuseActionRow(title: busy ? "处理中…" : "创建工作树", chevron: false) { add() }
            }

            if !message.isEmpty {
                NanoMuseCard {
                    Text(message)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                }
            }
            NanoMuseCaption(text: "工作树让 Codex 在独立目录里改代码，主分支不受影响；删除只移除工作树，不删分支。")
        }
        .task { refresh() }
    }

    private func refresh() {
        busy = true
        let ws = workspace
        Task {
            let list = await Task.detached(priority: .userInitiated) { await NanoMuseGitWorktree.list(workspace: ws) }.value
            entries = list
            busy = false
            if list.isEmpty { message = "这里不是 git 仓库，或还没有工作树。" }
        }
    }

    private func add() {
        guard !newPath.isEmpty else { return }
        busy = true
        let ws = workspace, path = newPath, branch = newBranch
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                await NanoMuseGitWorktree.add(workspace: ws, path: path, branch: branch)
            }.value
            message = output
            busy = false
            refresh()
        }
    }

    private func remove(_ entry: NanoMuseGitWorktree.Entry) {
        busy = true
        let ws = workspace
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                await NanoMuseGitWorktree.remove(workspace: ws, path: entry.path)
            }.value
            message = output
            busy = false
            refresh()
        }
    }
}

// MARK: - 签名工具（codex-sign）

struct NanoMuseSignerPage: View {

    enum Mode: String, CaseIterable, Identifiable {
        case adhoc, entitled
        var id: String { rawValue }
        var title: String { self == .adhoc ? "ad-hoc" : "带权限" }
    }

    @State private var mode: Mode = .adhoc
    @State private var target = ""
    @State private var output = ""
    @State private var busy = false

    var body: some View {
        NanoMusePage(title: "签名") {
            NanoMuseCard {
                Picker("模式", selection: $mode) {
                    ForEach(Mode.allCases) { option in Text(option.title).tag(option) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 12)

                HStack(spacing: 12) {
                    Text("目标").font(.body).frame(width: 72, alignment: .leading)
                    TextField("App 容器内的二进制路径", text: $target)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                NanoMuseRowDivider()
                NanoMuseActionRow(title: busy ? "签名中…" : "执行签名", chevron: false) {
                    sign()
                }
                NanoMuseRowDivider()
                NanoMuseActionRow(title: "签名诊断（4 项）", chevron: false) {
                    Task {
                        busy = true
                        output = "诊断中…"
                        output = await NanoMuseCodex.signDiagnostics()
                        busy = false
                    }
                }
            }
            NanoMuseCaption(text: mode == .entitled
                            ? "带权限模式用随包的 entitlements.plist（11 项巨魔权限；已移除那条会让 fork 崩溃的地址空间权限）。"
                            : "ad-hoc 模式只做最小签名，适合普通可执行文件。")

            if !output.isEmpty {
                NanoMuseCard {
                    Text(output)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
    }

    private func sign() {
        guard !target.isEmpty, !busy else { return }
        busy = true
        output = ""
        let mode = self.mode
        let path = target
        let entitlements = Bundle.main.bundlePath + "/entitlements.plist"
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> NanoMuseHelperRunner.Result in
                var arguments: [String] = []
                switch mode {
                case .adhoc: arguments = ["--adhoc-only", path]
                case .entitled: arguments = ["--entitlements", entitlements, path]
                }
                return NanoMuseHelperRunner.run("codex-sign", arguments: arguments, timeout: 120)
            }.value
            output = String(format: "退出码 %d · %.2fs\n\n", result.exitCode, result.duration) + result.output
            busy = false
        }
    }
}

// MARK: - 原生 Shell（bash.real）

struct NanoMuseNativeShellPage: View {
    @State private var command = "ls -l /"
    @State private var output = ""
    @State private var busy = false

    var body: some View {
        NanoMusePage(title: "原生 Shell") {
            NanoMuseCard {
                HStack(spacing: 12) {
                    Text("命令").font(.body).frame(width: 72, alignment: .leading)
                    TextField("例如 ls -l 或 codex-sign --help", text: $command)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                NanoMuseRowDivider()
                NanoMuseActionRow(title: busy ? "执行中…" : "执行", chevron: false) { run() }
            }
            NanoMuseCaption(text: "在 iOS 本机跑 bash.real，PATH 已指向 App 内的 Helpers（cat/ls/grep/tar 等由 ca-filetool 提供）。")

            if !output.isEmpty {
                NanoMuseCard {
                    ScrollView {
                        Text(output)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .frame(maxHeight: 320)
                }
            }
        }
    }

    private func run() {
        guard !busy, !command.isEmpty else { return }
        busy = true
        output = ""
        let cmd = command
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run("bash.real", arguments: ["-lc", cmd], timeout: 120)
            }.value
            output = String(format: "退出码 %d · %.2fs\n\n", result.exitCode, result.duration) + result.output
            busy = false
        }
    }
}
