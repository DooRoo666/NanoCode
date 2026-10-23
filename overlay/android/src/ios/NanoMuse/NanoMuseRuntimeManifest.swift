import Foundation

/// 原版 MT-Agent 的运行时体系（`CARuntimeManifestURL`）：
/// 一份 JSON 清单列出可安装的运行时包（codex / theos / ollvm / node / python …），
/// 每个包给出下载地址、大小、SHA256、安装布局（path_entries）与探测命令（probe）。
/// 清单里的 `download_proxy_prefixes` 用于 GitHub 直连失败时回退。
///
/// 本文件的职责：拉清单 → 解析 → 生成在 Alpine 里执行的安装脚本。
enum NanoMuseRuntimeManifest {

    /// 与原版一致；可在设置里覆盖
    static let defaultURL =
        "https://raw.githubusercontent.com/susu123oss/CodexApp-Runtime/main/Runtime/runtime-manifest.json"

    static let localStorageRoot = "/opt/runtimes"

    struct Package: Identifiable, Sendable {
        let id: String
        let displayName: String
        let group: String
        let archiveURL: String
        let sha256: String
        let sizeBytes: Int
        let pathEntries: [String]
        let probeArguments: [String]
        let probeContains: String?
        let capabilities: [String]

        var sizeText: String { String(format: "%.1f MB", Double(sizeBytes) / 1048576) }
    }

    struct Manifest: Sendable {
        let schema: Int
        let proxies: [String]
        let packages: [Package]
    }

    // MARK: - 拉取与解析

