import Foundation

/// 一个可安装的命令行工具：检查命令 + 安装脚本（脚本自己 echo 每一步，供界面回显）。
struct NanoMuseToolSpec: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let sizeHint: String
    /// 已安装时输出「版本」，未安装时无输出
    let checkCommand: String
    let installScript: String
}

/// 工具清单：Codex 本体 + 它干活常用的命令行工具。
/// 每项都能单独下载/安装，安装过程走 `NanoMuseCodex.runStreaming` 逐行回显。
enum NanoMuseTools {

    static var catalog: [NanoMuseToolSpec] {
        [
            NanoMuseToolSpec(
                id: "codex",
                title: "Codex",
                subtitle: "OpenAI 的编码 Agent，arm64 musl 官方包",
                sizeHint: "约 100 MB",
                checkCommand: "[ -x /usr/local/bin/codex ] && echo \"已装 $(stat -c %s /usr/local/bin/codex 2>/dev/null) bytes\" || true",
                installScript: NanoMuseCodex.installScript
            ),
            NanoMuseToolSpec(
                id: "base",
                title: "基础工具包",
                subtitle: "curl · wget · unzip · zip · jq · tar",
                sizeHint: "约 12 MB",
                checkCommand: "jq --version 2>&1",
                installScript: #"""
                set -u
                echo "STEP 1/2 安装 curl wget unzip zip jq tar ca-certificates"
                apk add --no-cache curl wget unzip zip jq tar ca-certificates 2>&1 | tail -8
                echo "STEP 2/2 验证"
                for t in curl wget unzip zip jq tar; do
                  if command -v $t >/dev/null 2>&1; then echo "  $t = $(command -v $t)"; else echo "  $t = 缺失"; fi
                done
                echo "  jq 版本 = $(jq --version 2>&1)"
                echo "STEP done"
                """#
            ),
            NanoMuseToolSpec(
                id: "git",
                title: "Git",
                subtitle: "版本控制，Codex 改仓库时要用",
                sizeHint: "约 15 MB",
                checkCommand: "git --version 2>&1",
                installScript: #"""
                set -u
                echo "STEP 1/2 安装 git"
                apk add --no-cache git 2>&1 | tail -8
                echo "STEP 2/2 验证"
                git --version 2>&1
                echo "STEP done"
                """#
            ),
            NanoMuseToolSpec(
                id: "python3",
                title: "Python 3",
                subtitle: "python3 + pip，跑脚本/测试",
                sizeHint: "约 45 MB",
                checkCommand: "python3 --version 2>&1",
                installScript: #"""
                set -u
                echo "STEP 1/3 安装 python3 + pip"
                apk add --no-cache python3 py3-pip 2>&1 | tail -8
                echo "STEP 2/3 升级 pip"
                python3 -m pip install --upgrade pip 2>&1 | tail -3 || true
                echo "STEP 3/3 验证"
                python3 --version 2>&1
                python3 -m pip --version 2>&1 || true
                echo "STEP done"
                """#
            ),
            NanoMuseToolSpec(
                id: "nodejs",
                title: "Node.js",
                subtitle: "node + npm，前端/脚本",
                sizeHint: "约 40 MB",
                checkCommand: "node --version 2>&1",
                installScript: #"""
                set -u
                echo "STEP 1/2 安装 nodejs + npm"
                apk add --no-cache nodejs npm 2>&1 | tail -8
                echo "STEP 2/2 验证"
                node --version 2>&1
                npm --version 2>&1 || true
                echo "STEP done"
                """#
            ),
            NanoMuseToolSpec(
                id: "build-base",
                title: "编译工具链",
                subtitle: "gcc/clang · make · musl-dev",
                sizeHint: "约 120 MB",
                checkCommand: "cc --version 2>&1 | head -1",
                installScript: #"""
                set -u
                echo "STEP 1/2 安装 build-base"
                apk add --no-cache build-base 2>&1 | tail -8
                echo "STEP 2/2 验证"
                cc --version 2>&1 | head -2
                make --version 2>&1 | head -1
                echo "STEP done"
                """#
            ),
            NanoMuseToolSpec(
                id: "openssh",
                title: "OpenSSH 客户端",
                subtitle: "ssh / scp，连自己的机器",
                sizeHint: "约 8 MB",
                checkCommand: "ssh -V 2>&1",
                installScript: #"""
                set -u
                echo "STEP 1/2 安装 openssh-client"
                apk add --no-cache openssh-client 2>&1 | tail -6
                echo "STEP 2/2 验证"
                ssh -V 2>&1
                echo "STEP done"
                """#
            ),
        ]
    }

    /// 查询某工具状态：有输出即已安装（输出就是版本行）
    static func status(of spec: NanoMuseToolSpec) async -> String? {
        // Codex 本体两条路线都算「已装」：只装了原生时，
        // Alpine 里那条 `[ -x /usr/local/bin/codex ]` 探针什么也不会输出。
        if spec.id == "codex", let native = NanoMuseCodex.nativeBinary() {
            let mb = native.size / 1048576
            var text = mb > 0 ? "原生 已装 \(mb) MB" : "原生 已装"
            if let version = NanoMuseCodex.cachedNativeVersion(path: native.path, size: native.size) {
                text += " · " + version
            }
            return text
        }
        let (_, output) = await NanoMuseCodex.runCommand("\(spec.checkCommand) 2>/dev/null || true", timeout: 60)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        // 这一页除 Codex 外都跑在 Alpine 里，标明来源，避免和「环境检测 → 运行时」同名混淆
        return "Alpine · " + first
    }
}
