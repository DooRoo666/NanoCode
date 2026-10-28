import Foundation
import CryptoKit
import Combine

/// 原生运行时安装器（对齐 MT-Agent 的真实形态）。
///
/// 为什么需要它：原版清单里的包是 **iOS 原生** 产物——
///   · codex 的 asset 是 `wiki.qaq.codex_…_iphoneos-arm64.deb`
///   · theos 带 `iPhoneOS16.5.sdk`，解包 934 MB
///   · node 的持久路径是 `Library/Application Support/CodexApp/Node/prefix/bin`
/// 这些是 Mach-O，塞进 Alpine（Linux ELF 环境）跑不起来，必须解到 App 容器里、
/// 由 `NanoMuseHelperRunner` 用 posix_spawn 起。
enum NanoMuseNativeRuntime {

    /// 安装日志：MainActor 隔离 + @Published，界面直接观察，避免跨线程改 @State。
    @MainActor
    final class Log: ObservableObject {
        @Published private(set) var lines: [String] = []
        /// 0…1；nil = 不确定进度
        @Published private(set) var progress: Double?
        /// 当前阶段文案（STEP / 下载中 12.3 / 95.0 MB）
        @Published private(set) var phase: String = ""

        func setProgress(_ value: Double?) { progress = value }
        func setPhase(_ text: String) { phase = text }

        func add(_ line: String) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            lines.append(trimmed)
            if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        }

