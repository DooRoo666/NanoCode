import Foundation
import Darwin

/// Codex 引擎：在 nanoMuse 的 iOS App 里通过 app-server 协议驱动 `codex`。
///
/// 它是「覆盖层」文件，放进 `android/src/ios/NanoMuse/` 后由 `Tools/apply_overlay.py`
/// 加进 Minis target。不依赖 App 里的任何其它类型，因此可以先独立编译通过再接业务。
///
/// 协议与 Python 侧 `nanomuse/engines/codex/client.py` 完全一致：
///   initialize → thread/start → turn/start → 通知流；server→client 的审批请求
///   交给 `approval` 回调，默认拒绝（不给「无人值守也能跑」的口子）。
public actor NanoMuseCodexEngine {

    public struct RpcError: Error, CustomStringConvertible {
        public let code: Int?
        public let message: String
        public var description: String { "rpc \(code.map(String.init) ?? "-"): \(message)" }
    }

    public enum Event: Sendable {
        case notification(method: String, params: [String: Any])
        case exited(status: Int32)
    }

    /// 审批回调：收到 app-server 的 server→client 请求，返回应答字典（默认：拒绝）。
    public typealias ApprovalHandler = @Sendable ([String: Any]) async -> [String: Any]

    private let binary: String
    private let workspace: String
    private let requestTimeout: TimeInterval

    private var pid: pid_t = 0
    private var stdinFD: Int32 = -1
    private var stdoutFD: Int32 = -1
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
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

        var stdinPipe: [Int32] = [-1, -1]   // [read, write]
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
            throw RpcError(code: nil, message: "posix_spawn failed (\(rc)): \(String(cString: strerror(rc)))")
        }

        pid = childPID
        stdinFD = stdinPipe[1]
        stdoutFD = stdoutPipe[0]

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
        for (_, cont) in waiters {
            cont.resume(throwing: RpcError(code: nil, message: "engine closed"))
        }
    }

    // MARK: - 请求

    @discardableResult
    public func request(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        guard isRunning else { throw RpcError(code: nil, message: "engine not running") }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            write(payload)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.requestTimeout ?? 60) * 1_000_000_000))
                await self?.timeout(id: id, method: method)
            }
        }
    }

    public func notify(_ method: String, _ params: [String: Any] = [:]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func timeout(id: Int, method: String) {
        guard let cont = pending.removeValue(forKey: id) else { return }
        cont.resume(throwing: RpcError(code: nil, message: "\(method) timed out"))
    }

    // MARK: - 高层操作

    /// 起一轮编码任务，返回 turn 结束时的文本。
    public func runTurn(prompt: String, threadID: inout String?) async throws -> String {
        if threadID == nil {
            let started = try await request("thread/start", ["cwd": workspace])
            threadID = ((started["thread"] as? [String: Any])?["id"] as? String)
        }
        guard let thread = threadID else {
            throw RpcError(code: nil, message: "thread/start returned no id")
        }
        _ = try await request("turn/start", [
            "threadId": thread,
            "input": [["type": "text", "text": prompt]],
        ])
        return ""   // 文本通过 onEvent 的 notification 流式返回
    }

    // MARK: - 读写

    private func write(_ object: [String: Any]) {
        guard stdinFD >= 0,
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let bytes = Array(line.utf8)
        bytes.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let n = Darwin.write(stdinFD, base + written, bytes.count - written)
                if n <= 0 { break }
                written += n
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
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty {
                    await handle(line: Data(line))
                }
            }
        }
        let status = await reap()
        onEvent?(.exited(status: status))
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters {
            cont.resume(throwing: RpcError(code: nil, message: "codex exited (\(status))"))
        }
    }

    private func handle(line: Data) async {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }

        // 应答：id + result/error
        if let id = object["id"] as? Int, object["method"] == nil {
            guard let cont = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                cont.resume(throwing: RpcError(code: error["code"] as? Int,
                                               message: error["message"] as? String ?? "unknown"))
            } else {
                cont.resume(returning: object["result"] as? [String: Any] ?? [:])
            }
            return
        }

        // server -> client 请求：走审批，默认拒绝
        if let id = object["id"] as? Int, let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            let request: [String: Any] = ["id": id, "method": method, "params": params]
            let answer: [String: Any]
            if let approval {
                answer = await approval(request)
            } else {
                answer = ["decision": "denied", "reason": "no approval handler"]
            }
            write(["jsonrpc": "2.0", "id": id, "result": answer])
            return
        }

        // 通知
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            onEvent?(.notification(method: method, params: params))
        }
    }

    private func reap() async -> Int32 {
        guard pid > 0 else { return -1 }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        pid = 0
        return status
    }

    // MARK: - C 字符串工具

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
