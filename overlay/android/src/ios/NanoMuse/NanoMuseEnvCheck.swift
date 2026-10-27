//
//  NanoMuseEnvCheck.swift
//  nanoMuse · 环境检测页
//
//  与 MT（wiki.qaq.codexapp）「环境检测」对齐，并做三处优化：
//   1. 依据「随包 → 运行时 → 系统」真实顺序查找可执行文件（不再把 /var/jb 假阳性当可用）
//   2. 未安装的可选组件收敛成一行，不铺满红叉
//   3. 上游连通性给出 HTTP 码 / 耗时 / 失败原因，而不是一个 ✅
//

import SwiftUI

// MARK: - 模型

enum NanoMuseEnvStatus {
    case ok, warn, fail, skip, info

    var symbol: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .skip: return "minus.circle"
        case .info: return "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .skip: return .gray
        case .info: return .secondary
        }
    }

    var label: String {
        switch self {
        case .ok: return "通过"
        case .warn: return "注意"
        case .fail: return "缺失"
        case .skip: return "未启用"
        case .info: return "信息"
        }
    }

    var rank: Int {
        switch self {
        case .fail: return 3
        case .warn: return 2
        case .ok: return 1
        default: return 0
        }
    }

    static func parse(_ raw: String) -> NanoMuseEnvStatus {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ok": return .ok
        case "warn": return .warn
        case "fail": return .fail
        case "skip": return .skip
        default: return .info
        }
    }
}

struct NanoMuseEnvRow: Identifiable {
    let id = UUID()
    let status: NanoMuseEnvStatus
    let title: String
    let detail: String
}

struct NanoMuseEnvSection: Identifiable {
    let id: String
    let title: String
    let note: String
    let optional: Bool
    var rows: [NanoMuseEnvRow]

    var worst: NanoMuseEnvStatus {
        rows.map { $0.status }.max(by: { $0.rank < $1.rank }) ?? .skip
    }
}

// MARK: - 探针

enum NanoMuseEnvProbe {

    /// Alpine 侧一次性把结果打成分隔行，Swift 只负责渲染。
    static let script: String = #"""
    S() { printf '#S|%s|%s|%s\n' "$1" "$2" "$3"; }
    R() { printf '#R|%s|%s|%s\n' "$1" "$2" "$3"; }
    sz() { du -sh "$1" 2>/dev/null | awk '{print $1}'; }
    first() { for p in "$@"; do [ -e "$p" ] && { printf '%s' "$p"; return; }; done; printf ''; }

    S 工具链 "查找顺序：随包 Helper → 运行时 → 系统 PATH" 0
    for c in bash.real sh curl wget unzip tar python3 git clang ld64.lld make ldid dpkg-deb jq rg file xxd; do
      p=$(command -v "$c" 2>/dev/null)
      if [ -n "$p" ]; then R ok "$c" "$p"; else R fail "$c" "未找到"; fi
    done

    S 运行时目录 "Codex / Python / Theos 等可下载运行时" 0
    for d in /opt/runtimes /root/runtimes "$HOME/runtimes" /usr/local/runtimes; do
      if [ -d "$d" ]; then
        n=$(ls -1 "$d" 2>/dev/null | wc -l | tr -d ' ')
        R ok "$d" "$(sz "$d") · $n 项"
      else
        R skip "$d" "不存在"
      fi
    done

    S 设备与环境 "Alpine 侧读到的真实环境" 0
    R info "内核" "$(uname -srm 2>/dev/null)"
    if [ -f /etc/alpine-release ]; then R ok "Alpine" "$(cat /etc/alpine-release 2>/dev/null)"; else R warn "Alpine" "无 /etc/alpine-release"; fi
    if [ -f /etc/os-release ]; then R info "发行版" "$(. /etc/os-release 2>/dev/null; printf '%s' "$PRETTY_NAME")"; fi
    R info "HOME" "$HOME"
    R info "时区" "$(date 2>/dev/null)"
    dfroot=$(df -h / 2>/dev/null | tail -1)
    R info "根分区" "$dfroot"
    if [ -d /opt/runtimes ]; then R info "运行时占用" "$(sz /opt/runtimes)"; fi

