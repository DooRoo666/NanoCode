import Foundation

/// 在 nanoMuse 里安装 / 运行 Codex。
///
/// **两条安装路线**（互不替代，状态合并展示）：
///   1. Alpine（Linux）：官方 `codex-aarch64-unknown-linux-musl.tar.gz` → `/usr/local/bin/codex`
///   2. 原生（iOS）：清单里的 `iphoneos-arm64.deb` → App 容器（`NanoMuseNativeRuntime`）
///
/// 判定「装没装上」只看**文件是否存在且可执行**，`--version` 只作参考——
/// 因为 iSH 的 syscall 覆盖不全，musl 静态程序很可能一跑就崩，
/// 用运行结果当判据会把"装好了但跑不起来"误报成"没装"。
public enum NanoMuseCodex {

    // MARK: - 状态

    public struct Status: Sendable {
        public let alpinePath: String?
        public let alpineSize: Int
        public let alpineRuns: Bool
        public let alpineVersion: String?
        public let nativePath: String?
        public let nativeSize: Int
        public let nativeRuns: Bool
        public let rawOutput: String

        public var installed: Bool { alpinePath != nil || nativePath != nil }
        public var version: String? { alpineVersion }

        /// 「Alpine 已装（0.163.0）· 原生 未装」
        public var summary: String {
            var parts: [String] = []
            if let alpinePath {
                let size = alpineSize > 0 ? " \(alpineSize / 1048576) MB" : ""
                let state = alpineRuns ? (alpineVersion.map { " \($0)" } ?? " 可运行") : " 不可运行"
                parts.append("Alpine 已装\(size) ·\(state)")
                _ = alpinePath
            } else {
                parts.append("Alpine 未装")
            }
            if let nativePath {
                let size = nativeSize > 0 ? " \(nativeSize / 1048576) MB" : ""
                parts.append("原生 已装\(size)\(nativeRuns ? " 可运行" : " 未验证")")
                _ = nativePath
            } else {
                parts.append("原生 未装")
            }
            return parts.joined(separator: " · ")
        }
    }

    public struct RunResult: Sendable {
        public let exitCode: Int32
        public let output: String
        public let errorOutput: String
        public let duration: TimeInterval
    }

    /// 官方发布的 aarch64 musl 资产
    public static let downloadURL =
        "https://github.com/openai/codex/releases/latest/download/codex-aarch64-unknown-linux-musl.tar.gz"

    /// Alpine 内的安装路径
    public static let binaryPath = "/usr/local/bin/codex"

    /// 国内常用 GitHub 代理，直连失败时按顺序回退
    public static let downloadProxies = ["https://gh-proxy.org/", "https://ghproxy.net/"]

    // MARK: - 执行入口

