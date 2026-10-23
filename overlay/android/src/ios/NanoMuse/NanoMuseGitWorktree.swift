import Foundation

/// git worktree 管理（在 Alpine 里执行）。原版 MT-Agent 有 worktree 能力，
/// 这里给 nano 侧的 Codex 工作区补上同一件事：列出、创建、删除、清理。
enum NanoMuseGitWorktree {

    struct Entry: Identifiable, Sendable {
        let path: String
        let head: String
        let branch: String
        var id: String { path }
        var isMain: Bool { branch.isEmpty }
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ command: String, timeout: TimeInterval = 60) -> String {
        let result = ISHShellExecutor.executeCommandSync(command, timeout: timeout, lineCallback: nil)
        let out = (result.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let err = (result.errorOutput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return err
    }

    /// `git worktree list --porcelain` → 条目
    static func list(workspace: String) -> [Entry] {
        let raw = run("cd \(quote(workspace)) 2>/dev/null && git worktree list --porcelain 2>&1 || echo '__NOT_A_REPO__'")
        guard !raw.contains("__NOT_A_REPO__") else { return [] }

        var entries: [Entry] = []
        var path = ""
        var head = ""
        var branch = ""

        func flush() {
            guard !path.isEmpty else { return }
            entries.append(Entry(path: path, head: head, branch: branch))
            path = ""; head = ""; branch = ""
        }

        for line in raw.split(separator: "\n") {
            let text = String(line)
            if text.hasPrefix("worktree ") {
                flush()
                path = String(text.dropFirst("worktree ".count))
            } else if text.hasPrefix("HEAD ") {
                head = String(text.dropFirst("HEAD ".count).prefix(8))
            } else if text.hasPrefix("branch ") {
                branch = String(text.dropFirst("branch ".count))
                    .replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        flush()
        return entries
    }

    static func add(workspace: String, path: String, branch: String) -> String {
        let newBranch = branch.isEmpty ? "" : "-b \(quote(branch))"
        return run("""
        cd \(quote(workspace)) || { echo "工作区不存在: \(workspace)"; exit 1; }
        mkdir -p $(dirname \(quote(path)))
        git worktree add \(newBranch) \(quote(path)) 2>&1
        git worktree list 2>&1
        """, timeout: 120)
    }

    static func remove(workspace: String, path: String) -> String {
        run("""
        cd \(quote(workspace)) || exit 1
        git worktree remove --force \(quote(path)) 2>&1
        git worktree prune 2>&1
        git worktree list 2>&1
        """, timeout: 120)
    }

    static func prune(workspace: String) -> String {
        run("cd \(quote(workspace)) && git worktree prune 2>&1 && git worktree list 2>&1")
    }
}