        func clear() {
            lines.removeAll()
            progress = nil
            phase = ""
        }
    }

    struct Installed: Sendable {
        let id: String
        let root: String
        let installedAt: Date
    }

    /// 运行时根目录：**优先放在自己的 .app 里**（和 MT-Agent 一致）。
    ///
    /// 这是"下载了能用"的关键：iOS 只信任安装时被 TrollStore 签进 .app 的 Mach-O。
    /// 放在 Library/ 里的二进制即使符号链接正确，dyld 也会拒绝加载它依赖的私有 dylib
    /// （实测 clang 就死在这里，而 tar/sed/make/ld64/perl 因为只吃系统库才活着）。
    /// 所以能写 .app 就写 .app，写不进才退回 Application Support。
    static var rootDirectory: URL {
        let bundled = URL(fileURLWithPath: Bundle.main.bundlePath)
            .appendingPathComponent("Runtimes", isDirectory: true)
        if probeWritable(bundled) {
            return bundled
        }
        // 包内不可写时，落到「本 App 自己的数据容器」——这是唯一能装可执行代码、
        // dylib 不会被拦的位置。之前落到 ~/Library/Application Support（带 no-container
        // 时就是 /var/mobile/Library/…，其实是系统目录、不属于任何容器），
        // 所以 Python.framework 一加载就被判 sandbox blocked mmap()。
        if let container = ownContainerURL {
            let dir = container
                .appendingPathComponent("Library/Application Support/NanoCodex/runtimes", isDirectory: true)
            if probeWritable(dir) { return dir }
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("NanoCodex/runtimes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 通过容器元数据找到本 App 的 Data 容器（bundleIdentifier 匹配）。
    /// 带 no-container 权限时 NSHomeDirectory() 是 /var/mobile，靠它拿不到容器。
    static var ownContainerURL: URL? {
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        guard !bundleID.isEmpty else { return nil }
        let base = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: base,
                                                                    includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let meta = dir.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: meta),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: Any],
                  (dict["MCMMetadataIdentifier"] as? String) == bundleID else { continue }
            return dir
        }
        return nil
    }

    /// **真写一次**再判定。不能用 `isWritableFile`：
    /// 包里目录是 33:33/755，POSIX 判定必然 false，但 App 的
    /// `com.apple.private.security.storage.AppBundles` 沙盒扩展允许它真的写进去
    /// （MT-Agent 的 PythonRuntime/TheosRuntime 就是这么以 501 属主建出来的）。
    private static func probeWritable(_ dir: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let probe = dir.appendingPathComponent(".write-probe")
        guard (try? Data(UUID().uuidString.utf8).write(to: probe, options: .atomic)) != nil else {
            return false
        }
        try? fm.removeItem(at: probe)
        return true
    }

    /// 运行时根落在包内还是数据容器（MT-Agent 是包内）。
    static var rootIsBundled: Bool {
        probeWritable(URL(fileURLWithPath: Bundle.main.bundlePath)
            .appendingPathComponent("Runtimes", isDirectory: true))
    }

    /// 极短标签，给行值用（行值会被单行中部省略）。
    static var rootLocationLabel: String {
        rootIsBundled ? "包内 Runtimes" : "本 App 容器"
    }

    /// 完整解释：为什么没进包内、怎么改回包内。放卡片下方，可换行。
    static var rootLocationNote: String {
        if rootIsBundled {
            return "运行时装在 App 包内 Runtimes/，与 MT-Agent 一致，dylib 不会被沙箱拦。"
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: Bundle.main.bundlePath)
        let owner = (attrs?[.ownerAccountName] as? String) ?? "?"
        let mode = (attrs?[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let path = (rootDirectory.path as NSString).abbreviatingWithTildeInPath
        return String(format: "App 包不可写（属主 %@ / 0%o），运行时只能落在 %@。包外的 dylib 会被 iOS 拦（sandbox blocked mmap / code signature invalid），所以 Python 这类带 framework 的运行时装完也跑不起来。用 TrollStore 重装本 App（让包体归 mobile 所有）就能改回包内。", owner, mode, path)
    }

    static func directory(for id: String) -> URL {
        rootDirectory.appendingPathComponent(id, isDirectory: true)
    }

    static func isInstalled(_ id: String) -> Bool {
        let dir = directory(for: id)
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".installed").path) {
            return true
        }
        // 标记丢失但内容还在（容器迁移、中断安装）→ 以内容为准
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return !contents.isEmpty
    }

    static func installedIDs() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)) ?? []
        let ids = contents.filter { isInstalled($0) }
        if ids.contains("python") {
            healPythonSupportIfNeeded()
        }
        return ids
    }

    // MARK: - Python 运行时的支撑文件（sitecustomize / CA 证书 / pip）

    /// iOS 版 CPython 有三个开箱即坏的点，实测全部可以在 site-packages 里补掉：
    /// 1. `subprocess` / `os.fork` 在该 build 被编译成直接 ENOTSUP —— 用 posix_spawn 顶替
    ///    （父进程不 fork，只是在子进程里 exec，TrollStore 环境允许）；
    /// 2. 没有任何系统 CA 证书，`urllib` 一访问 https 就 CERTIFICATE_VERIFY_FAILED —— 随包
    ///    的 cacert.pem 落到 site-packages 并由补丁自动设 SSL_CERT_FILE；
    /// 3. `platform.uname()` 要走 objc 桥，DeviceKit 返回 nil 就抛异常，pip / setuptools
    ///    一调就崩 —— 固定成 Darwin/arm64。
    /// 补完之后 pip、requests 这类纯 Python 包都能正常用。
    private static func pythonSitePackages(in dir: URL) -> [URL] {
        var found: [URL] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: dir.path) else { return [] }
        for case let rel as String in e {
            if rel.hasSuffix("site-packages") {
                found.append(dir.appendingPathComponent(rel))
            }
        }
        return found
    }

    @MainActor
    static func installPythonSupport(destination: URL, log: Log?) async {
        let fm = FileManager.default
        let sites = pythonSitePackages(in: destination)
        guard let site = sites.first else { return }
        let bundle = Bundle.main.bundlePath
        let scSrc = bundle + "/python-support/sitecustomize.py"
        let caSrc = bundle + "/cacert.pem"

        var didCopy = false
        for s in sites {
            if fm.fileExists(atPath: scSrc) {
                let dst = s.appendingPathComponent("sitecustomize.py")
                try? fm.removeItem(at: dst)
                if (try? fm.copyItem(atPath: scSrc, toPath: dst.path)) != nil { didCopy = true }
            }
            if fm.fileExists(atPath: caSrc) {
                let dst = s.appendingPathComponent("cacert.pem")
                if !fm.fileExists(atPath: dst.path) {
                    _ = try? fm.copyItem(atPath: caSrc, toPath: dst.path)
                }
            }
        }
        if didCopy, let log {
            await log.add("  已铺 python 支撑文件（sitecustomize + CA）→ \(site.lastPathComponent)")
        }

        // pip：随包带 get-pip.py，site-packages 里没有 pip 时装一次（纯 Python，无需编译）
        let gp = bundle + "/python-support/get-pip.py"
        let python = destination.appendingPathComponent("python3").path
        guard fm.fileExists(atPath: gp), fm.fileExists(atPath: python) else { return }
        guard !fm.fileExists(atPath: site.appendingPathComponent("pip").path) else { return }
        if let log { await log.add("  安装 pip（随包离线引导）…") }
        let ca = site.appendingPathComponent("cacert.pem").path
        let r = await Task.detached(priority: .userInitiated) {
            NanoMuseHelperRunner.run(python,
                                     arguments: [gp, "--no-warn-script-location", "--disable-pip-version-check"],
                                     timeout: 900,
                                     extraEnvironment: ["SSL_CERT_FILE": ca])
        }.value
        if let log {
            let tail = r.output.split(separator: "\n").suffix(3).joined(separator: " / ")
            await log.add(r.exitCode == 0 ? "  pip 就绪：\(tail)" : "  pip 安装失败（\(r.exitCode)）：\(tail)")
        }
    }

    // MARK: - 运行时工具的环境变量

    /// 运行时里的二进制是「装好了却用不了」的重灾区，根因只有两个，都能靠环境变量修：
    /// · **没有根证书**：iOS 上 `/private/etc/ssl` 根本不存在，curl 报
    ///   `SSL Trust Anchors: no trust anchors configured`、python 报证书校验失败、
    ///   git 拉不了 https。App 包里自带 `cacert.pem`（Mozilla 2026-09，121 张），指向它即可。
    /// · **编译期路径写死**：core_tools 的 git 把 exec-path 编成
    ///   `/Users/macos/libexec/git-core` → `unable to find remote helper for 'https'`；
    ///   指 GIT_EXEC_PATH 到自家 bin 就好。
    /// 全部指向 App 包内 / 本 App 容器内的文件，不依赖设备上任何别的 App 或系统文件。
    static func runtimeEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        let fm = FileManager.default
        let bundle = Bundle.main.bundlePath

        let ca = bundle + "/cacert.pem"
        if fm.fileExists(atPath: ca) {
            env["SSL_CERT_FILE"] = ca
            env["CURL_CA_BUNDLE"] = ca
            env["REQUESTS_CA_BUNDLE"] = ca
            env["GIT_SSL_CAINFO"] = ca
            env["PIP_CERT"] = ca
        }

        let core = directory(for: "core_tools")
        let coreBin = core.appendingPathComponent("bin").path
        if fm.fileExists(atPath: coreBin + "/git") {
            env["GIT_EXEC_PATH"] = coreBin
            for tpl in [core.appendingPathComponent("share/git-core/templates").path,
                        core.appendingPathComponent("share/templates").path] {
                if fm.fileExists(atPath: tpl) { env["GIT_TEMPLATE_DIR"] = tpl; break }
            }
            env["GIT_TERMINAL_PROMPT"] = "0"
        }

        // python 的 sitecustomize 用它把 shell=True 指到自带 bash（iOS 没有 /bin/sh）
        let bash = bundle + "/Helpers/bash.real"
        if fm.fileExists(atPath: bash) {
            env["NANOMUSE_SH"] = bash
            env["SHELL"] = bash
        }
        return env
    }

    /// PATH 里该追加的运行时目录：core_tools/bin、python、node/bin …（存在才加）
    static func runtimePathEntries() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for id in ["core_tools", "build_tools", "python", "node", "theos"] {
            let base = directory(for: id)
            let bin = base.appendingPathComponent("bin").path
            if fm.fileExists(atPath: bin) { out.append(bin); continue }
            // python 这种是平铺的：<root>/python3
            if fm.fileExists(atPath: base.appendingPathComponent("python3").path) {
                out.append(base.path)
            }
        }
        return out
    }

    /// 已经装过 python 的老用户：进一次运行时列表就把支撑文件补上，不需要重装。
    private static func healPythonSupportIfNeeded() {
        let dir = directory(for: "python")
        let marker = dir.appendingPathComponent(".python-support-v1")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        guard let site = pythonSitePackages(in: dir).first else { return }
        guard !FileManager.default.fileExists(atPath: site.appendingPathComponent("sitecustomize.py").path) else {
            FileManager.default.createFile(atPath: marker.path, contents: Data())
            return
        }
        Task.detached(priority: .utility) {
            await NanoMuseNativeRuntime.installPythonSupport(destination: dir, log: nil)
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
    }

    enum UninstallError: LocalizedError {
        case invalidID(String)
        case notInstalled(String)
        case outsideRoot(String)
        case removalFailed(String)
        case stillExists(String)

        var errorDescription: String? {
            switch self {
            case .invalidID(let id): return "运行时标识无效：\(id)"
            case .notInstalled(let id): return "运行时未安装：\(id)"
            case .outsideRoot(let path): return "拒绝删除运行时根目录之外的路径：\(path)"
            case .removalFailed(let message): return "删除运行时失败：\(message)"
            case .stillExists(let path): return "删除后目标仍存在：\(path)"
            }
        }
    }

    /// 仅删除 root 下的单个已安装运行时；保留 Foundation 的底层错误供 UI 显示。
    @discardableResult
    static func uninstall(_ id: String) throws -> Bool {
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"),
              !id.contains("\0") else { throw UninstallError.invalidID(id) }
        let fm = FileManager.default
        let root = rootDirectory.standardizedFileURL
        let target = root.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        guard target.deletingLastPathComponent() == root, target != root else {
            throw UninstallError.outsideRoot(target.path)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue,
              isInstalled(id) else { throw UninstallError.notInstalled(id) }
        do { try fm.removeItem(at: target) }
        catch { throw UninstallError.removalFailed(error.localizedDescription) }
        guard !fm.fileExists(atPath: target.path) else { throw UninstallError.stillExists(target.path) }
        return true
    }

    /// 已安装目录在磁盘上的真实占用（字节）。用于把「包多大」和「展开多大」分开显示。
    static func sizeOnDisk(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                 options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        }
        return total
    }

    /// root 目录里存在、但清单里已经没有的运行时（旧的 cl16 之类）——
    /// 这些正是「卸载不掉的残留」，单独列出来让用户能删。
    static func orphanDirectories(known: Set<String>) -> [(name: String, bytes: Int64)] {
        let fm = FileManager.default
        let root = rootDirectory
        guard let items = try? fm.contentsOfDirectory(at: root,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url -> (String, Int64)? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            guard !known.contains(name), !name.hasPrefix(".") else { return nil }
            return (name, sizeOnDisk(url))
        }
        .sorted { $0.0 < $1.0 }
    }

    /// 安装后自检：真的把 bin 里的第一个 Mach-O 跑一遍 `--version`。
    /// 这一步能暴露「解开但签不出来 / 被 AMFI 杀掉」的情况，避免装完才发现不能用。
    static func selfTest(_ id: String, log: Log) async -> Bool {
        let fm = FileManager.default
        let dir = directory(for: id)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        var candidates: [URL] = []
        if let items = try? fm.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil) {
            for f in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    candidates.append(f)
                }
            }
        }
        guard let probe = candidates.first else {
            await log.add("  自检：没有可执行文件可试跑（包内可能只有库/脚本）")
            return true
        }
        let result = await Task.detached(priority: .userInitiated) {
            NanoMuseHelperRunner.run(probe.path, arguments: ["--version"], timeout: 60)
        }.value
        let firstLine = result.output.split(separator: "\n").first.map(String.init) ?? ""
        if result.exitCode == 0 {
            await log.add("  自检通过：\(probe.lastPathComponent) → \(firstLine)")
            return true
        }
        await log.add("  自检失败：\(probe.lastPathComponent) 退出码 \(result.exitCode)")
        if result.exitCode == 137 || result.exitCode == 126 || result.exitCode == 132 {
            await log.add("  系统拒绝执行（签名/AMFI）。二进制已解包在：\(dir.path)/bin")
            await log.add("  可继续使用其中的脚本、配置文件；可执行文件需要重签名后才能跑。")
        }
        return false
    }

    // MARK: - 安装主流程

    static func install(_ package: NanoMuseRuntimeManifest.Package,
                        proxies: [String],
                        log: Log) async -> Bool {

        await log.add("STEP 1/5 准备")
        await log.setPhase("准备")
        await log.add("  目标：\(directory(for: package.id).path)")
        await log.add("  大小：\(package.sizeText)")

        // 依赖 / 冲突门禁（清单里的 requires / conflicts）
        let missing = package.requires.filter { !isInstalled($0) }
        if !missing.isEmpty {
            await log.add("ERR 需要先安装：\(missing.joined(separator: ", "))")
            return false
        }
        let conflicted = package.conflicts.filter { isInstalled($0) }
        if !conflicted.isEmpty {
            await log.add("ERR 与已安装的 \(conflicted.joined(separator: ", ")) 冲突")
            return false
        }

        let destination = directory(for: package.id)

        // ---- 已装则跳过下载与解包 ----
        let marker = destination.appendingPathComponent(".installed")
        // 布局校验：deb 必须是 var/jb/... 结构；上次被"归一化"成 jb/ 的要强制重解
        let expectedLayout = destination.appendingPathComponent("var/jb")
        let layoutBroken = package.archiveURL.lowercased().hasSuffix(".deb")
            && !FileManager.default.fileExists(atPath: expectedLayout.path)
        if layoutBroken, FileManager.default.fileExists(atPath: marker.path) {
            await log.add("检测到旧布局（缺 var/jb），重新解包")
            try? FileManager.default.removeItem(at: marker)
        }
        let alreadyInstalled = FileManager.default.fileExists(atPath: marker.path)
        if alreadyInstalled {
            await log.add("STEP 2-4/5 跳过：已安装（只重新签名与探测）")
            await log.setPhase("已安装，跳过下载")
        } else if package.archiveURL.lowercased().hasSuffix(".deb") {
            // 决策依据（真机实测）：Swift 往 rootfs 写文件后 guest 看不到（只有目录、`total 0`），
            // 因为 iSH 的 fakefs 只认 meta.db 里登记过的条目；反过来 guest 建的文件是真实宿主文件。
            // 所以 .deb 一律交给 Alpine：下载（带缓存）、ar 拆包、zstd 解压、tar 解文件。
            guard await installViaAlpine(package, proxies: proxies,
                                         destination: destination, log: log) else {
                await log.add("ERR Alpine 端下载/解包未完成")
                return false
            }
        } else {
            await log.add("STEP 2/5 下载")
            await log.setPhase("下载中…")
            guard let archive = await download(package.archiveURL, proxies: proxies, log: log) else {
                await log.add("ERR 下载失败（直连与代理都不可用）")
                return false
            }
            await log.add("  已落地：\(archive.lastPathComponent)")

            await log.add("STEP 3/5 校验 SHA256")
            await log.setPhase("校验 SHA256")
            let digest = (try? sha256(of: archive)) ?? ""
            await log.add("  期望：\(package.sha256)")
            await log.add("  实际：\(digest)")
            guard !package.sha256.isEmpty, digest == package.sha256 else {
                await log.add("ERR sha256 不匹配，已丢弃")
                try? FileManager.default.removeItem(at: archive)
                return false
            }

            await log.add("STEP 4/5 解包")
            await log.setPhase("解包中…")
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

            guard let payload = await preparePayload(archive: archive, log: log) else {
                await log.add("ERR 无法准备解包载荷（不支持的压缩格式）")
                return false
            }
            guard await extract(payload: payload, into: destination, log: log) else {
                await log.add("ERR 解包失败（详情见上方步骤）")
                return false
            }
            try? FileManager.default.removeItem(at: archive)
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        await log.add("  内容：\(entries.prefix(6).joined(separator: " "))")
        // .deb 的 var/jb/... 是正常布局，不能"归一化"：
        // usr/bin/codex 是硬编码 /var/jb 的启动器，真二进制在 usr/libexec/codex/。
        if !package.archiveURL.lowercased().hasSuffix(".deb"), !alreadyInstalled {
            await normalizeSingleLevel(destination: destination, log: log)
        }

        // 把 deb 自带的 config.toml 作为基础配置（file_opener=none / apps=false 等）
        seedCodexConfig(from: destination, log: log)

        // ---- 权限 / 探测 / 签名 ----
        await log.add("STEP 5/5 权限与探测")
        await log.setPhase("探测与签名")
        let executables = makeExecutable(destination)
        await log.add("  可执行文件：\(executables) 个")

        // 先直接跑：deb 里的二进制本来就带签名，很多情况下不需要重签
        var runnable = false
        if let binary = codexBinary(in: destination) {
            await log.add("  主程序：\(binary.path)")
            let probe = await runProbe(binary.path, arguments: ["--version"])
            await log.add("  --version → rc=\(probe.code)")
            for line in probe.output.split(separator: "\n").prefix(3) {
                await log.add("    \(line)")
            }
            runnable = probe.code == 0
        } else {
            await log.add("  未找到 codex 主程序")
        }

        if !runnable {
            await log.add("  直接运行未通过，尝试签名后重试")
            let signed = await attemptSign(destination, log: log)
            await log.add("  签名：\(signed) 个")
            if let binary = codexBinary(in: destination) {
                let again = await runProbe(binary.path, arguments: ["--version"])
                await log.add("  重试 --version → rc=\(again.code)")
                for line in again.output.split(separator: "\n").prefix(3) {
                    await log.add("    \(line)")
                }
                runnable = again.code == 0
            }
        } else {
            await log.add("  无需重签（原签名可用）")
        }

        // 准备可写的 HOME/bin，避免 codex 试图在只读目录建软链
        let home = NanoMuseCodex.codexHome()
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("bin"),
                                                 withIntermediateDirectories: true)
        if let binary = codexBinary(in: destination) {
            NanoMuseCodex.rememberNativeProbe(binaryPath: binary.path,
                                              runs: runnable,
                                              version: runnable ? "0.162.1" : nil)
        }

        try? Data("\(package.sha256)\n".utf8).write(to: marker)
        if package.id != "codex" {
            if package.id == "python" {
                await log.add("STEP 6/7 铺 python 支撑文件（subprocess / CA / pip）")
                await installPythonSupport(destination: destination, log: log)
            }
            await log.add("STEP 7/7 安装后自检")
            _ = await selfTest(package.id, log: log)
        }
        await log.add("STEP done")
        await log.setPhase("完成")
        await log.setProgress(1)
        return true
    }

    /// 让 Alpine 完成「下载 → ar 拆包 → zstd 解压 → tar 解文件」，
    /// Swift 只负责把 guest 生成的结果搬进 App 容器。
    private static func installViaAlpine(_ package: NanoMuseRuntimeManifest.Package,
                                        proxies: [String],
                                        destination: URL,
                                        log: Log) async -> Bool {
        let rootfsData = RootfsManager.shared.dataPath
        guard FileManager.default.fileExists(atPath: rootfsData.path) else {
            await log.add("ERR iSH rootfs 未就绪")
            return false
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        let stageName = ".nanocodex-\(token)"
        let guest = "/root/\(stageName)"
        let hostOut = rootfsData.appendingPathComponent("root/\(stageName)/out")

        let urls = ([""] + proxies).map { "\($0)\(package.archiveURL)" }
            .map { "\"\($0)\"" }
            .joined(separator: " ")
        let total = package.sizeBytes

        let script = #"""
        set -u
        D=__GUEST__
        rm -rf "$D"; mkdir -p "$D/out"; cd "$D" || { echo CD_FAIL; exit 10; }
        echo "GUEST=$D"
        apk add --no-cache curl tar zstd >/dev/null 2>&1 || true
        command -v zstd >/dev/null 2>&1 || { echo NO_ZSTD; exit 11; }

        CACHE=/root/.nanocodex-cache
        mkdir -p "$CACHE"
        CACHED="$CACHE/__SHA__.deb"
        OK=0
        if [ -s "$CACHED" ]; then
          CSZ=$(stat -c %s "$CACHED" 2>/dev/null || echo 0)
          if [ "$CSZ" -gt 1000000 ]; then
            echo "CACHE_HIT 复用已下载的包（$CSZ bytes）"
            cp "$CACHED" pkg.deb && OK=1
          fi
        fi
        if [ "$OK" != "1" ]; then
          for U in __URLS__; do
            echo "TRY $U"
            ( curl -fL --retry 1 --connect-timeout 20 -o pkg.deb "$U" 2>/dev/null ) &
            CPID=$!
            while kill -0 $CPID 2>/dev/null; do
              SZ=$(stat -c %s pkg.deb 2>/dev/null || echo 0)
              echo "BYTES $SZ __TOTAL__"
              sleep 1
            done
            wait $CPID && OK=1
            SZ=$(stat -c %s pkg.deb 2>/dev/null || echo 0)
            echo "BYTES $SZ __TOTAL__"
            if [ "$OK" = "1" ] && [ "$SZ" -gt 1000000 ]; then break; fi
            OK=0
          done
          [ "$OK" = "1" ] || { echo NO_DOWNLOAD; exit 12; }
          cp pkg.deb "$CACHED" 2>/dev/null || true
          echo "CACHE_SAVED $(stat -c %s "$CACHED" 2>/dev/null || echo 0) bytes"
        fi

        echo "SIZE=$(stat -c %s pkg.deb)"
        echo "SHA256=$(sha256sum pkg.deb | cut -d' ' -f1)"

        command -v ar >/dev/null 2>&1 || apk add --no-cache binutils >/dev/null 2>&1
        rm -rf x && mkdir x
        ( cd x && ar x ../pkg.deb ) 2>&1 | head -3 || { echo NO_AR; exit 13; }
        ls -l x 2>/dev/null | head -5

        if [ -f x/data.tar.zst ]; then
          zstd -d -q -f x/data.tar.zst -o x/data.tar || { echo NO_ZSTD_DECODE; exit 14; }
          tar xf x/data.tar -C out || { echo NO_UNTAR; exit 15; }
        elif [ -f x/data.tar.xz ]; then
          tar xJf x/data.tar.xz -C out || { echo NO_UNTAR; exit 15; }
        elif [ -f x/data.tar.gz ]; then
          tar xzf x/data.tar.gz -C out || { echo NO_UNTAR; exit 15; }
        else
          echo NO_DATA; exit 16
        fi

        echo "EXTRACT_OK"
        find out -maxdepth 2 -type f | head -8 | sed 's/^/  /'
        rm -rf x pkg.deb
        """#
            .replacingOccurrences(of: "__GUEST__", with: guest)
            .replacingOccurrences(of: "__URLS__", with: urls)
            .replacingOccurrences(of: "__TOTAL__", with: String(total))
            .replacingOccurrences(of: "__SHA__", with: package.sha256.isEmpty ? "unknown" : package.sha256)

        await log.add("STEP 2-4/5 Alpine 端下载并解包")
        await log.setPhase("Alpine 下载中…")
        let (code, output) = await NanoMuseCodex.runCommand(script, timeout: 2400)
        for line in output.split(separator: "\n") { await log.add("  " + String(line)) }

        guard code == 0, output.contains("EXTRACT_OK") else {
            await log.add("ERR 解包脚本失败（rc=\(code)）")
            try? FileManager.default.removeItem(at: rootfsData.appendingPathComponent("root/\(stageName)"))
            return false
        }

        // 校验 SHA256（由 guest 计算，Swift 比对）
        if let range = output.range(of: "SHA256=") {
            let rest = output[range.upperBound...]
            let digest = String(rest.prefix(while: { $0 != "\n" && $0 != "\r" }))
            await log.add("  期望 sha256：\(package.sha256)")
            await log.add("  实际 sha256：\(digest)")
            if !package.sha256.isEmpty, digest != package.sha256 {
                await log.add("ERR sha256 不匹配，已丢弃")
                try? FileManager.default.removeItem(at: rootfsData.appendingPathComponent("root/\(stageName)"))
                return false
            }
        }

        // 把 guest 生成的结果搬进 App 容器（guest→host 是真实文件）
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = (try? FileManager.default.contentsOfDirectory(atPath: hostOut.path)) ?? []
        await log.add("  guest 产出：\(children.count) 项")
        guard !children.isEmpty else {
            await log.add("ERR guest 没产出文件（检查 out 目录）")
            return false
        }
        for child in children {
            let from = hostOut.appendingPathComponent(child)
            let to = destination.appendingPathComponent(child)
            try? FileManager.default.moveItem(at: from, to: to)
        }
        try? FileManager.default.removeItem(at: rootfsData.appendingPathComponent("root/\(stageName)"))
        return true
    }

    /// 单层目录归一：`out/bin` → `bin`
    private static func normalizeSingleLevel(destination: URL, log: Log) async {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []
        guard entries.count == 1, let only = entries.first else { return }
        let inner = destination.appendingPathComponent(only)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: inner.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        await log.add("  归一化单层目录：\(only)")
        for child in (try? FileManager.default.contentsOfDirectory(atPath: inner.path)) ?? [] {
            try? FileManager.default.moveItem(at: inner.appendingPathComponent(child),
                                              to: destination.appendingPathComponent(child))
        }
        try? FileManager.default.removeItem(at: inner)
    }

    /// 找运行时里的 codex 主程序：取体积最大的那个（deb 里 usr/bin/codex 只是 52 KB 启动器）
    static func codexBinary(in root: URL) -> (path: String, size: Int)? {
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: [.fileSizeKey],
                                                             options: []) else { return nil }
        var candidates: [(path: String, size: Int)] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "codex" || url.lastPathComponent == "codex-code-mode-host" else { continue }
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            candidates.append((url.path, size))
        }
        return candidates.max(by: { $0.size < $1.size })
    }

    /// 用原生 posix_spawn 跑一次探测（同时验证签名与依赖）
    static func runProbe(_ path: String, arguments: [String]) async -> (code: Int32, output: String) {
        let result = await Task.detached(priority: .userInitiated) {
            NanoMuseHelperRunner.run(path, arguments: arguments, timeout: 60)
        }.value
        return (result.exitCode, result.output)
    }

    /// 把 deb 自带的 etc/codex/config.toml 复制到 CODEX_HOME 作为基础配置
    private static func seedCodexConfig(from destination: URL, log: Log) {
        let home = NanoMuseCodex.codexHome()
        let target = home.appendingPathComponent("config.toml")
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        let candidates = ["var/jb/etc/codex/config.toml", "etc/codex/config.toml"]
        for rel in candidates {
            let source = destination.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.copyItem(at: source, to: target)
                return
            }
        }
    }

    // MARK: - 下载（直连 → 代理回退）

    private static func download(_ urlString: String,
                                 proxies: [String],
                                 log: Log) async -> URL? {
        for prefix in ([""] + proxies) {
            guard let url = URL(string: prefix + urlString) else { continue }
            await log.add("  尝试：\(prefix.isEmpty ? "直连" : prefix)")
            await log.setPhase("连接中…")

            let suffix: String
            if urlString.hasSuffix(".gz") { suffix = "tar.gz" }
            else if urlString.hasSuffix(".deb") { suffix = "deb" }
            else if urlString.hasSuffix(".xz") { suffix = "tar.xz" }
            else if urlString.hasSuffix(".zst") { suffix = "tar.zst" }
            else { suffix = "bin" }

            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("rt-\(UUID().uuidString.prefix(6)).\(suffix)")

            do {
                let downloader = ProgressDownloader(log: log, destination: target)
                let file = try await downloader.start(url)
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
                let size = (attributes?[.size] as? Int) ?? 0
                await log.setProgress(1)
                await log.setPhase("下载完成 \(size / 1048576) MB")
                await log.add("    完成：\(size / 1048576) MB")
                return file
            } catch {
                await log.add("    失败：\(error.localizedDescription)")
                await log.setProgress(nil)
            }
        }
        return nil
    }

    /// URLSession 下载代理：每 0.4 秒写一次进度，每 4 MB 落一行回显。
    private final class ProgressDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let log: Log
        private let destination: URL
        private var continuation: CheckedContinuation<URL, Error>?
        private var session: URLSession?
        private var lastEmit = Date.distantPast
        private var lastMark: Int64 = 0

        init(log: Log, destination: URL) {
            self.log = log
            self.destination = destination
        }

        func start(_ url: URL) async throws -> URL {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 1800
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                session.downloadTask(with: url).resume()
            }
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite
            let progress = total > 0 ? Double(totalBytesWritten) / Double(total) : nil
            let mb = Double(totalBytesWritten) / 1048576
            let totalMB = total > 0 ? Double(total) / 1048576 : 0

            let now = Date()
            if now.timeIntervalSince(lastEmit) > 0.4 {
                lastEmit = now
                Task { @MainActor in
                    log.setProgress(progress)
                    log.setPhase(String(format: "下载中 %.1f / %.1f MB", mb, totalMB))
                }
            }
            if totalBytesWritten - lastMark >= 4 * 1024 * 1024 {
                lastMark = totalBytesWritten
                Task { @MainActor in
                    log.add(String(format: "BYTES %lld %lld", totalBytesWritten, total))
                }
            }
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                continuation?.resume(returning: destination)
                continuation = nil
            } catch {
                continuation?.resume(throwing: error)
                continuation = nil
            }
            session.finishTasksAndInvalidate()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let continuation else { return }
            continuation.resume(throwing: error)
            self.continuation = nil
            session.finishTasksAndInvalidate()
        }
    }

    // MARK: - SHA256（流式，避免 200 MB 进内存）

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - deb / tar 载荷准备

    private static func preparePayload(archive: URL, log: Log) async -> URL? {
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return archive }
        guard name.hasSuffix(".deb") else {
            await log.add("  不支持：\(name)（仅支持 .deb 与 .tar.gz）")
            return nil
        }
        return await arExtract(archive: archive, matchingPrefix: "data.tar", log: log)
    }

    /// 极简 `ar` 读取器：`!<arch>\n` + 60 字节头。
    private static func arExtract(archive: URL, matchingPrefix: String, log: Log) async -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return nil }
        defer { try? handle.close() }

        guard let magic = try? handle.read(upToCount: 8), magic == Data("!<arch>\n".utf8) else {
            await log.add("  不是 ar 归档")
            return nil
        }
        while true {
            guard let header = try? handle.read(upToCount: 60), header.count == 60 else { break }
            let nameField = header.subdata(in: 0..<16)
            let sizeField = header.subdata(in: 48..<58)
            let name = String(decoding: nameField, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "/", with: "")
            let size = Int(String(decoding: sizeField, as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)) ?? 0
            await log.add("  ar 成员：\(name.isEmpty ? "(长名)" : name) \(size) B")
            guard size > 0 else { continue }

            if name.hasPrefix(matchingPrefix) {
                let suffix = name.hasSuffix(".xz") ? "xz" : (name.hasSuffix(".zst") ? "zst" : "gz")
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("input-\(UUID().uuidString.prefix(6)).tar.\(suffix)")
                guard stream(handle: handle, bytes: size, to: out) else {
                    await log.add("  写出载荷失败")
                    return nil
                }
                if suffix == "gz" { return out }
                await log.add("  deb 内层为 .\(suffix)：交给 Alpine 解压（zstd/xz 由 apk 提供）")
                return out
            }
            let skip = UInt64(size % 2 == 0 ? size : size + 1)
            try? handle.seek(toOffset: handle.offsetInFile + skip)
        }
        await log.add("  deb 里没找到 \(matchingPrefix)")
        return nil
    }

    /// 解包分流：
    ///   · `.tar.gz` / `.deb`(gz 载荷) → 随包 Helpers/tarx（原生 Mach-O 解包器）
    ///   · `.tar.zst` / `.tar.xz` → 交给 Alpine（apk 提供 zstd/xz），
    ///     这样解出来的 Mach-O 才能被 posix_spawn 执行。
    ///
    /// ⚠️ 以前这里调的是 `ca-filetool tar xzf`，但 ca-filetool 只有
    /// ls/cat/grep/head/tail/xxd/ln/chmod/du/find/which 这些子命令，**根本没有 tar**，
    /// 于是每次都「tar 退出码 1」，安装流程必然失败。Helpers/tarx 才是随包的真解包器。
    private static func extract(payload: URL, into destination: URL, log: Log) async -> Bool {
        let name = payload.lastPathComponent.lowercased()
        if name.hasSuffix(".zst") || name.hasSuffix(".xz") {
            return await extractViaAlpine(payload: payload, into: destination, log: log)
        }

        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        if NanoMuseHelperRunner.exists("tarx") {
            // 几百 MB 的包，放后台线程，别占主线程
            let result = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run(
                    "tarx",
                    arguments: ["-xf", payload.path, "-C", destination.path],
                    timeout: 900
                )
            }.value
            await log.add("  tarx 退出码：\(result.exitCode)")
            for line in result.output.split(separator: "\n").suffix(3) {
                await log.add("  \(line)")
            }
            if result.exitCode == 0 { return true }
            await log.add("  tarx 失败，回退到 Alpine 解包")
        } else {
            await log.add("  未随包 tarx，回退到 Alpine 解包")
        }
        return await extractViaAlpine(payload: payload, into: destination, log: log)
    }

    /// 借 Alpine 解 zstd/xz：**直接读写 iSH 的 rootfs 目录**（`RootfsManager.shared.dataPath`，
    /// 即 `Documents/alpine-rootfs/data`），不需要 mount —— nanoMuse 自己也是这么用这个路径的。
    /// 流程：把载荷复制进 `/tmp/<staging>` → Alpine 里 `apk add zstd` 解压 → 读回 `out/` → 搬进最终目录。
    private static func extractViaAlpine(payload: URL, into destination: URL, log: Log) async -> Bool {
        let rootfsData = RootfsManager.shared.dataPath
        guard FileManager.default.fileExists(atPath: rootfsData.path) else {
            await log.add("ERR iSH rootfs 还没安装好，无法借 Alpine 解压")
            return false
        }

        let token = String(UUID().uuidString.prefix(8)).lowercased()
        // 放 /root 而不是 /tmp：/tmp 可能被挂成 tmpfs，宿主写入看不到
        let stagingHost = rootfsData.appendingPathComponent("root/.nanocodex-\(token)")
        let stagingGuest = "/root/.nanocodex-\(token)"

        // 载荷名：只保留扩展名，避免 "payload-payload-xxx"
        let suffixTag: String
        if payload.lastPathComponent.hasSuffix(".tar.zst") { suffixTag = "tar.zst" }
        else if payload.lastPathComponent.hasSuffix(".tar.xz") { suffixTag = "tar.xz" }
        else if payload.lastPathComponent.hasSuffix(".tar.gz") { suffixTag = "tar.gz" }
        else { suffixTag = "bin" }
        let payloadName = "input.\(suffixTag)"

        do {
            try FileManager.default.createDirectory(at: stagingHost, withIntermediateDirectories: true)
            let target = stagingHost.appendingPathComponent(payloadName)
            try FileManager.default.copyItem(at: payload, to: target)
        } catch {
            await log.add("ERR 复制载荷到 rootfs 失败：\(error.localizedDescription)")
            return false
        }

        // ★ 关键：iSH 的 fakefs 用 meta.db 描述目录树，
        //   纯宿主写入的文件没有 meta 行，guest 里看不到 → 必须注册。
        let copiedAttributes = try? FileManager.default
            .attributesOfItem(atPath: stagingHost.appendingPathComponent(payloadName).path)
        let payloadBytes = (copiedAttributes?[.size] as? Int) ?? 0
        await log.add("  载荷大小：\(payloadBytes / 1048576) MB")

        RootfsManager.shared.registerSubtreeInMetaDB(hostRoot: stagingHost)
        await log.add("  已注册到 iSH meta.db（否则 guest 看不到）")
        await log.add("  载荷已放入 rootfs：\(stagingGuest)/\(payloadName)")

        let script = #"""
        set -u
        echo "GUEST_DIR=__GUEST__"
        ls -la __GUEST__ 2>&1 | head -5
        cd __GUEST__ || { echo "CD_FAIL"; exit 10; }
        rm -rf out && mkdir -p out
        case "__NAME__" in
          *.zst)
            command -v zstd >/dev/null 2>&1 || apk add --no-cache zstd >/dev/null 2>&1
            command -v zstd >/dev/null 2>&1 || { echo "NO_ZSTD"; exit 11; }
            zstd -d -q -f "__NAME__" -o data.tar || exit 12
            tar xf data.tar -C out || exit 13
            rm -f data.tar
            ;;
          *.xz)
            command -v xz >/dev/null 2>&1 || apk add --no-cache xz >/dev/null 2>&1
            tar xJf "__NAME__" -C out || exit 13
            ;;
          *)
            echo "UNSUPPORTED"; exit 14 ;;
        esac
        echo "EXTRACT_OK"
        find out -maxdepth 3 -type f | head -8
        """#
            .replacingOccurrences(of: "__GUEST__", with: stagingGuest)
            .replacingOccurrences(of: "__NAME__", with: payloadName)

        let (code, output) = await NanoMuseCodex.runCommand(script, timeout: 1200)
        for line in output.split(separator: "\n") {
            await log.add("  " + String(line))
        }
        guard code == 0, output.contains("EXTRACT_OK") else {
            if output.contains("NO_ZSTD") {
                await log.add("  Alpine 里 apk add zstd 失败（源/网络问题）")
            }
            try? FileManager.default.removeItem(at: stagingHost)
            await log.add("ERR Alpine 解压未成功（载荷 \(payloadBytes / 1048576) MB，见上方 CD_FAIL / ls 输出）")
            return false
        }

        let produced = stagingHost.appendingPathComponent("out")
        let children = (try? FileManager.default.contentsOfDirectory(atPath: produced.path)) ?? []
        await log.add("  搬运 \(children.count) 项到 App 容器")
        for child in children {
            let from = produced.appendingPathComponent(child)
            let to = destination.appendingPathComponent(child)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.moveItem(at: from, to: to)
        }
        try? FileManager.default.removeItem(at: stagingHost)
        return true
    }

    /// 从 handle 里按块搬 `bytes` 字节到文件，避免把上百 MB 读进内存
    private static func stream(handle: FileHandle, bytes: Int, to url: URL) -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let sink = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? sink.close() }
        var remaining = bytes
        while remaining > 0 {
            let chunk = min(remaining, 4 << 20)
            guard let data = try? handle.read(upToCount: chunk), !data.isEmpty else { break }
            sink.write(data)
            remaining -= data.count
        }
        return remaining == 0
    }

    // MARK: - 权限 / 签名 / 探测

    @discardableResult
    private static func makeExecutable(_ root: URL) -> Int {
        var count = 0
        guard let enumerator = FileManager.default.enumerator(at: root,
                                                             includingPropertiesForKeys: [.isRegularFileKey],
                                                             options: []) else { return 0 }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            guard isMachO(url) else { continue }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            count += 1
        }
        return count
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        try? handle.close()
        let magic = [UInt8](head)
        return magic == [0xCF, 0xFA, 0xED, 0xFE]
            || magic == [0xCE, 0xFA, 0xED, 0xFE]
            || magic == [0xCA, 0xFE, 0xBA, 0xBE]
    }

    /// 读 Mach-O filetype：2 = MH_EXECUTE，6 = MH_DYLIB，8 = MH_BUNDLE；
    /// fat 容器/读不出时返回 nil（按可执行文件处理，保持旧行为）。
    private static func machOFileType(_ url: URL) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 16), head.count == 16 else { return nil }
        try? handle.close()
        let b = [UInt8](head)
        if b.prefix(4) == [0xCA, 0xFE, 0xBA, 0xBE] { return nil }
        let le = b.prefix(4) == [0xCF, 0xFA, 0xED, 0xFE] || b.prefix(4) == [0xCE, 0xFA, 0xED, 0xFE]
        guard le else { return nil }
        return UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24
    }

    /// 尽力用随包的 codex-sign 做 ad-hoc 签名；失败不阻断（App 已无沙盒）。
    private static func attemptSign(_ root: URL, log: Log) async -> Int {
        guard NanoMuseHelperRunner.exists("codex-sign") else {
            await log.add("  （未随包 codex-sign，跳过）")
            return 0
        }
        var targets: [URL] = []
        if let enumerator = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: []) {
            for case let url as URL in enumerator where isMachO(url) { targets.append(url) }
        }
        // 带 entitlements 签名：no-sandbox / platform-application / get-task-allow …
        // 这样原生 codex 才有机会读到宿主数据；失败再退回 adhoc（至少能起进程）。
        let entitlementPath = Bundle.main.bundlePath + "/entitlements.plist"
        let hasEntitlements = FileManager.default.fileExists(atPath: entitlementPath)
        if hasEntitlements {
            await log.add("  用 entitlements.plist 签名（平台身份）")
        } else {
            await log.add("  未找到 entitlements.plist，退回 adhoc")
        }

        var signed = 0
        var keptOriginal = 0
        // 单个文件 > 64 MB 时签名工具很容易被 jetsam 杀掉（SIGKILL/137），
        // 而且 deb 里的大二进制本来就带签名，先跳过、交给"运行探测"判断。
        // 先试大文件；只有大文件确实签失败后，才跳过后续大文件。
        // 否则主程序（235 MB）永远签不到，仍然 EBADEXEC。
        let sizeLimit = 64 * 1024 * 1024
        var skippedBig = 0
        var bigFailed = false
        for url in targets {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > sizeLimit && bigFailed { skippedBig += 1; continue }
            let fileType = machOFileType(url)
            // dylib / framework：一比一照 MT-Agent 的产物来签 —— 一个权限槽都不带。
            // 实测差异：MT 的 Python.framework 是 3 个 blob（CD-SHA1 + CD-SHA256 + CMS）；
            // 我们之前用 --entitlements（哪怕内容是空字典）会多出第 4 个 blob
            // （entitlements，1076 字节，等于 App 自己的权限表），AMFI 直接判
            // code signature invalid。所以这里只发 codex-sign <path>，失败就保留原签名。
            // 按路径兜底：Python.framework/Python 这类框架二进制实测被 machOFileType
            // 误判成可执行文件，于是走了 --entitlements 分支，多出第 4 个 1076B 权限
            // blob → AMFI 判 invalid。路径判定比头解析可靠，两个条件取或。
            let lowerPath = url.path.lowercased()
            let looksLikeLibrary = lowerPath.contains(".framework/") || lowerPath.hasSuffix(".dylib")
                || lowerPath.hasSuffix(".so")
            if looksLikeLibrary || fileType == 6 || fileType == 8 {
                let plain = await Task.detached(priority: .utility) {
                    NanoMuseHelperRunner.run("codex-sign", arguments: [url.path], timeout: 60)
                }.value
                if plain.exitCode == 0 {
                    signed += 1
                } else {
                    keptOriginal += 1
                }
                continue
            }
            var ok = false
            // 可执行文件才需要平台身份（no-sandbox / platform-application / get-task-allow）。
            if hasEntitlements {
                let entitled = await Task.detached(priority: .utility) {
                    NanoMuseHelperRunner.run("codex-sign",
                                             arguments: ["--entitlements", entitlementPath, url.path],
                                             timeout: 60)
                }.value
                ok = entitled.exitCode == 0
                if !ok {
                    await log.add("    签名失败（rc=\(entitled.exitCode)）：\(url.lastPathComponent)，试 adhoc")
                }
            }
            if !ok {
                let adhoc = await Task.detached(priority: .utility) {
                    NanoMuseHelperRunner.run("codex-sign", arguments: ["--adhoc-only", url.path], timeout: 60)
                }.value
                ok = adhoc.exitCode == 0
            }
            if ok {
                signed += 1
                if size > sizeLimit {
                    await log.add("  已签大文件：\(url.lastPathComponent) \(size / 1048576) MB")
                }
            } else if size > sizeLimit {
                bigFailed = true
                await log.add("  大文件签名失败：\(url.lastPathComponent) \(size / 1048576) MB")
            }
        }
        if skippedBig > 0 {
            await log.add("  跳过 \(skippedBig) 个超过 64 MB 的文件（避免签名工具被系统杀掉）")
        }
        if keptOriginal > 0 {
            await log.add("  \(keptOriginal) 个 dylib/framework 签名工具返回失败，已保留包内原签名")
        }
        return signed
    }

    private static func probeBinary(package: NanoMuseRuntimeManifest.Package, root: URL) -> String? {
        guard let first = package.probeArguments.first else { return nil }
        let candidate = first.contains("/")
            ? root.appendingPathComponent(first)
            : root.appendingPathComponent("bin/\(first)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate.path : nil
    }

    private static func probe(binary: String, arguments: [String]) async -> String {
        let escaped = arguments.dropFirst()
            .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        let (_, output) = await NanoMuseCodex.runCommand("'\(binary)' \(escaped) 2>&1 | head -5", timeout: 60)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 清单里的 `install.environment`：把 `${RUNTIME_ROOT}` 换成本地路径
    static func environment(for package: NanoMuseRuntimeManifest.Package) -> [String: String] {
        let root = directory(for: package.id).path
        return package.environment.mapValues {
            $0.replacingOccurrences(of: "${RUNTIME_ROOT}", with: root)
        }
    }
}
