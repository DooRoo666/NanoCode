import Foundation

/// 在 nanoMuse 的 Alpine（aarch64）里安装并运行 Codex。
///
/// 为什么走 iSH 而不是原生 spawn：nanoMuse iOS 的 `iSH` 是 **ARM64 Linux**（rootfs 里的
/// busybox/apk 都是 ELF aarch64），而 codex 官方发布正好有
/// `codex-aarch64-unknown-linux-musl.tar.gz` —— 两者能直接对上。
/// 这样 Codex 就是一个普通 Linux 程序，不需要 entitlement、不需要交叉编译。
///
/// 现有运行时接口来自 `ISHShellExecutor.executeCommandSync`（ObjC，经桥接头暴露）。
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

    /// 官方发布的 aarch64 musl 资产（v0.163.0 起稳定存在）
    public static let downloadURL =
        "https://github.com/openai/codex/releases/latest/download/codex-aarch64-unknown-linux-musl.tar.gz"

    // MARK: - 基础

    private static func run(_ command: String) -> (Int32, String, String, TimeInterval) {
        let result = ISHShellExecutor.executeCommandSync(command)
        return (result.exitCode, result.output ?? "", result.errorOutput ?? "", result.duration)
    }

    /// 单引号转义，避免 prompt 里的字符被 shell 解释
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 状态

    public static func status() -> Status {
        let (code, out, err, _) = run(
            "command -v codex >/dev/null 2>&1 && codex --version 2>&1 || echo __MISSING__"
        )
        let merged = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 || merged.contains("__MISSING__") || merged.isEmpty {
            return Status(installed: false, version: nil, rawOutput: merged)
        }
        let version = merged.split(separator: " ").last.map(String.init)
        return Status(installed: true, version: version, rawOutput: merged)
    }

    // MARK: - 安装

    /// 下载并安装 codex 到 /usr/local/bin（rootfs 内持久化）。
    /// 幂等：已安装且版本可用时直接返回当前状态。
    @discardableResult
    public static func install(force: Bool = false) -> Status {
        if !force {
            let current = status()
            if current.installed { return current }
        }

        let script = """
        set -e
        ARCH=$(uname -m)
        if [ "$ARCH" != "aarch64" ]; then echo "unsupported arch: $ARCH"; exit 3; fi
        apk add --no-cache curl tar >/dev/null 2>&1 || true
        mkdir -p /usr/local/bin
        rm -f /tmp/codex.tgz
        curl -fL --retry 2 --connect-timeout 20 -o /tmp/codex.tgz \(downloadURL)
        tar xzf /tmp/codex.tgz -C /tmp
        # 资产可能把二进制放在根目录或子目录里
        BIN=$(find /tmp -maxdepth 3 -type f -name codex ! -path '*/node_modules/*' | head -1)
        [ -n "$BIN" ] || { echo "codex binary not found in archive"; exit 4; }
        install -m 0755 "$BIN" /usr/local/bin/codex
        rm -f /tmp/codex.tgz
        /usr/local/bin/codex --version
        """

        let (code, out, err, _) = run(script)
        let merged = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 0 {
            return Status(installed: false, version: nil, rawOutput: merged)
        }
        return status()
    }

    // MARK: - 运行

    /// 非交互执行一轮：`codex exec`。
    /// - Parameters:
    ///   - prompt: 任务描述
    ///   - workspace: Alpine 里的工作目录（默认 /root/work）
    ///   - apiKey: OpenAI（或兼容端点）密钥；为空则用 rootfs 里已有的环境变量
    ///   - baseURL: 兼容端点，例如自建网关；为空则用官方
    ///   - model: 模型名，可为空
    public static func execute(
        prompt: String,
        workspace: String = "/root/work",
        apiKey: String? = nil,
        baseURL: String? = nil,
        model: String? = nil,
        extraArgs: [String] = []
    ) -> RunResult {
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

        let (code, out, err, duration) = run(command)
        return RunResult(exitCode: code, output: out, errorOutput: err, duration: duration)
    }

    // MARK: - 卸载

    public static func uninstall() {
        _ = run("rm -f /usr/local/bin/codex")
    }
}