    static func fetch(urlString: String = defaultURL) async throws -> Manifest {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "NanoRuntime", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "清单地址无效"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw NSError(domain: "NanoRuntime", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "清单返回 HTTP \(status)"])
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Manifest {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "NanoRuntime", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "清单不是 JSON 对象"])
        }
        let proxies = (root["download_proxy_prefixes"] as? [String]) ?? []
        let schema = root["schema"] as? Int ?? 0
        guard let runtimes = root["runtimes"] as? [String: Any] else {
            throw NSError(domain: "NanoRuntime", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "清单缺少 runtimes"])
        }

        var packages: [Package] = []
        for (id, value) in runtimes {
            guard let entry = value as? [String: Any],
                  let archiveURL = entry["archive_url"] as? String else { continue }
            let install = entry["install"] as? [String: Any] ?? [:]
            let probe = install["probe"] as? [String: Any] ?? [:]
            packages.append(Package(
                id: id,
                displayName: entry["display_name"] as? String ?? id,
                group: entry["group"] as? String ?? "other",
                archiveURL: archiveURL,
                sha256: entry["archive_sha256"] as? String ?? "",
                sizeBytes: entry["download_size"] as? Int ?? 0,
                pathEntries: install["path_entries"] as? [String] ?? [],
                probeArguments: probe["arguments"] as? [String] ?? [],
                probeContains: probe["contains"] as? String,
                capabilities: Array((entry["capabilities"] as? [String: Any] ?? [:]).keys).sorted()
            ))
        }
        packages.sort { lhs, rhs in
            if lhs.group != rhs.group { return lhs.group < rhs.group }
            return lhs.sizeBytes < rhs.sizeBytes
        }
        return Manifest(schema: schema, proxies: proxies, packages: packages)
    }

    // MARK: - 安装脚本（在 Alpine 里跑，逐行回显）

    /// 生成一个包的自包含安装脚本：直连→代理回退下载、sha256 校验、解包、
    /// 归一化单层目录、写 PATH、跑 probe。
    static func installScript(_ package: Package, proxies: [String]) -> String {
        let attempts = ([""] + proxies).map { prefix in
            "\"\(prefix)\(package.archiveURL)\""
        }.joined(separator: " ")

        // 8 空格前缀与脚本里的缩进对齐，否则 Swift 多行字符串会报 insufficient indentation
        let pathLines = package.pathEntries.map { entry in
            "        [ -d \"$DEST/\(entry)\" ] && echo \"/opt/runtimes/\(package.id)/\(entry)\" >> \"$PATHS\""
        }.joined(separator: "\n")

        return #"""
        set -u
        ID="__ID__"; URL="__URL__"; SHA="__SHA__"
        DEST="/opt/runtimes/$ID"
        TMP="/tmp/rt-$ID.tgz"
        echo "STEP 1/5 准备目录"
        echo "  目标：$DEST"
        echo "  大小：__SIZE__"
        mkdir -p /opt/runtimes

        echo "STEP 2/5 下载（直连失败自动走代理）"
        rm -f "$TMP"
        OK=0
        for P in __ATTEMPTS__; do
          [ -z "$P" ] && echo "  尝试：直连" || echo "  尝试：${P%%github*}…"
          if curl -fL --retry 1 --connect-timeout 15 -o "$TMP" "$P"; then OK=1; break; fi
        done
        [ "$OK" = "1" ] || { echo "ERR 下载失败（直连与代理都不可用）"; exit 4; }
        SZ=$(stat -c %s "$TMP" 2>/dev/null || echo 0)
        echo "  实际下载：$SZ bytes"

        echo "STEP 3/5 校验 SHA256"
        GOT=$(sha256sum "$TMP" | cut -d' ' -f1)
        echo "  期望：$SHA"
        echo "  实际：$GOT"
        [ "$GOT" = "$SHA" ] || { echo "ERR sha256 不匹配，已丢弃"; rm -f "$TMP"; exit 5; }

        echo "STEP 4/5 解包到 $DEST"
        rm -rf "$DEST"; mkdir -p "$DEST"
        tar xzf "$TMP" -C "$DEST" || { echo "ERR 解包失败"; exit 6; }
        COUNT=$(ls -1 "$DEST" | wc -l | tr -d ' ')
        if [ "$COUNT" = "1" ] && [ ! -d "$DEST/bin" ]; then
          ONLY=$(ls -1 "$DEST")
          echo "  归一化单层目录：$ONLY"
          mv "$DEST/$ONLY"/* "$DEST"/ 2>/dev/null || true
          rmdir "$DEST/$ONLY" 2>/dev/null || true
        fi
        echo "  内容：$(ls -1 "$DEST" | head -6 | tr '\n' ' ')"
        rm -f "$TMP"

        echo "STEP 5/5 写入 PATH 并探测"
        PATHS="/etc/profile.d/nanocodex-paths.list"
        : > "$PATHS"
        __PATH_LINES__
        {
          echo "# 由 nanoCode 运行时安装器维护"
          echo 'export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"'
          if [ -f "$PATHS" ]; then
            while read -r p; do
              [ -n "$p" ] && echo "export PATH=\"\$PATH:$p\""
            done < "$PATHS"
          fi
        } > /etc/profile.d/nanocodex-runtimes.sh
        chmod 0644 /etc/profile.d/nanocodex-runtimes.sh
        echo "  PATH 片段：/etc/profile.d/nanocodex-runtimes.sh"
        __PROBE__
        echo "$SHA" > "$DEST/.installed"
        echo "  已记录 .installed"
        echo "STEP done"
        """#
            .replacingOccurrences(of: "__ID__", with: package.id)
            .replacingOccurrences(of: "__URL__", with: package.archiveURL)
            .replacingOccurrences(of: "__SHA__", with: package.sha256)
            .replacingOccurrences(of: "__SIZE__", with: package.sizeText)
            .replacingOccurrences(of: "__ATTEMPTS__", with: attempts)
            .replacingOccurrences(of: "__PATH_LINES__", with: pathLines)
            .replacingOccurrences(of: "__PROBE__", with: probeCommand(package: package))
    }

    private static func probeCommand(package: Package) -> String {
        guard let binary = package.probeArguments.first else { return "true" }
        let arguments = package.probeArguments.dropFirst().joined(separator: " ")
        // probe 的 arguments[0] 在清单里是二进制相对路径（如 bin/cmake）
        if binary.contains("/") {
            return "\"$DEST/\(binary)\" \(arguments)"
        }
        return "\"$DEST/bin/\(binary)\" \(arguments)"
    }

    // MARK: - 状态查询脚本

    static func statusScript(_ ids: [String]) -> String {
        let checks = ids.map { id in
            "if [ -f /opt/runtimes/\(id)/.installed ]; then echo \"\(id):installed\"; else echo \"\(id):absent\"; fi"
        }.joined(separator: "\n")
        return checks.isEmpty ? "true" : checks
    }

    /// 解析 `id:installed` 形式的输出
    static func parseStatus(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) == "installed"
        }
        return result
    }
}