    S 上游连通性 "解析 ~/.codex/config.toml 的 base_url 并实测" 0
    cfg=""
    for f in "$HOME/.codex/config.toml" /root/.codex/config.toml /opt/codex/config.toml "$HOME/config.toml"; do
      if [ -f "$f" ]; then cfg="$f"; break; fi
    done
    if [ -z "$cfg" ]; then
      R warn "config.toml" "未找到配置文件"
    else
      R ok "配置文件" "$cfg"
      model=$(grep -m1 -o 'model[[:space:]]*=[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
      if [ -n "$model" ]; then R info "模型" "$model"; else R warn "模型" "未在 config.toml 中声明"; fi
      base=$(grep -m1 -o 'base_url[[:space:]]*=[[:space:]]*"[^"]*"' "$cfg" 2>/dev/null | sed 's/.*"\(.*\)".*/\1/')
      if [ -z "$base" ]; then
        R warn "base_url" "未配置（使用默认端点）"
      else
        R ok "base_url" "$base"
        if command -v curl >/dev/null 2>&1; then
          t0=$(date +%s)
          me=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "$base/models" 2>/dev/null)
          t1=$(date +%s)
          dt=$((t1 - t0))
          case "$me" in
            2??) R ok "GET /models" "HTTP $me · ${dt}s" ;;
            401|403) R warn "GET /models" "HTTP $me · 需鉴权（端点可达）· ${dt}s" ;;
            000|"") R fail "GET /models" "无响应 · 连接失败或超时 · ${dt}s" ;;
            5??) R warn "GET /models" "HTTP $me · 服务端错误 · ${dt}s" ;;
            *) R warn "GET /models" "HTTP $me · ${dt}s" ;;
          esac
        else
          R skip "GET /models" "缺少 curl，无法实测"
        fi
      fi
    fi

    S 报告结束 "" 1
    R info "采集完成" "$(date '+%Y-%m-%d %H:%M:%S')"
    """#

    static func parse(_ output: String) -> [NanoMuseEnvSection] {
        var sections: [NanoMuseEnvSection] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("#S|") || line.hasPrefix("#R|") else { continue }
            let parts = line.components(separatedBy: "|")
            if line.hasPrefix("#S|"), parts.count >= 4 {
                let title = parts[1]
                if title == "报告结束" { continue }
                sections.append(NanoMuseEnvSection(id: title,
                                                   title: title,
                                                   note: parts[2],
                                                   optional: parts[3] == "1",
                                                   rows: []))
            } else if line.hasPrefix("#R|"), parts.count >= 4, !sections.isEmpty {
                let row = NanoMuseEnvRow(status: NanoMuseEnvStatus.parse(parts[1]),
                                         title: parts[2],
                                         detail: parts[3])
                sections[sections.count - 1].rows.append(row)
            }
        }
        return sections
    }

    /// 运行时清单：优先用真实 manifest，失败时退回固定表
    static func runtimeSection() async -> NanoMuseEnvSection {
        var rows: [NanoMuseEnvRow] = []
        // 两套安装位置都要看：App 自身目录（原生，优先）与 Alpine 侧。
        // 之前只问 Alpine 的 /opt/runtimes，导致 App 自己装好的运行时被显示成「未安装」。
        let nativeIDs = Set(NanoMuseNativeRuntime.installedIDs())
        var manifestIDs = Set<String>()
        do {
            let manifest = try await NanoMuseRuntimeManifest.fetch()
            let packages = manifest.packages
            manifestIDs = Set(packages.map { $0.id })
            let status = await runtimeInstalled(ids: packages.map { $0.id })
            for p in packages {
                let onNative = nativeIDs.contains(p.id)
                let onAlpine = !onNative && (status[p.id] ?? false)
                let source = onNative ? "原生 · App 目录" : (onAlpine ? "Alpine 侧" : "")
                rows.append(NanoMuseEnvRow(status: (onNative || onAlpine) ? .ok : .skip,
                                           title: p.displayName,
                                           detail: (onNative || onAlpine) ? "已安装 · \(source) · \(p.sizeText)"
                                                                          : "未安装 · \(p.sizeText)"))
            }
        } catch {
            rows.append(NanoMuseEnvRow(status: .warn, title: "运行时清单", detail: "拉取失败：\(error.localizedDescription)"))
        }
        if rows.isEmpty {
            rows.append(NanoMuseEnvRow(status: .skip, title: "运行时", detail: "清单为空"))
        }
        // 已装在 App 自身目录、但不在远端清单里的（随包附带或手工装的）也列出来
        for id in nativeIDs.subtracting(manifestIDs).sorted() {
            rows.append(NanoMuseEnvRow(status: .ok, title: id, detail: "已安装 · 原生 · App 目录"))
        }
        rows.append(NanoMuseEnvRow(status: .info, title: "安装位置",
                                   detail: NanoMuseNativeRuntime.rootDirectory.path))
        return NanoMuseEnvSection(id: "runtime", title: "运行时",
                                  note: "优先 App 自身目录（原生），其次 Alpine 侧；不借用其它 App",
                                  optional: false, rows: rows)
    }

    static func runtimeInstalled(ids: [String]) async -> [String: Bool] {
        guard !ids.isEmpty else { return [:] }
        let script = NanoMuseRuntimeManifest.statusScript(ids)
        let result = await NanoMuseCodex.runCommand(script, timeout: 60)
        return NanoMuseRuntimeManifest.parseStatus(result.output)
    }
}

// MARK: - 页面

struct NanoMuseEnvCheckView: View {

    @State private var sections: [NanoMuseEnvSection] = []
    @State private var loading = false
    @State private var collapsed: Set<String> = []
    @State private var lastCheck: Date?
    @State private var errorText: String?

    var body: some View {
        NanoMusePage(title: "环境检测") {
            VStack(spacing: 10) {
                headerCard

                if let errorText {
                    NanoMuseCard {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }

                if !sections.isEmpty {
                    NanoMuseCard {
                        HStack(spacing: 18) {
                            Button { copyReport() } label: {
                                Label("复制报告", systemImage: "doc.on.doc").font(.footnote.weight(.semibold))
                            }
                            Button { Task { await run() } } label: {
                                Label("重新检测", systemImage: "arrow.clockwise").font(.footnote.weight(.semibold))
                            }
                            Spacer()
                        }
                        .padding(16)
                    }
                }
                ForEach(sections) { section in
                    sectionCard(section)
                }

                if sections.isEmpty && !loading {
                    NanoMuseCard {
                        Text("点右上角「检测」开始")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }

                Text("只读取，不写入任何系统路径。检测不消耗 token。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .task {
            if sections.isEmpty { await run() }
        }
    }

    private var headerCard: some View {
        NanoMuseCard {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(loading ? "正在检测…" : (sections.isEmpty ? "尚未检测" : summaryText))
                        .font(.subheadline.weight(.semibold))
                    Text(lastCheck.map { "上次检测 " + $0.formatted(date: .omitted, time: .standard) } ?? "按右侧按钮开始")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button {
                    Task { await run() }
                } label: {
                    Text(loading ? "检测中" : "重新检测")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
            .padding(16)
        }
    }

    private var summaryText: String {
        let all = sections.flatMap { $0.rows }
        let fail = all.filter { $0.status == .fail }.count
        let warn = all.filter { $0.status == .warn }.count
        let ok = all.filter { $0.status == .ok }.count
        if fail > 0 { return "\(fail) 项异常 · \(warn) 项注意 · \(ok) 项正常" }
        if warn > 0 { return "\(warn) 项注意 · \(ok) 项正常" }
        return "全部正常 · \(ok) 项通过"
    }

    @ViewBuilder
    private func sectionCard(_ section: NanoMuseEnvSection) -> some View {
        let open = !collapsed.contains(section.id)
        NanoMuseCard {
            Button {
                if open { collapsed.insert(section.id) } else { collapsed.remove(section.id) }
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(section.optional ? Color.gray.opacity(0.5) : section.worst.color)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(section.optional ? Color.secondary : Color.primary)
                        if !section.note.isEmpty {
                            Text(section.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 6)
                    Text("\(section.rows.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                ForEach(section.rows) { row in
                    NanoMuseRowDivider()
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                }
            }
        }
    }

    private func run() async {
        guard !loading else { return }
        loading = true
        errorText = nil
        defer { loading = false }

        var built: [NanoMuseEnvSection] = []
        let runtime = await NanoMuseEnvProbe.runtimeSection()
        built.append(runtime)

        let result = await NanoMuseCodex.runCommand(NanoMuseEnvProbe.script, timeout: 90)
        let probed = NanoMuseEnvProbe.parse(result.output)
        if probed.isEmpty {
            errorText = "探针没有返回可解析的行（退出码 \(result.code)）。输出片段：\n" + String(result.output.suffix(400))
        }
        built.append(contentsOf: probed)

        sections = built
        lastCheck = Date()
        collapsed = Set(built.filter { $0.optional && !$0.rows.contains(where: { $0.status == .fail || $0.status == .warn }) }.map { $0.id })
    }

    private func copyReport() {
        var out: [String] = []
        out.append("NanoCodex 环境检测 · " + Date().formatted(date: .numeric, time: .standard))
        for section in sections {
            out.append("")
            out.append("【\(section.title)】" + (section.note.isEmpty ? "" : "（\(section.note)）"))
            for row in section.rows {
                out.append("  [\(row.status.label)] \(row.title)" + (row.detail.isEmpty ? "" : " — \(row.detail)"))
            }
        }
        UIPasteboard.general.string = out.joined(separator: "\n")
    }
}
