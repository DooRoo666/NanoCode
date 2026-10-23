import Foundation
import UserNotifications

/// 子代理：把 Codex 当成"专门干编码的帮手"放到后台跑，跑完把结果送回主对话。
///
/// 与 MT-Agent 的逻辑一致：
///   主 Agent（nanoMuse）派活 → 子代理（Codex）在 Alpine 里独立跑 →
///   结束写回结果、发本地通知 → 主 Agent 下次取结果时一次拿走。
enum NanoMuseSubagentKind: String, Codable, Sendable {
    case codex
    case shell
}

struct NanoMuseSubagentJob: Identifiable, Codable, Sendable {
    let id: String
    let kind: NanoMuseSubagentKind
    let prompt: String
    let workspace: String
    var status: String            // running / finished / failed
    var output: String
    var exitCode: Int32
    let createdAt: Date
    var finishedAt: Date?
    var delivered: Bool

    var durationText: String {
        guard let finishedAt else { return "运行中" }
        return String(format: "%.1fs", finishedAt.timeIntervalSince(createdAt))
    }
}

@MainActor
final class NanoMuseSubagentCenter: ObservableObject {

    static let shared = NanoMuseSubagentCenter()

    @Published private(set) var jobs: [NanoMuseSubagentJob] = []

    private let storageURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("NanoCodex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("subagents.json")
    }()

    private init() {
        load()
    }

    // MARK: - 派活

    @discardableResult
    func dispatch(kind: NanoMuseSubagentKind,
                  prompt: String,
                  workspace: String = "/root/work",
                  timeout: TimeInterval = 1800) -> NanoMuseSubagentJob {
        let job = NanoMuseSubagentJob(
            id: String(UUID().uuidString.prefix(8)).lowercased(),
            kind: kind,
            prompt: prompt,
            workspace: workspace,
            status: "running",
            output: "",
            exitCode: -1,
            createdAt: Date(),
            finishedAt: nil,
            delivered: false
        )
        jobs.insert(job, at: 0)
        persist()

        let credential = NanoMuseCodexSettings.resolved()
        let model = NanoMuseCodexSettings.current.model
        let jobID = job.id

        Task.detached(priority: .background) { [weak self] in
            let output: String
            let code: Int32

            switch kind {
            case .codex:
                let result = await NanoMuseCodex.execute(
                    prompt: prompt,
                    workspace: workspace,
                    apiKey: credential.apiKey,
                    baseURL: credential.baseURL,
                    model: model,
                    timeout: timeout
                )
                output = result.output.isEmpty ? result.errorOutput : result.output
                code = result.exitCode
            case .shell:
                let result = await NanoMuseCodex.runCommand(
                    "cd \(workspace) 2>/dev/null; \(prompt) 2>&1",
                    timeout: timeout
                )
                output = result.output
                code = result.code
            }

            await MainActor.run {
                self?.finish(id: jobID, output: output, code: code)
            }
        }

        return job
    }

    // MARK: - 取结果

    /// 主 Agent 取「已完成但还没送达」的结果，并标记为已送达。
    func pendingForAgent(limit: Int = 3) -> [NanoMuseSubagentJob] {
        let pending = jobs.filter { $0.status != "running" && !$0.delivered }.prefix(limit)
        let ids = Set(pending.map(\.id))
        for index in jobs.indices where ids.contains(jobs[index].id) {
            jobs[index].delivered = true
        }
        persist()
        return Array(pending)
    }

    func recent(limit: Int = 20) -> [NanoMuseSubagentJob] {
        Array(jobs.prefix(limit))
    }

    func clearFinished() {
        jobs.removeAll { $0.status != "running" }
        persist()
    }

    // MARK: - 内部

    private func finish(id: String, output: String, code: Int32) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = code == 0 ? "finished" : "failed"
        jobs[index].output = output
        jobs[index].exitCode = code
        jobs[index].finishedAt = Date()
        persist()
        notify(job: jobs[index])
    }

    private func notify(job: NanoMuseSubagentJob) {
        let content = UNMutableNotificationContent()
        content.title = job.kind == .codex ? "Codex 子代理完成" : "后台任务完成"
        content.body = String(job.prompt.prefix(60))
        content.sound = .default
        let request = UNNotificationRequest(identifier: "nanocodex-\(job.id)",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let stored = try? JSONDecoder().decode([NanoMuseSubagentJob].self, from: data) else { return }
        // 上次进程被杀时仍在跑的任务标为失败，避免一直显示"运行中"
        jobs = stored.map { job in
            var copy = job
            if copy.status == "running" { copy.status = "failed"; copy.output = "应用重启，任务中断" }
            return copy
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
