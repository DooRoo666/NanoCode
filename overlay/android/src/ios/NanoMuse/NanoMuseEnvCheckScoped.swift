import SwiftUI
import UIKit

// MARK: - 分环境结果容器

struct NanoMuseScopedEnvState {
    var sections: [NanoMuseEnvSection] = []
    var loading = false
    var lastCheck: Date?
    var error: String?

    var rowCount: Int { sections.reduce(0) { $0 + $1.rows.count } }

    var summary: String {
        if loading { return "检测中…" }
        guard !sections.isEmpty else { return "尚未检测" }
        let rows = sections.flatMap { $0.rows }
        let bad = rows.filter { $0.status == .fail || $0.status == .warn }.count
        return bad == 0 ? "全部正常 · \(rows.count) 项" : "\(bad)/\(rows.count) 项需要注意"
    }

    var stamp: String {
        guard let lastCheck else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "上次 " + formatter.string(from: lastCheck)
    }

    var report: String {
        var lines: [String] = []
        for section in sections {
            lines.append("[\(section.title)]")
            for row in section.rows {
                lines.append("  \(row.title)：\(row.detail.isEmpty ? "-" : row.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 分环境检测页

struct NanoMuseScopedEnvCheckView: View {
    @State private var host = NanoMuseScopedEnvState()
    @State private var alpine = NanoMuseScopedEnvState()
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NanoMuseCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("两套环境分开检测")
                        .font(.subheadline.weight(.semibold))
                    Text("宿主 = 装在 App 包里的 Mach-O 运行时；Alpine = iSH 里的 Linux 工具。它们互不相通，所以各自检测、各自出结果。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button {
                            Task { await detectAll() }
                        } label: {
                            Text(host.loading || alpine.loading ? "检测中…" : "全部检测")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .disabled(host.loading || alpine.loading)
                        Button {
                            UIPasteboard.general.string = combinedReport
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                        } label: {
                            Text(copied ? "已复制" : "复制报告")
                                .font(.footnote.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                }
                .padding(14)
            }

            scopeCard(.host)
            scopeCard(.alpine)
        }
        .task {
            if host.sections.isEmpty { await detect(.host) }
            if alpine.sections.isEmpty { await detect(.alpine) }
        }
    }

    private var combinedReport: String {
        var lines = ["== 宿主（App 内置）==", host.report, "", "== Alpine（iSH）==", alpine.report]
        lines.append("")
        lines.append("宿主根目录：\(NanoMuseNativeRuntime.rootDirectory.path)")
        return lines.joined(separator: "\n")
    }

    // MARK: 单个环境

    @ViewBuilder
    private func scopeCard(_ scope: NanoMuseEnvScope) -> some View {
        let state = scope == .host ? host : alpine
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(scope.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if state.loading {
                    ProgressView().controlSize(.small)
                }
                Button {
                    Task { await detect(scope) }
                } label: {
                    Text("检测\(scope.short)")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(state.loading)
            }
            .padding(.horizontal, 4)

            NanoMuseCard {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(scope.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("位置：\(scope.rootText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if let error = state.error {
                        NanoMuseRowDivider()
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }

                    ForEach(state.sections) { section in
                        NanoMuseRowDivider()
                        VStack(alignment: .leading, spacing: 0) {
                            Text(section.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 14)
                                .padding(.top, 9)
                                .padding(.bottom, 2)
                            ForEach(section.rows) { row in
                                rowView(row)
                            }
                        }
                    }

                    if state.sections.isEmpty && !state.loading && state.error == nil {
                        NanoMuseRowDivider()
                        Text("还没有结果，点右上角「检测\(scope.short)」")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                }
            }

            HStack(spacing: 6) {
                Text(state.summary)
                if !state.stamp.isEmpty {
                    Text("·")
                    Text(state.stamp)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    private func rowView(_ row: NanoMuseEnvRow) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: row.status.symbol)
                .font(.footnote)
                .foregroundStyle(row.status.color)
                .frame(width: 15, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.footnote.weight(.medium))
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 检测

    private func detectAll() async {
        await detect(.host)
        await detect(.alpine)
    }

    private func detect(_ scope: NanoMuseEnvScope) async {
        switch scope {
        case .host:
            guard !host.loading else { return }
            host.loading = true
            host.error = nil
        case .alpine:
            guard !alpine.loading else { return }
            alpine.loading = true
            alpine.error = nil
        }

        var sections: [NanoMuseEnvSection] = []
        var failure: String?

        switch scope {
        case .host:
            let hostSection = await NanoMuseEnvProbe.runtimeSection()
            sections = [hostSection]
            if sections.isEmpty { failure = "宿主运行时目录读取失败" }
        case .alpine:
            let (code, output) = await NanoMuseCodex.runCommand(NanoMuseEnvProbe.script, timeout: 120)
            sections = NanoMuseEnvProbe.parse(output)
            if sections.isEmpty {
                failure = code == 0 ? "iSH 没有返回可解析的结果" : "iSH 退出码 \(code)"
            }
        }

        await MainActor.run {
            switch scope {
            case .host:
                host.sections = sections
                host.error = failure
                host.lastCheck = Date()
                host.loading = false
            case .alpine:
                alpine.sections = sections
                alpine.error = failure
                alpine.lastCheck = Date()
                alpine.loading = false
            }
        }
    }
}
