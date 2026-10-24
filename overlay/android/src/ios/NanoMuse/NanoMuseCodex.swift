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
        public let nativeVersion: String?
        public let rawOutput: String

        public var installed: Bool {
            alpinePath != nil || nativePath != nil || (!NanoMuseNativeRuntime.installedIDs().isEmpty)
        }

        /// codex_exec 实际会用的那条路（原生优先于"装了但跑不起来"的 Alpine）
        public var activeRoute: String? {
            if alpinePath != nil, alpineRuns { return "Alpine" }
            if nativePath != nil { return "原生" }
            if alpinePath != nil { return "Alpine（但跑不起来）" }
            return nil
        }

        /// 当前实际会用的那条路的版本号
        public var version: String? {
            if activeRoute == "Alpine" { return alpineVersion ?? nativeVersion }
            if activeRoute == "原生" { return nativeVersion ?? alpineVersion }
            return nativeVersion ?? alpineVersion
        }

        private func sizeLabel(_ bytes: Int) -> String {
            bytes > 0 ? "\(bytes / 1048576) MB" : "已装"
        }

        /// 卡片首行：先说结论，再说细节。
        /// **绝不以「Alpine 未装」开头**——只装了原生时那不是问题，是正常状态。
        public var headline: String {
            if nativePath != nil, nativeRuns { return "已就绪 · 原生" }
            if alpinePath != nil, alpineRuns { return "已就绪 · Alpine" }
            if nativePath != nil { return "已安装 · 待验证" }
            if alpinePath != nil { return "已安装 · 不可运行" }
            if (!NanoMuseNativeRuntime.installedIDs().isEmpty) { return "已安装 · 待验证" }
            return "未安装"
        }

        /// 「已装」说明：只写实际存在的那几条，缺失的那条不再当成错误提示。
        public var summary: String {
            var parts: [String] = [installLine]
            if let route = activeRoute {
                parts.append("Agent 走 " + route)
            }
            if let version, !version.isEmpty {
                parts.append(version)
            }
            return parts.joined(separator: " · ")
        }

        /// 只描述「装了什么」，不含路由与版本（给卡片单独一行用）
        public var installLine: String {
            var parts: [String] = []
            if let nativePath {
                parts.append("原生 \(sizeLabel(nativeSize))\(nativeRuns ? " 可运行" : " 未验证")")
                _ = nativePath
            }
            if alpinePath != nil {
                parts.append("Alpine \(sizeLabel(alpineSize))\(alpineRuns ? " 可运行" : " 不可运行")")
            }
            if parts.isEmpty {
                // 目录里有东西但扫不到可执行文件
                if (!NanoMuseNativeRuntime.installedIDs().isEmpty) {
                    return "原生 目录已有内容，未找到可执行 codex"
                }
                return "未安装"
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

    /// 面板构建标记：装完新包先看这一行，确认跑的是新代码
    public static let buildTag = "r5"

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

    // MARK: - 原生二进制与探测

    /// 在运行目录里找 codex 主程序。
    /// **不依赖 .installed 标记**：标记在容器迁移/中断安装时会丢，
    /// 会造成"能跑却显示未装"。以内容为准。
    /// 同时扫 `NanoCodex/` 与 `NanoCodex/runtimes/` 两处，布局变化也不会漏。
    static func nativeBinary() -> (path: String, size: Int)? {
        let fm = FileManager.default
        var roots: [URL] = [NanoMuseNativeRuntime.rootDirectory]
        roots.append(NanoMuseNativeRuntime.rootDirectory.deletingLastPathComponent())

        var seen = Set<String>()
        var candidates: [(path: String, size: Int)] = []
        for root in roots {
            guard let enumerator = fm.enumerator(at: root,
                                                 includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                 options: []) else { continue }
            for case let url as URL in enumerator {
                guard url.lastPathComponent == "codex" else { continue }
                guard seen.insert(url.path).inserted else { continue }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                let size = values?.fileSize ?? 0
                // 没执行位也算「已装」——大小对得上就是那份二进制，安装流程会补 chmod
                let executable = fm.isExecutableFile(atPath: url.path)
                if !executable, size < 1_048_576 { continue }
                candidates.append((url.path, size))
            }
        }
        // deb 里 usr/bin/codex 是 52 KB 启动器（硬编码 /var/jb），
        // 真二进制在 usr/libexec/codex/codex（235 MB）→ 取最大的
        return candidates.max(by: { $0.size < $1.size })
    }

    /// 探测缓存戳：路径 + 大小 + 修改时间（签名后 mtime 变化会自动重探）
    private static func stamp(for path: String, size: Int) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(path)|\(size)|\(Int(mtime))"
    }

    /// 原生 codex 能否真的运行
    static func nativeProbe(force: Bool = false) async -> (runs: Bool, version: String?) {
        guard let binary = nativeBinary() else { return (false, nil) }
        let current = stamp(for: binary.path, size: binary.size)
        let key = "nanocodex.nativeProbe"
        if !force,
           let saved = UserDefaults.standard.dictionary(forKey: key),
           saved["stamp"] as? String == current,
           let runs = saved["runs"] as? Bool {
            return (runs, saved["version"] as? String)
        }
        let result = await Task.detached(priority: .utility) {
            NanoMuseHelperRunner.run(binary.path, arguments: ["--version"], timeout: 30)
        }.value
        let version = result.output
            .split(separator: "\n")
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        UserDefaults.standard.set(
            ["stamp": current, "runs": result.exitCode == 0, "version": version ?? ""],
            forKey: key
        )
        return (result.exitCode == 0, version)
    }

    /// 安装流程结束时写入已知结果，省掉一次 235 MB 进程启动
    static func rememberNativeProbe(binaryPath: String, runs: Bool, version: String?) {
        let size = (try? FileManager.default.attributesOfItem(atPath: binaryPath)[.size] as? Int) ?? 0
        UserDefaults.standard.set(
            ["stamp": stamp(for: binaryPath, size: size),
             "runs": runs,
             "version": version ?? ""],
            forKey: "nanocodex.nativeProbe"
        )
    }

    /// 缓存里已知的原生版本（不启动进程，供工具列表即时显示）
    static func cachedNativeVersion(path: String, size: Int) -> String? {
        guard let saved = UserDefaults.standard.dictionary(forKey: "nanocodex.nativeProbe"),
              saved["stamp"] as? String == stamp(for: path, size: size),
              (saved["runs"] as? Bool) == true,
              let value = saved["version"] as? String,
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: - 状态（分位置判定）

    public static func status() async -> Status {
        let script = #"""
        echo "PATH=$PATH"
        if [ -x /usr/local/bin/codex ]; then
          echo "ALPINE_PATH=/usr/local/bin/codex"
          echo "ALPINE_SIZE=$(stat -c %s /usr/local/bin/codex 2>/dev/null || echo 0)"
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
            guard let last = value.split(separator: " ").last.map(String.init), !value.isEmpty else { return nil }
            return last
        }

        let native = nativeBinary()
        // 扫到了但没执行位（复制/解包时丢权限）→ 补上，否则会误判成"不可运行"
        if let native, !FileManager.default.isExecutableFile(atPath: native.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: native.path)
        }
        let probe = await nativeProbe()

        return Status(
            alpinePath: alpinePath,
            alpineSize: alpineSize,
            alpineRuns: alpineRuns,
            alpineVersion: alpineRuns ? alpineVersion : nil,
            nativePath: native?.path,
            nativeSize: native?.size ?? 0,
            nativeRuns: probe.runs,
            nativeVersion: probe.runs ? probe.version : nil,
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

    // MARK: - 签名诊断（把 rc 变成证据）

    /// 三个探针，定位「codex-sign 到底死在哪」：
    ///   ① 包内 bash.real 能不能跑（验证 in-bundle ad-hoc 是否被接受）
    ///   ② 包内 codex-sign 能不能跑（验证它自己的签名）
    ///   ③ 把 codex-sign 复制到 App 容器再跑（验证是否与路径有关）
    public static func signDiagnostics() async -> String {
        var lines: [String] = []

        let root = NanoMuseNativeRuntime.rootDirectory
        let codexDir = NanoMuseNativeRuntime.directory(for: "codex")
        let marker = codexDir.appendingPathComponent(".installed")
        lines.append("[0] runtimes = \(root.path)")
        lines.append("    codex 目录存在=\(FileManager.default.fileExists(atPath: codexDir.path)) 标记=\(FileManager.default.fileExists(atPath: marker.path))")
        let top = (try? FileManager.default.contentsOfDirectory(atPath: codexDir.path)) ?? []
        lines.append("    顶层：\(top.prefix(6).joined(separator: ", "))")

        let bash = NanoMuseHelperRunner.run("bash.real",
                                            arguments: ["-c", "echo bash-ok; id -u"],
                                            timeout: 20)
        lines.append("[1] 包内 bash.real rc=\(bash.exitCode)")
        lines.append("    " + bash.output.split(separator: "\n").prefix(2).joined(separator: " | "))

        let help = NanoMuseHelperRunner.run("codex-sign", arguments: ["--help"], timeout: 20)
        lines.append("[2] 包内 codex-sign --help rc=\(help.exitCode)")
        lines.append("    " + help.output.split(separator: "\n").prefix(2).joined(separator: " | "))

        let home = codexHome()
        let copy = home.appendingPathComponent("codex-sign-copy")
        let source = Bundle.main.bundlePath + "/Helpers/codex-sign"
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(atPath: source, toPath: copy.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path)
            let run = NanoMuseHelperRunner.run(copy.path, arguments: ["--help"], timeout: 20)
            lines.append("[3] 容器内 codex-sign --help rc=\(run.exitCode)")
            lines.append("    " + run.output.split(separator: "\n").prefix(2).joined(separator: " | "))
        } catch {
            lines.append("[3] 复制失败：\(error.localizedDescription)")
        }

        if let binary = nativeBinary() {
            let probe = NanoMuseHelperRunner.run(binary.path, arguments: ["--version"], timeout: 30)
            lines.append("[4] codex 主程序 rc=\(probe.exitCode)  \(binary.size / 1048576) MB")
            lines.append("    " + probe.output.split(separator: "\n").prefix(3).joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 权限探针（原生 vs iSH 对照）

    /// 由 Minis 本体 posix_spawn 出来的 bash：能看到宿主 App 的沙盒边界。
    public static var nativePermissionScript: String {
        #"""
        echo "=== 原生进程（Minis 直接 posix_spawn）==="
        echo "uid:gid      = $(id -u 2>/dev/null):$(id -g 2>/dev/null)"
        echo "uname        = $(uname -a 2>/dev/null)"
        echo "HOME         = $HOME"
        probe() {
          if [ -e "$1" ]; then
            if [ -r "$1" ]; then echo "  可读    $1"; else echo "  存在但被拒 $1"; fi
          else
            echo "  不存在  $1"
          fi
        }
        probe /private/var/mobile
        probe /private/var/mobile/Library/Preferences
        probe /System/Library/CoreServices/SystemVersion.plist
        probe /dev/disk0
        probe /dev/kmem
        echo "--- 列 /private/var/mobile/Containers ---"
        if ls /private/var/mobile/Containers >/dev/null 2>&1; then echo "  可以列（宿主权限生效）"; else echo "  被拒（errno=$?）"; fi
        echo "--- 写 /private/var/mobile/Library/Preferences ---"
        if (echo probe > /private/var/mobile/Library/Preferences/nanocodex-probe 2>/dev/null); then
          echo "  可写（宿主权限生效）"; rm -f /private/var/mobile/Library/Preferences/nanocodex-probe
        else
          echo "  被拒（errno=$?）"
        fi
        echo "=== 结束 ==="
        """#
    }

    /// iSH 里的 Linux 进程：fake fs + 自造 /proc，宿主权限不进来。
    public static var alpinePermissionScript: String {
        #"""
        echo "=== iSH 内的 Linux 进程 ==="
        echo "uname        = $(uname -a 2>/dev/null)"
        echo "/proc/version= $(cat /proc/version 2>/dev/null)"
        echo "uid:gid      = $(id -u 2>/dev/null):$(id -g 2>/dev/null)"
        probe() {
          if [ -e "$1" ]; then
            if [ -r "$1" ]; then echo "  可读    $1"; else echo "  存在但被拒 $1"; fi
          else
            echo "  不存在  $1"
          fi
        }
        probe /private/var/mobile
        probe /private/var/mobile/Library/Preferences
        probe /dev/disk0
        probe /dev/kmem
        probe /etc/alpine-release
        echo "--- 宿主设备节点 ---"
        ls /dev | head -8 | sed 's/^/  \/dev\//'
        echo "=== 结束：以上是 fake fs 的视图，宿主 entitlements 不作用于本进程 ==="
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

        // 原生二进制：只要 Alpine 那条「装了但跑不起来」，就直接用原生。
        // 否则会出现：Alpine 的 musl 程序一跑就崩，codex_exec 却一直往那条路走。
        let alpineUsable = (current.alpinePath != nil) && current.alpineRuns
        if !alpineUsable, let native = nativeBinary() {
            // `exec` 默认是 read-only 沙箱（在 macOS 上走 seatbelt，iOS 没有这层，
            // 结果就是命令跑不动、写不了文件 → 看起来"能起但读不到系统数据"）。
            // 这个 App 本身就是边界（TrollStore 带 no-sandbox / platform-application），
            // 所以显式关掉 codex 自己的沙箱与审批。已在该二进制里核对过此 flag 存在。
            var args = ["exec"]
            // 有 baseURL + key 时显式声明 provider：不声明 codex 会打到 api.openai.com，
            // 在没有 ChatGPT 登录的情况下必然 401——这就是"链路通了但没 key"的现场。
            if let apiKey, let baseURL, !apiKey.isEmpty, !baseURL.isEmpty {
                let provider = "nanomuse"
                args.append(contentsOf: [
                    "-c", "model_provider=\"\(provider)\"",
                    "-c", "model_providers.\(provider).name=\"nanoMuse\"",
                    "-c", "model_providers.\(provider).base_url=\"\(baseURL)\"",
                    "-c", "model_providers.\(provider).env_key=\"OPENAI_API_KEY\"",
                    "-c", "model_providers.\(provider).wire_api=\"\(NanoMuseCodexSettings.wireAPI)\"",
                ])
                if let model, !model.isEmpty { args.append(contentsOf: ["-m", model]) }
            }
            args.append("--dangerously-bypass-approvals-and-sandbox")
            args.append("--skip-git-repo-check")
            args.append(contentsOf: extraArgs)
            args.append(effectivePrompt)

            var env: [String: String] = [:]
            let home = codexHome()
            env["CODEX_HOME"] = home.path
            env["HOME"] = home.path
            // 预先备好 codex 会去放 PATH 别名的那几个目录，
            // 免得它每次启动都因为建不了目录而打一行 WARNING。
            for sub in ["bin", ".local/bin", ".codex/bin", ".cache"] {
                try? FileManager.default.createDirectory(at: home.appendingPathComponent(sub),
                                                         withIntermediateDirectories: true)
            }
            // codex 执行命令要靠 shell；iOS 上没有 /bin/sh。
            // 把随包的 bash.real 以 bash / sh 两个名字软链进容器的 bin/，并置于 PATH 前。
            let binDir = home.appendingPathComponent("bin", isDirectory: true)
            let bashPath = NanoMuseHelperRunner.path("bash.real")
            if FileManager.default.isExecutableFile(atPath: bashPath) {
                for alias in ["bash", "sh"] {
                    let linkPath = binDir.appendingPathComponent(alias).path
                    if !FileManager.default.fileExists(atPath: linkPath) {
                        try? FileManager.default.createSymbolicLink(atPath: linkPath,
                                                                   withDestinationPath: bashPath)
                    }
                }
            }
            env["PATH"] = [
                binDir.path,
                NanoMuseHelperRunner.helpersDirectory,
                "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            ].joined(separator: ":")
            syncAuthFromAlpine(into: home)
            if let apiKey, !apiKey.isEmpty { env["OPENAI_API_KEY"] = apiKey }
            if let baseURL, !baseURL.isEmpty { env["OPENAI_BASE_URL"] = baseURL }
            if let model, !model.isEmpty { env["CODEX_MODEL"] = model }

            // iOS 没有 posix_spawn 的 chdir，用随包的 bash 包一层设置工作目录。
            // `/root/work` 这类 Linux 路径在 iOS 上建不出来，落到容器里的 work 目录。
            var effectiveWorkspace = workspace
            if !FileManager.default.fileExists(atPath: effectiveWorkspace) {
                var created = true
                do {
                    try FileManager.default.createDirectory(atPath: effectiveWorkspace,
                                                            withIntermediateDirectories: true)
                } catch {
                    created = false
                }
                if !created {
                    let fallback = codexHome().appendingPathComponent("work", isDirectory: true)
                    try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
                    effectiveWorkspace = fallback.path
                }
            }
            let runDir = effectiveWorkspace
            let runEnv = env
            func commandLine(_ arguments: [String]) -> String {
                "cd \(quote(runDir)) 2>/dev/null || cd \(quote(codexHome().path)); "
                    + "exec \(quote(native.path)) " + arguments.map { quote($0) }.joined(separator: " ")
            }
            func runOnce(_ arguments: [String]) async -> NanoMuseHelperRunner.Result {
                let command = commandLine(arguments)
                return await Task.detached(priority: .userInitiated) {
                    NanoMuseHelperRunner.run("bash.real",
                                             arguments: ["-lc", command],
                                             timeout: timeout,
                                             extraEnvironment: runEnv)
                }.value
            }

            var result = await runOnce(args)
            // 网关只支持 chat 而不支持 responses（或反过来）时，换一种 wire_api 再试一次
            if result.exitCode != 0, Self.looksLikeWireMismatch(result.output) {
                let other = NanoMuseCodexSettings.wireAPI == "responses" ? "chat" : "responses"
                var retryArgs = args
                if let index = retryArgs.firstIndex(where: { $0.contains("wire_api=") }) {
                    retryArgs[index] = "model_providers.nanomuse.wire_api=\"\(other)\""
                    result = await runOnce(retryArgs)
                }
            }
            // PATH 别名那条 WARNING 无害（退出码仍是 0），别让它混进 Agent 看到的结果里
            let cleaned = result.output
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.contains("PATH aliases") }
                .joined(separator: "\n")
            return RunResult(exitCode: result.exitCode, output: cleaned,
                             errorOutput: "", duration: result.duration)
        }

        // 到这里只剩 Alpine 路线；若它也不在，给出可操作的错误
        guard current.alpinePath != nil else {
            return RunResult(exitCode: 127,
                             output: """
                             没有可用的 codex（App 容器与 Alpine 里都没找到可执行文件）：
                               · 点「原生安装（推荐）」把 iphoneos-arm64 包解到 App 容器
                               · 或点「Alpine 安装」装 Linux 版
                             装完点「重新检测」确认状态。
                             """,
                             errorOutput: "", duration: 0)
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

    /// 原生 codex 的 HOME：`Application Support/NanoCodex/codex-home`
    static func codexHome() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let home = base.appendingPathComponent("NanoCodex/codex-home", isDirectory: true)
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// 把 iSH 里 `codex login` 写下的 auth.json 搬给原生 codex 用。
    /// （两个世界的 HOME 不同，不搬的话原生端永远处于未登录状态。）
    static func syncAuthFromAlpine(into home: URL) {
        let target = home.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: target.path) { return }
        let source = RootfsManager.shared.dataPath
            .appendingPathComponent("root/.codex/auth.json")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: target)
    }

    /// 单引号转义，避免 prompt 里的字符被 shell 解释
    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 输出像"这个网关不认当前 wire_api / 端点不存在"时返回 true，供换协议重试一次
    private static func looksLikeWireMismatch(_ text: String) -> Bool {
        let lowered = text.lowercased()
        for needle in ["wire_api", "unknown variant", "unsupported", "not supported",
                       "404", "405", "not found"] {
            if lowered.contains(needle) { return true }
        }
        return false
    }

    // MARK: - 卸载

    public static func uninstall() async {
        _ = await runCommand("rm -f /usr/local/bin/codex /usr/bin/codex", timeout: 30)
    }
}