    public static func runCommand(
        _ command: String,
        timeout: TimeInterval = 900
    ) async -> (code: Int32, output: String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            let lock = NSLock()
            var lines: [String] = []
            var finished = false

            _ = ISHShellExecutor.executeCommand(
                command,
                lineCallback: { line, _ in
                    lock.lock(); lines.append(line); lock.unlock()
                },
                completion: { result in
                    lock.lock()
                    guard !finished else { lock.unlock(); return }
                    finished = true
                    let collected = lines
                    lock.unlock()
                    continuation.resume(returning: (result.exitCode, collected.joined(separator: "\n")))
                }
            )
        }
    }

    // MARK: - 状态（分位置判定，不依赖 --version 的退出码）

    public static func status() async -> Status {
        let script = #"""
        echo "PATH=$PATH"
        if [ -x /usr/local/bin/codex ]; then
          echo "ALPINE_PATH=/usr/local/bin/codex"
          echo "ALPINE_SIZE=$(stat -c %s /usr/local/bin/codex 2>/dev/null || echo 0)"
          ALPINE_HEAD=$(od -An -tx1 -N4 /usr/local/bin/codex 2>/dev/null | tr -d ' \n')
          echo "ALPINE_HEAD=$ALPINE_HEAD"
          VER_OUT=$(/usr/local/bin/codex --version 2>&1); VER_RC=$?
          echo "ALPINE_VER_RC=$VER_RC"
          echo "ALPINE_VER=$(printf '%s' "$VER_OUT" | head -1)"
        else
          echo "ALPINE_PATH="
          echo "ALPINE_SIZE=0"
          echo "ALPINE_VER_RC=127"
        fi
        echo "PROBE_END"
        """#

        let (_, out) = await runCommand(script, timeout: 60)
        let fields = parseKeyValues(out)

        let alpinePath = fields["ALPINE_PATH"].flatMap { $0.isEmpty ? nil : $0 }
        let alpineSize = Int(fields["ALPINE_SIZE"] ?? "0") ?? 0
        let alpineRuns = (Int(fields["ALPINE_VER_RC"] ?? "127") ?? 127) == 0
        let alpineVersion = fields["ALPINE_VER"].flatMap { value -> String? in
            guard let first = value.split(separator: " ").last.map(String.init), !value.isEmpty else { return nil }
            return first
        }

        // 原生：App 容器里找 codex 可执行
        let native = nativeBinary()

        return Status(
            alpinePath: alpinePath,
            alpineSize: alpineSize,
            alpineRuns: alpineRuns,
            alpineVersion: alpineRuns ? alpineVersion : nil,
            nativePath: native?.path,
            nativeSize: native?.size ?? 0,
            nativeRuns: false,
            rawOutput: out
        )
    }

    private static func parseKeyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// 在原生运行时目录里找 codex 可执行文件
    static func nativeBinary() -> (path: String, size: Int)? {
        var roots: [URL] = []
        if NanoMuseNativeRuntime.isInstalled("codex") {
            roots.append(NanoMuseNativeRuntime.directory(for: "codex"))
        }
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                                                                 includingPropertiesForKeys: [.fileSizeKey],
                                                                 options: []) else { continue }
            for case let url as URL in enumerator {
                guard url.lastPathComponent == "codex" else { continue }
                guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return (url.path, size)
            }
        }
        return nil
    }

    // MARK: - 流式执行

    @discardableResult
    public static func runStreaming(
        _ script: String,
        timeout: TimeInterval = 1800,
        onLine: @escaping (String) -> Void,
        onFinish: @escaping (Bool) -> Void
    ) -> Bool {
        let pid = ISHShellExecutor.executeCommand(
            script,
            lineCallback: { line, _ in onLine(line) },
            completion: { result in onFinish(result.exitCode == 0) }
        )
        return pid > 0
    }

    @discardableResult
    public static func runStreamingAwait(_ script: String, timeout: TimeInterval = 1800) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            _ = runStreaming(script, timeout: timeout, onLine: { _ in }, onFinish: { ok in
                continuation.resume(returning: ok)
            })
        }
    }

    // MARK: - 安装脚本（加固版）

    /// 与之前相比的修正：
    ///   · 不用 `install`（Alpine 默认没有），改 `cp` + `chmod`
    ///   · 直连失败自动走 gh-proxy 代理
    ///   · 装完同时建 `/usr/bin/codex` 软链，并写 PATH 片段
    ///   · 结尾输出 `RESULT installed` 与 `VERIFY_*`，**不用 `--version` 决定成败**
    public static var installScript: String {
        let attempts = ([""] + downloadProxies)
            .map { "\"\($0)\(downloadURL)\"" }
            .joined(separator: " ")

        return #"""
        set -u
        say() { echo "STEP $1"; }
        fail() { echo "ERR $1"; exit 1; }

        say "1/7 检查环境"
        ARCH=$(uname -m)
        echo "  uname -m = $ARCH"
        echo "  shell    = $0"
        echo "  PATH     = $PATH"
        df -h / 2>/dev/null | tail -1 || true

        say "2/7 安装下载依赖 (curl tar ca-certificates)"
        apk add --no-cache curl tar ca-certificates 2>&1 | tail -3 || true
        command -v curl >/dev/null 2>&1 || fail "curl 不可用"
        command -v tar  >/dev/null 2>&1 || fail "tar 不可用"

        say "3/7 读取远端包大小"
        URLS="__ATTEMPTS__"
        TOTAL=0
        for U in $URLS; do
          N=$(curl -sIL --connect-timeout 15 "$U" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
          if [ "${N:-0}" -gt 1000000 ]; then TOTAL=$N; PICK=$U; break; fi
        done
        echo "  content-length = $TOTAL bytes"
        [ "${TOTAL:-0}" -gt 1000000 ] || echo "  提示：拿不到长度，仍继续尝试下载"

        say "4/7 下载（每秒回报字节数）"
        rm -f /tmp/codex.tgz
        OK=0
        for U in $URLS; do
          echo "  尝试：$U"
          ( curl -fL --retry 1 --connect-timeout 20 -o /tmp/codex.tgz "$U" 2>/dev/null ) &
          CPID=$!
          while kill -0 $CPID 2>/dev/null; do
            SZ=$(stat -c %s /tmp/codex.tgz 2>/dev/null || echo 0)
            echo "BYTES $SZ $TOTAL"
            sleep 1
          done
          wait $CPID && OK=1
          SZ=$(stat -c %s /tmp/codex.tgz 2>/dev/null || echo 0)
          echo "BYTES $SZ $TOTAL"
          if [ "$OK" = "1" ] && [ "$SZ" -gt 1000000 ]; then break; fi
          OK=0
        done
        SZ=$(stat -c %s /tmp/codex.tgz 2>/dev/null || echo 0)
        echo "  实际大小 = $SZ bytes"
        [ "$SZ" -gt 1000000 ] || fail "下载失败或内容过小（$SZ bytes）"

        say "5/7 校验 tarball"
        echo "  sha256(tgz) = $(sha256sum /tmp/codex.tgz | cut -d' ' -f1)"
        gzip -t /tmp/codex.tgz 2>/dev/null && echo "  gzip 完整性 = OK" || fail "gzip 校验失败"

        say "6/7 解包并安装"
        rm -rf /tmp/codex-pkg && mkdir -p /tmp/codex-pkg
        tar xzf /tmp/codex.tgz -C /tmp/codex-pkg || fail "解包失败"
        echo "  解包内容："
        find /tmp/codex-pkg -maxdepth 3 -type f | head -10 | sed 's/^/    /'
        BIN=$(find /tmp/codex-pkg -maxdepth 4 -type f -name codex | head -1)
        [ -n "${BIN:-}" ] || fail "压缩包里找不到 codex 可执行文件"
        echo "  找到 = $BIN"
        echo "  sha256(bin) = $(sha256sum "$BIN" | cut -d' ' -f1)"
        echo "  ELF 头 = $(od -An -tx1 -N4 "$BIN" | tr -d ' \n')"

        mkdir -p /usr/local/bin
        cp "$BIN" /usr/local/bin/codex || fail "复制到 /usr/local/bin 失败"
        chmod 0755 /usr/local/bin/codex || fail "chmod 失败"
        ln -sf /usr/local/bin/codex /usr/bin/codex 2>/dev/null || true
        mkdir -p /etc/profile.d
        echo 'export PATH="/usr/local/bin:$PATH"' > /etc/profile.d/codex-path.sh
        chmod 0644 /etc/profile.d/codex-path.sh
        echo "  已建软链 /usr/bin/codex 与 PATH 片段"
        echo "  说明：Linux ELF 靠 Alpine 的内核接口运行，不需要 iOS 代码签名。"

        say "7/7 验证（仅作参考，失败不代表没装上）"
        ls -l /usr/local/bin/codex 2>&1 | sed 's/^/  /'
        echo "  SIZE=$(stat -c %s /usr/local/bin/codex 2>/dev/null || echo 0) bytes"
        echo "  HEAD=$(od -An -tx1 -N4 /usr/local/bin/codex 2>/dev/null | tr -d ' \n')"
        VOUT=$(/usr/local/bin/codex --version 2>&1); VRC=$?
        echo "  codex --version (rc=$VRC): $(printf '%s' "$VOUT" | head -1)"
        if [ "$VRC" != "0" ]; then
          echo "  提示：iSH 的 syscall 覆盖不全时，musl 静态程序可能无法启动。"
          echo "        可改用「原生安装」（清单里的 iphoneos-arm64.deb，跑在 iOS 上）。"
        fi
        echo "RESULT installed"
        say "done"
        """#
            .replacingOccurrences(of: "__ATTEMPTS__", with: attempts)
    }

    /// 诊断脚本：把「路径 / 大小 / 头 / 版本 / PATH」一次打全，便于定位
    public static var diagnoseScript: String {
        #"""
        echo "=== 诊断 ==="
        echo "uname -m = $(uname -m)"
        echo "PATH = $PATH"
        echo "--- /usr/local/bin/codex ---"
        if [ -e /usr/local/bin/codex ]; then
          ls -l /usr/local/bin/codex
          echo "size = $(stat -c %s /usr/local/bin/codex 2>/dev/null || echo 0)"
          echo "head = $(od -An -tx1 -N8 /usr/local/bin/codex 2>/dev/null | tr -d ' \n')"
          echo "file = $(file /usr/local/bin/codex 2>&1 || echo 'file 命令不可用')"
          VOUT=$(/usr/local/bin/codex --version 2>&1); VRC=$?
          echo "version_rc = $VRC"
          echo "version_out = $(printf '%s' "$VOUT" | head -3)"
          echo "ldd = $(ldd /usr/local/bin/codex 2>&1 | head -3)"
        else
          echo "不存在"
        fi
        echo "--- /usr/bin/codex ---"
        ls -l /usr/bin/codex 2>&1 || echo "无软链"
        echo "--- 磁盘 ---"
        df -h / | tail -1
        echo "=== 诊断结束 ==="
        """#
    }

    @discardableResult
    public static func install(force: Bool = false) async -> Status {
        await runStreamingAwait(installScript, timeout: 1800)
        return await status()
    }

    // MARK: - 运行（优先 Alpine，其次原生）

    public static func execute(
        prompt: String,
        workspace: String = "/root/work",
        apiKey: String? = nil,
        baseURL: String? = nil,
        model: String? = nil,
        extraArgs: [String] = [],
        timeout: TimeInterval = 900
    ) async -> RunResult {

        var effectivePrompt = prompt
        if NanoMuseCodexSettings.useFallbackPrompt,
           let guide = NanoMuseCodexAssets.fallbackPrompt(),
           !guide.isEmpty {
            effectivePrompt = guide + "\n\n---\n\n任务：\n" + prompt
        }

        let current = await status()

        // 原生二进制：直接 posix_spawn，不需要 Alpine
        if current.alpinePath == nil, let native = nativeBinary() {
            var args = ["exec", "--skip-git-repo-check"]
            args.append(contentsOf: extraArgs)
            args.append(effectivePrompt)

            var env: [String: String] = [:]
            if let apiKey, !apiKey.isEmpty { env["OPENAI_API_KEY"] = apiKey }
            if let baseURL, !baseURL.isEmpty { env["OPENAI_BASE_URL"] = baseURL }
            if let model, !model.isEmpty { env["CODEX_MODEL"] = model }

            // iOS 没有 posix_spawn 的 chdir，用随包的 bash 包一层设置工作目录
            let command = "cd \(quote(workspace)) 2>/dev/null || mkdir -p \(quote(workspace)) && cd \(quote(workspace)); "
                + "exec \(quote(native.path)) " + args.map { quote($0) }.joined(separator: " ")
            let result = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run("bash.real",
                                         arguments: ["-lc", command],
                                         timeout: timeout,
                                         extraEnvironment: env)
            }.value
            return RunResult(exitCode: result.exitCode, output: result.output,
                             errorOutput: "", duration: result.duration)
        }

        // Alpine 路线
        var env: [String] = []
        if let apiKey, !apiKey.isEmpty { env.append("export OPENAI_API_KEY=\(quote(apiKey))") }
        if let baseURL, !baseURL.isEmpty { env.append("export OPENAI_BASE_URL=\(quote(baseURL))") }
        if let model, !model.isEmpty { env.append("export CODEX_MODEL=\(quote(model))") }

        var args = ["exec", "--skip-git-repo-check"]
        args.append(contentsOf: extraArgs)
        let command = """
        mkdir -p \(quote(workspace))
        \(env.joined(separator: "\n"))
        cd \(quote(workspace)) && codex \(args.joined(separator: " ")) \(quote(effectivePrompt)) 2>&1
        """

        let started = Date()
        let (code, out) = await runCommand(command, timeout: timeout)
        return RunResult(exitCode: code, output: out, errorOutput: "",
                         duration: Date().timeIntervalSince(started))
    }

    /// 单引号转义，避免 prompt 里的字符被 shell 解释
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 卸载

    public static func uninstall() async {
        _ = await runCommand("rm -f /usr/local/bin/codex /usr/bin/codex", timeout: 30)
    }
}
