import Foundation

/// 在 nanoMuse 的 Alpine（aarch64）里安装并运行 Codex，以及其它命令行工具。
///
/// 为什么走 iSH 而不是原生 spawn：nanoMuse iOS 的 iSH 是 **ARM64 Linux**
/// （rootfs 里的 busybox/apk 都是 ELF aarch64），codex 官方正好发布
/// `codex-aarch64-unknown-linux-musl`，两边能直接对上。
///
/// 所有安装都通过 `runStreaming` 执行：iSH 会逐行回调，界面因此能显示
/// 「第几步 / 下载百分比 / 字节数 / SHA256 / ELF 头 / 版本」这些完整回显。
public enum NanoMuseCodex {

    public struct Status: Sendable {
        public let installed: Bool
        public let version: String?
        public let rawOutput: String
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

    /// 安装目标路径（rootfs 内持久化）
    public static let binaryPath = "/usr/local/bin/codex"

    // MARK: - 统一执行入口（异步 + 流式，避免阻塞与死锁）

    /// 用 iSH 的流式接口跑一段脚本，等待结束后一次性返回退出码与完整输出。
    /// 为什么不用 `executeCommandSync`：上游各版本的参数不一致（有的带 timeout、
    /// 有的 `output` 非可选），而且是同步阻塞 + 回调在主队列，从主线程调用会死锁。
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
                timeout: timeout,
                lineCallback: { line, _ in
                    lock.lock(); lines.append(line); lock.unlock()
                },
                completion: { result in
                    lock.lock()
                    guard !finished else { lock.unlock(); return }
                    finished = true
                    let collected = lines
                    lock.unlock()
                    continuation.resume(returning: (result?.exitCode ?? -1, collected.joined(separator: "\n")))
                }
            )
        }
    }

    public static func status() async -> Status {
        let (code, out) = await runCommand(
            "command -v codex >/dev/null 2>&1 && codex --version 2>&1 || echo __MISSING__",
            timeout: 60
        )
        let merged = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 || merged.contains("__MISSING__") || merged.isEmpty {
            return Status(installed: false, version: nil, rawOutput: merged)
        }
        let version = merged.split(separator: " ").last.map(String.init)
        return Status(installed: true, version: version, rawOutput: merged)
    }

    // MARK: - 流式执行（安装/下载，界面显示回显）

    /// 跑一段脚本，逐行回调。返回是否成功拿到进程号。
    /// `lineCallback` / `completion` 都在主队列，界面可直接写 @State。
    @discardableResult
    public static func runStreaming(
        _ script: String,
        timeout: TimeInterval = 1800,
        onLine: @escaping (String) -> Void,
        onFinish: @escaping (Bool) -> Void
    ) -> Bool {
        let pid = ISHShellExecutor.executeCommand(
            script,
            timeout: timeout,
            lineCallback: { line, _ in onLine(line) },
            completion: { result in onFinish((result?.exitCode ?? -1) == 0) }
        )
        return pid > 0
    }

    /// 跑一段脚本并等待结束（无逐行回调时用）
    @discardableResult
    public static func runStreamingAwait(_ script: String, timeout: TimeInterval = 1800) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            _ = runStreaming(script, timeout: timeout, onLine: { _ in }, onFinish: { ok in
                continuation.resume(returning: ok)
            })
        }
    }

    // MARK: - Codex 安装脚本（带完整回显）

    /// 每一步都 `echo STEP …`：架构 → 依赖 → 下载 → 校验 → 解包 → 安装 → 验证。
    /// 校验段打印 tarball 与二进制的 SHA256、ELF 头、文件类型，
    /// 并明确说明「Linux 二进制不需要 iOS 代码签名」——避免把 ldid 误用到 ELF 上。
    public static var installScript: String {
        #"""
        set -u
        STEP=0
        say() { echo "STEP $1"; }
        fail() { echo "ERR $1"; exit 1; }

        say "1/7 检查环境"
        ARCH=$(uname -m)
        echo "  uname -m = $ARCH"
        echo "  shell    = $0"
        [ "$ARCH" = "aarch64" ] || fail "需要 aarch64 的 Alpine，当前是 $ARCH"
        echo "  内存/磁盘："
        df -h / | tail -1
        free -m 2>/dev/null | head -2 || true

        say "2/7 安装下载依赖 (curl tar)"
        apk add --no-cache curl tar 2>&1 | tail -3 || true
        command -v curl >/dev/null 2>&1 || fail "curl 安装失败"
        command -v tar  >/dev/null 2>&1 || fail "tar 安装失败"
        echo "  curl = $(curl --version | head -1)"

        say "3/7 读取远端包大小"
        URL="__URL__"
        echo "  url = $URL"
        TOTAL=$(curl -sIL "$URL" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v+0}')
        [ -n "${TOTAL:-}" ] || TOTAL=0
        echo "  content-length = $TOTAL bytes"

        say "4/7 下载（每秒回报字节数）"
        rm -f /tmp/codex.tgz
        curl -fL --retry 2 --connect-timeout 20 -o /tmp/codex.tgz "$URL" &
        CPID=$!
        while kill -0 $CPID 2>/dev/null; do
          SZ=$(stat -c %s /tmp/codex.tgz 2>/dev/null || echo 0)
          echo "BYTES $SZ $TOTAL"
          sleep 1
        done
        wait $CPID || fail "下载失败"
        SZ=$(stat -c %s /tmp/codex.tgz 2>/dev/null || echo 0)
        echo "BYTES $SZ $TOTAL"
        echo "  实际大小 = $SZ bytes"
        [ "$SZ" -gt 1000000 ] || fail "下载内容过小（$SZ bytes），可能被拦截"

        say "5/7 校验 tarball"
        echo "  sha256(tgz) = $(sha256sum /tmp/codex.tgz | cut -d' ' -f1)"
        gzip -t /tmp/codex.tgz 2>/dev/null && echo "  gzip 完整性 = OK" || fail "gzip 校验失败"

        say "6/7 解包并安装到 /usr/local/bin"
        rm -rf /tmp/codex-pkg && mkdir -p /tmp/codex-pkg
        tar xzf /tmp/codex.tgz -C /tmp/codex-pkg || fail "解包失败"
        echo "  解包内容："
        find /tmp/codex-pkg -maxdepth 2 -type f | head -8 | sed 's/^/    /'
        BIN=$(find /tmp/codex-pkg -maxdepth 3 -type f -name codex | head -1)
        [ -n "${BIN:-}" ] || fail "压缩包里找不到 codex 可执行文件"
        echo "  找到 = $BIN"
        echo "  sha256(bin) = $(sha256sum "$BIN" | cut -d' ' -f1)"
        echo "  ELF 头 (前16字节)：$(od -An -tx1 -N16 "$BIN" | tr -s ' ')"
        mkdir -p /usr/local/bin
        install -m 0755 "$BIN" /usr/local/bin/codex || fail "写入 /usr/local/bin/codex 失败"
        echo "  安装后权限：$(ls -l /usr/local/bin/codex)"
        echo "  说明：这是 Linux ELF 程序，靠 Alpine 的内核接口运行，不需要 iOS 代码签名（ldid 只对 Mach-O 有意义）。"
        rm -rf /tmp/codex-pkg /tmp/codex.tgz

        say "7/7 验证"
        if /usr/local/bin/codex --version; then
          echo "  版本可用"
        else
          echo "  警告：codex --version 失败，可能是 iSH 的 syscall 覆盖不足（程序会保留在 /usr/local/bin 供排查）"
        fi
        say "done"
        """#
            .replacingOccurrences(of: "__URL__", with: downloadURL)
    }

    // MARK: - 同步安装（工具内部使用，无回显）

    @discardableResult
    public static func install(force: Bool = false) async -> Status {
        await runStreamingAwait(installScript, timeout: 1800)
        return await status()
    }

    // MARK: - 运行

    public static func execute(
        prompt: String,
        workspace: String = "/root/work",
        apiKey: String? = nil,
        baseURL: String? = nil,
        model: String? = nil,
        extraArgs: [String] = [],
        timeout: TimeInterval = 900
    ) async -> RunResult {
        var env: [String] = []
        if let apiKey, !apiKey.isEmpty { env.append("export OPENAI_API_KEY=\(quote(apiKey))") }
        if let baseURL, !baseURL.isEmpty { env.append("export OPENAI_BASE_URL=\(quote(baseURL))") }
        if let model, !model.isEmpty { env.append("export CODEX_MODEL=\(quote(model))") }

        var args = ["exec", "--skip-git-repo-check"]
        args.append(contentsOf: extraArgs)
        let command = """
        mkdir -p \(quote(workspace))
        \(env.joined(separator: "\n"))
        cd \(quote(workspace)) && codex \(args.joined(separator: " ")) \(quote(prompt)) 2>&1
        """

        let (code, out) = await runCommand(command, timeout: timeout)
        return RunResult(exitCode: code, output: out, errorOutput: "", duration: 0)
    }

    /// 单引号转义，避免 prompt 里的字符被 shell 解释
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 卸载

    public static func uninstall() async {
        _ = await runCommand("rm -f /usr/local/bin/codex", timeout: 30)
    }
}
