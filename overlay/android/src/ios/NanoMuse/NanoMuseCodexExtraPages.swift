import SwiftUI

// MARK: - Codex 页里的「更多」入口卡

extension NanoMuseCodexView {
    var extraCard: some View {
        NanoMuseCard {
            NavigationLink { NanoMuseRuntimePage() } label: {
                row(title: "运行时（原版清单）", subtitle: "codex · theos · ollvm · node · python · 逆向工具")
            }
            .buttonStyle(.plain)
            NanoMuseRowDivider()
            NavigationLink { NanoMuseSubagentPage() } label: {
                row(title: "子代理", subtitle: "后台跑 Codex，完成后回投结果")
            }
            .buttonStyle(.plain)
            NanoMuseRowDivider()
            NavigationLink { NanoMuseWorktreePage() } label: {
                row(title: "Git Worktree", subtitle: "为 Codex 建独立工作树")
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
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - 运行时（manifest）

struct NanoMuseRuntimePage: View {
    @State private var packages: [NanoMuseRuntimeManifest.Package] = []
    @State private var proxies: [String] = []
    @State private var installed: [String: Bool] = [:]
    @State private var manifestError: String?
    @State private var runningID: String?
    @State private var logLines: [String] = []
    @State private var progress: Double?

    var body: some View {
        NanoMusePage(title: "运行时") {
            NanoMuseCard {
                NanoMuseRowLabel(title: "清单", value: packages.isEmpty ? "未加载" : "\(packages.count) 个包",
                                 titleColor: .primary, chevron: false)
                NanoMuseRowDivider()
                NanoMuseActionRow(title: "刷新清单", chevron: false) { Task { await load() } }
                if let manifestError {
                    Text(manifestError)
                        .font(.footnote).foregroundStyle(.red)
                        .padding(.horizontal, 16).padding(.bottom, 10)
                }
            }
            NanoMuseCaption(text: "与 MT-Agent 同一份清单（含代理回退、SHA256 校验、probe 探测）。theos 214 MB 装着 iOS 编译/链接/打包工具链。")

            if !packages.isEmpty {
                NanoMuseCard {
                    ForEach(Array(packages.enumerated()), id: \.element.id) { index, package in
                        if index > 0 { NanoMuseRowDivider() }
                        packageRow(package)
                    }
                }
            }

            if !logLines.isEmpty {
                NanoMuseCard {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(line.hasPrefix("ERR") ? .red : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 220)
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
            }
            Spacer(minLength: 8)
            if runningID == package.id {
                ProgressView().controlSize(.small)
            } else if installed[package.id] == true {
                Text("已安装").font(.footnote).foregroundStyle(NanoMuseTones.action)
            } else {
                Button {
                    install(package)
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
            let ids = manifest.packages.map(\.id)
            let script = NanoMuseRuntimeManifest.statusScript(ids)
            let output = await Task.detached(priority: .userInitiated) { () -> String in
                let result = ISHShellExecutor.executeCommandSync(script, timeout: 30, lineCallback: nil)
                return result.output ?? ""
            }.value
            installed = NanoMuseRuntimeManifest.parseStatus(output)
        } catch {
            manifestError = error.localizedDescription
        }
    }

    private func install(_ package: NanoMuseRuntimeManifest.Package) {
        runningID = package.id
        logLines.removeAll()
        let script = NanoMuseRuntimeManifest.installScript(package, proxies: proxies)
        NanoMuseCodex.runStreaming(script, timeout: 3600) { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            logLines.append(trimmed)
            if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
            if trimmed.hasPrefix("STEP ") {
                let lowered = trimmed.lowercased()
                if lowered.contains("2/5") { progress = 0.1 }
                if lowered.contains("3/5") { progress = 0.7 }
                if lowered.contains("4/5") { progress = 0.85 }
                if lowered.contains("5/5") { progress = 0.95 }
                if lowered.hasSuffix("done") { progress = 1 }
            }
        } onFinish: { _ in
            runningID = nil
            Task { await load() }
        }
    }
}

// MARK: - 子代理

struct NanoMuseSubagentPage: View {
    @ObservedObject private var center = NanoMuseSubagentCenter.shared

    var body: some View {
        NanoMusePage(title: "子代理") {
            NanoMuseCard {
                NanoMuseRowLabel(title: "作业数", value: "\(center.recent().count)", titleColor: .primary, chevron: false)
                NanoMuseRowDivider()
                NanoMuseActionRow(title: "清除已结束", chevron: false) { center.clearFinished() }
            }
            NanoMuseCaption(text: "主 Agent 用 subagent_dispatch 把编码任务派给后台 Codex，subagent_result 取回结果；完成时发本地通知。")

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
        NanoMusePage(title: "Worktree") {
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
            let list = await Task.detached(priority: .userInitiated) { NanoMuseGitWorktree.list(workspace: ws) }.value
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
                NanoMuseGitWorktree.add(workspace: ws, path: path, branch: branch)
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
                NanoMuseGitWorktree.remove(workspace: ws, path: entry.path)
            }.value
            message = output
            busy = false
            refresh()
        }
    }
}
