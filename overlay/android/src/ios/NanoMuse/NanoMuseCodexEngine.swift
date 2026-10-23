import Foundation
import Darwin

/// Codex 引擎：在 nanoMuse 的 iOS App 里通过 app-server 协议驱动 `codex`。
///
/// 覆盖层文件，放进 `android/src/ios/NanoMuse/`（该目录是 Xcode 16 同步文件夹，自动进 target）。
/// 协议与桌面端 `nanomuse/engines/codex/client.py` 一致：
///   initialize → thread/start → turn/start → 通知流；
///   server→client 的审批请求交给 approval 回调，**默认拒绝**。
///
/// Swift 6 严格并发注意：跨 actor 传递的 JSON 一律用 `Data`，
/// 而不是 `[String: Any]`（后者不是 Sendable，会直接编译失败）。
public actor NanoMuseCodexEngine {

    /// 一个 JSON 对象结果。`@unchecked Sendable` 是必要的：字典本身不带并发标注，
    /// 但它在引擎内部只在 actor 与 continuation 之间单向传递，不做共享写。
    public struct Payload: @unchecked Sendable {
        public let json: [String: Any]
        public init(_ json: [String: Any]) { self.json = json }
    }

    public struct RpcError: Error, CustomStringConvertible, Sendable {
        public let code: Int?
        public let message: String
        public var description: String { "rpc \(code.map(String.init) ?? "-"): \(message)" }
    }

    public enum Event: Sendable {
        /// app-server 主动推送；`paramsJSON` 是原始参数 JSON，避免传递非 Sendable 字典。
        case notification(method: String, paramsJSON: Data)
        case exited(status: Int32)
    }

    /// 审批回调：入参与返回都是 JSON 的 `Data` 形式，保持 Sendable。
    public typealias ApprovalHandler = @Sendable (_ requestJSON: Data) async -> Data

    private let binary: String
    private let workspace: String
    private let requestTimeout: TimeInterval

    private var pid: pid_t = 0
    private var stdinFD: Int32 = -1
    private var stdoutFD: Int32 = -1
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Payload, Error>] = [:]
    private var buffer = Data()
    private var reader: Task<Void, Never>?
    private var onEvent: (@Sendable (Event) -> Void)?
    private var approval: ApprovalHandler?

    public init(binary: String, workspace: String, requestTimeout: TimeInterval = 60) {
        self.binary = binary
        self.workspace = workspace
        self.requestTimeout = requestTimeout
    }

    public func setHandlers(
        onEvent: (@Sendable (Event) -> Void)? = nil,
        approval: ApprovalHandler? = nil
    ) {
        self.onEvent = onEvent
        self.approval = approval
    }

    public var isRunning: Bool { pid > 0 }

    // MARK: - 生命周期

    public func start(environment: [String: String] = [:]) throws {
        guard pid == 0 else { return }

        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0 else {
            throw RpcError(code: nil, message: "pipe() failed: \(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 2)
        posix_spawn_file_actions_addclose(&actions, stdinPipe[1])
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var argv = Self.cStrings([binary, "app-server"])
        var envp = Self.cStrings(Self.environment(overrides: environment))
        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, binary, &actions, &attr, &argv, &envp)

        Self.freeCStrings(&argv)
        Self.freeCStrings(&envp)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(stdinPipe[0])
        close(stdoutPipe[1])

        guard rc == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            throw RpcError(code: nil, message: "posix_spawn \(rc): \(String(cString: strerror(rc)))")
        }

        pid = childPID
        stdinFD = stdinPipe[1]
        stdoutFD = stdoutPipe[0]

        // 读完 stdout 的循环放在 detached task，闭包里只捕获 actor 自身（Sendable）
        reader = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.readLoop()
        }
    }

    public func close() {
        reader?.cancel()
        reader = nil
        if stdinFD >= 0 { close(stdinFD); stdinFD = -1 }
        if stdoutFD >= 0 { close(stdoutFD); stdoutFD = -1 }
        if pid > 0 {
            kill(pid, SIGTERM)
            pid = 0
        }
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: RpcError(code: nil, message: "engine closed"))
        }
    }

    // MARK: - 请求

    @discardableResult
    public func request(_ method: String, _ params: [String: Any] = [:]) async throws -> Payload {
        guard isRunning else { throw RpcError(code: nil, message: "engine not running") }
        let id = nextID
        nextID += 1
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let timeout = requestTimeout
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.expire(id: id, method: method)
            }
        }
    }

    public func notify(_ method: String, _ params: [String: Any] = [:]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func expire(id: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: RpcError(code: nil, message: "\(method) timed out"))
    }

    /// 起一轮编码任务。返回 threadId（首轮自动创建）。
    public func startTurn(prompt: String, threadID: String?) async throws -> String {
        let thread: String
        if let existing = threadID {
            thread = existing
        } else {
            let started = try await request("thread/start", ["cwd": workspace])
            guard let created = (started.json["thread"] as? [String: Any])?["id"] as? String else {
                throw RpcError(code: nil, message: "thread/start returned no id")
            }
            thread = created
        }
        _ = try await request("turn/start", [
            "threadId": thread,
            "input": [["type": "text", "text": prompt]],
        ])
        return thread
    }

    // MARK: - 读写

    private func write(_ object: [String: Any]) {
        guard stdinFD >= 0,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(stdinFD, base + offset, bytes.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func readLoop() async {
        guard stdoutFD >= 0 else { return }
        let handle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: false)
        while !Task.isCancelled {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty {
                    await handle(line: line)
                }
            }
        }
        let status = reap()
        onEvent?(.exited(status: status))
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: RpcError(code: nil, message: "codex exited (\(status))"))
        }
    }

    private func handle(line: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        if let id = object["id"] as? Int, object["method"] == nil {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: RpcError(code: error["code"] as? Int,
                                                       message: error["message"] as? String ?? "unknown"))
            } else {
                continuation.resume(returning: Payload(object["result"] as? [String: Any] ?? [:]))
            }
            return
        }

        if let id = object["id"] as? Int, let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            let requestJSON = (try? JSONSerialization.data(withJSONObject: [
                "id": id, "method": method, "params": params,
            ])) ?? Data()

            let answerJSON: Data
            if let approval {
                answerJSON = await approval(requestJSON)
            } else {
                answerJSON = (try? JSONSerialization.data(withJSONObject: [
                    "decision": "denied", "reason": "no approval handler",
                ])) ?? Data("{\"decision\":\"denied\"}".utf8)
            }
            let answer = (try? JSONSerialization.jsonObject(with: answerJSON) as? [String: Any]) ?? [:]
            write(["jsonrpc": "2.0", "id": id, "result": answer])
            return
        }

        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            let paramsJSON = (try? JSONSerialization.data(withJSONObject: params)) ?? Data()
            onEvent?(.notification(method: method, paramsJSON: paramsJSON))
        }
    }

    /// stdout EOF 之后阻塞等待子进程退出。此时已无其它 actor 工作，阻塞是安全的。
    private func reap() -> Int32 {
        guard pid > 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        pid = 0
        return status
    }

    // MARK: - C 字符串

    private static func cStrings(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var out = strings.map { strdup($0) }
        out.append(nil)
        return out
    }

    private static func freeCStrings(_ array: inout [UnsafeMutablePointer<CChar>?]) {
        for pointer in array where pointer != nil { free(pointer) }
        array.removeAll()
    }

    private static func environment(overrides: [String: String]) -> [String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in overrides { env[key] = value }
        return env.map { "\($0.key)=\($0.value)" }
    }
}
