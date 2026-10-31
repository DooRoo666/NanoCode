import Foundation

/// `swift_tipa`：Swift 源码 → 编译 → 链接 → .app → 签名 → .tipa。
///
/// 全程在宿主 App 进程内完成，不 fork、不经过 iSH：
///   · 编译 / 链接：`NanoMuseNyxian`（CoreCompiler.framework 的 C API）
///   · SDK：`NanoMuseSDKDownloader`（已安装则直接用，缺失才下载）
///   · 签名：`NanoMuseMachSigner`（纯 Swift ad-hoc + entitlements）
///   · 打包：`NanoMuseTipaBuilder`（进程内 ZIP，内部用 codex-sign 签 Mach-O）
enum NanoMuseSwiftTipaTool {

    static let toolName = "swift_tipa"

    /// SDK 只有 arm64e；设备为 A16 / arm64e。
    static let target = "arm64e-apple-ios26.5"
    static let minimumOS = "26.0"

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: toolName,
            description: """
            Compile Swift source directly into an installable .tipa on the iPhone, in-process \
            (no fork, no iSH). Pass one .swift file or a directory of .swift files; it compiles \
            with CoreCompiler for arm64e, links against the installed iPhoneOS SDK, assembles a \
            minimal .app bundle, signs it with TrollStore entitlements and packages Payload/ into \
            a .tipa. Use this after writing an iOS GUI app (it must call UIApplicationMain). \
            The absolute .tipa path is returned and can be opened with TrollStore.
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user. Use the user's language."),
                "source": AgentToolParam(type: .string, description: "Absolute path to a .swift file, or a directory whose .swift files are all compiled together."),
                "name": AgentToolParam(type: .string, description: "App name, also used as the executable name. Defaults to the source file/directory name."),
                "bundle_id": AgentToolParam(type: .string, description: "CFBundleIdentifier. Defaults to com.nanocode.<name>, lowercased."),
                "output": AgentToolParam(type: .string, description: "Optional output file name, e.g. MyApp.tipa. Defaults to <name>.tipa."),
            ],
            required: ["tool_title", "source"],
            propertyOrdering: ["tool_title", "source", "name", "bundle_id", "output"]
        )
    }

    struct Outcome: Sendable {
        let exitCode: Int32
        let text: String
    }

    static func execute(source: String,
                        name: String?,
                        bundleID: String?,
                        output: String?) async -> Outcome {
        let fm = FileManager.default
        var log: [String] = ["== swift_tipa（宿主进程内，不 fork）=="]
        let started = Date()
        var cleanedUp = false

        func finish(_ message: String, code: Int32) -> Outcome {
            if !message.isEmpty { log.append(message) }
            log.append(String(format: "== %@ · 用时 %.1fs ==",
                              code == 0 ? "完成" : "失败",
                              Date().timeIntervalSince(started)))
            return Outcome(exitCode: code, text: log.joined(separator: "\n"))
        }

        // ---- 1. 源文件 -----------------------------------------------------
        let input = expand(source)
        guard !input.isEmpty else {
            log.append("ERR 缺少 source：请传 .swift 文件或目录的绝对路径")
            return finish("", code: 1)
        }
        guard input.hasPrefix("/") else {
            log.append("ERR source 需要绝对路径，收到：\(input)")
            return finish("", code: 1)
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input, isDirectory: &isDir) else {
            log.append("ERR 源码不存在：\(input)")
            return finish("", code: 1)
        }

        let sources: [URL]
        if isDir.boolValue {
            sources = swiftFiles(in: URL(fileURLWithPath: input, isDirectory: true))
            log.append("源目录：\(input)")
            log.append("发现 \(sources.count) 个 .swift：")
            for file in sources { log.append("  · \(file.path)") }
            guard !sources.isEmpty else {
                log.append("ERR 目录下没有 .swift 文件")
                return finish("", code: 1)
            }
        } else {
            guard input.lowercased().hasSuffix(".swift") else {
                log.append("ERR 不是 .swift 文件：\(input)")
                return finish("", code: 1)
            }
            sources = [URL(fileURLWithPath: input)]
            log.append("源文件：\(input)")
        }

        let appName = sanitizedName(name, fallback: defaultName(for: URL(fileURLWithPath: input)))
        let bundle = normalizedBundleID(bundleID, appName: appName)
        log.append("App：\(appName)")
        log.append("Bundle ID：\(bundle)")

        // 只受理主入口在源码里出现的情况：Swift 顶层代码若没有 UIApplicationMain，
        // 装上去必然闪退/黑屏。这里不修改源码，只给出明确可操作的错误。
        let combined = sources.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        guard combined.contains("UIApplicationMain") else {
            log.append("ERR 源码缺少 UIApplicationMain —— 编出来是终端程序，安装后会闪退/黑屏。")
            log.append("    请以 UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self)) 结尾。")
            return finish("", code: 1)
        }

        // ---- 工作目录 ------------------------------------------------------
        let work = fm.temporaryDirectory
            .appendingPathComponent("swift-tipa-\(UUID().uuidString)", isDirectory: true)
        let moduleCache = work.appendingPathComponent("ModuleCache", isDirectory: true)
        let objectsDir = work.appendingPathComponent("objects", isDirectory: true)
        let app = work.appendingPathComponent("\(appName).app", isDirectory: true)
        let binary = app.appendingPathComponent(appName)
        let entitlements = work.appendingPathComponent("entitlements.plist")

        do {
            try fm.createDirectory(at: moduleCache, withIntermediateDirectories: true)
            try fm.createDirectory(at: objectsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: app, withIntermediateDirectories: true)
        } catch {
            log.append("ERR 创建临时目录失败：\(error.localizedDescription)")
            return finish("", code: 1)
        }
        // 临时 .app 只在打包时使用；成功后清理，失败时保留以便排查。
        defer { if cleanedUp { try? fm.removeItem(at: work) } }
        log.append("临时目录：\(work.path)")

        // ---- 2. SDK --------------------------------------------------------
        log.append("[1/6] 检查 SDK…")
        let sdk: URL
        if NanoMuseSDKDownloader.isInstalled() {
            sdk = NanoMuseSDKDownloader.installedSDKPath
            log.append("      已安装：\(sdk.path)")
        } else if let detected = NanoMuseNyxian.detectSDK() {
            sdk = detected
            log.append("      检测到外部 SDK：\(sdk.path)")
        } else {
            log.append("      未安装，开始下载 iPhoneOS SDK（约 49MB 压缩包）…")
            let progress = ProgressLog()
            let result: Result<URL, Error> = await withCheckedContinuation { continuation in
                NanoMuseSDKDownloader.ensureInstalled(progress: { ratio in
                    // 回调可能来自任意线程；ProgressLog 自己加锁，只保留 20% 档位。
                    progress.record(ratio)
                }, completion: { continuation.resume(returning: $0) })
            }
            switch result {
            case .success(let url):
                sdk = url
                log.append("      SDK 就绪：\(sdk.path)")
            case .failure(let error):
                log.append("ERR SDK 缺失且下载失败：\(error.localizedDescription)")
                log.append("    可手动把 iPhoneOS26.5.sdk 放到 Documents/nyxian/ 或 Runtimes/sdks/ 后重试。")
                return finish("", code: 1)
            }
            log.append(contentsOf: progress.lines())
        }
        guard fm.fileExists(atPath: sdk.path) else {
            log.append("ERR SDK 路径不存在：\(sdk.path)")
            return finish("", code: 1)
        }

        let res = NanoMuseNyxian.detectSwiftResources()?.path ?? ""
        log.append("Swift 资源：\(res.isEmpty ? "未检测到（链接会尝试 SDK 内置库）" : res)")
        if !res.isEmpty {
            let marker = res + "/swift/iphoneos"
            if !fm.fileExists(atPath: marker) {
                log.append("      提示：\(marker) 不存在，Swift 编译可能缺少 stdlib 模块")
            }
        }

        // ---- 3. 编译 -------------------------------------------------------
        log.append("[2/6] 编译 Swift（swiftc via CoreCompiler）…")
        let loaded: NanoMuseNyxian.Loaded
        switch NanoMuseNyxian.load() {
        case .success(let value):
            loaded = value
            log.append("      CoreCompiler：\(value.path)")
        case .failure(let error):
            log.append("ERR 加载 CoreCompiler 失败：\(error)")
            log.append("    请先在「设置 → Codex」完成原生运行时安装（需要 CoreCompiler.framework，约 186MB）。")
            return finish("", code: 1)
        }

        // 目录内的全部 .swift 作为同一个模块一次编译；-emit-object 产出单个 .o，
        // 避免多文件各自编译时的模块边界与同名文件覆盖问题。
        let object = objectsDir.appendingPathComponent("main.o")
        try? fm.removeItem(at: object)
        var compileArgs = ["-target", target,
                           "-sdk", sdk.path,
                           "-isysroot", sdk.path,
                           "-F", sdk.path + "/System/Library/Frameworks",
                           "-I", sdk.path + "/usr/lib/swift",
                           "-L", sdk.path + "/usr/lib/swift",
                           "-module-cache-path", moduleCache.path]
        if !res.isEmpty { compileArgs += ["-resource-dir", res] }
        compileArgs += ["-module-name", "main"]
        compileArgs += ["-emit-object", "-o", object.path]
        compileArgs += sources.map(\.path)
        log.append("      " + sources.map(\.lastPathComponent).joined(separator: ", "))
        let startedCompile = Date()
        let compile = loaded.run(compileArgs, swift: true)
        log.append("      ok=\(compile.ok) · \(String(format: "%.1fs", Date().timeIntervalSince(startedCompile)))")
        log.append(indent(compile.log))
        let produced = ((try? fm.attributesOfItem(atPath: object.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard compile.ok, fm.fileExists(atPath: object.path), produced > 0 else {
            log.append("ERR 编译失败：\(sources.map(\.path).joined(separator: ", "))")
            log.append("    常见原因：缺少 Swift 资源目录、SDK 不匹配、源码语法错误。")
            return finish("", code: 1)
        }
        log.append("      目标文件：\(object.path)（\(produced) B）")

        // ---- 4. 链接 -------------------------------------------------------
        log.append("[3/6] 链接 executable（swiftLink）…")
        try? fm.removeItem(at: binary)
        let linkLog = NanoMuseNyxian.swiftLink(loaded: loaded,
                                               obj: object,
                                               bin: binary,
                                               sdk: sdk.path,
                                               res: res,
                                               work: work,
                                               target: target,
                                               isolated: false,
                                               frameworks: ["UIKit", "Foundation"],
                                               progress: { log.append(indent($0)) })
        log.append(indent(linkLog))
        let linkedSize = ((try? fm.attributesOfItem(atPath: binary.path))?[.size] as? NSNumber)?.intValue ?? 0
        let linked = linkedSize > 0
        guard linked, fm.fileExists(atPath: binary.path) else {
            log.append("ERR 链接失败：未产出可执行文件")
            log.append("    检查 SDK 的 usr/lib/swift 与 System/Library/Frameworks 是否完整。")
            return finish("", code: 1)
        }
        let binarySize = linkedSize
        log.append("      产物：\(binary.path)（\(binarySize) B）")
        let architecture = machoDescription(binary)
        log.append("      架构校验：\(architecture)")
        guard architecture.contains("arm64e") else {
            log.append("ERR 链接产物不是 arm64e（SDK/参数与设备不匹配）")
            return finish("", code: 1)
        }

        // ---- 5. 组 .app ----------------------------------------------------
        log.append("[4/6] 组装 .app…")
        do {
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            try writeInfoPlist(to: app.appendingPathComponent("Info.plist"),
                               name: appName, bundleID: bundle)
            log.append("      \(app.path)")
            log.append("      Info.plist：\(app.appendingPathComponent("Info.plist").path)")
        } catch {
            log.append("ERR 写 .app 失败：\(error.localizedDescription)")
            return finish("", code: 1)
        }

        // ---- 6. 签名 -------------------------------------------------------
        log.append("[5/6] 签名主可执行文件…")
        let entData: Data
        do {
            entData = try entitlementsData()
            try entData.write(to: entitlements)
            log.append("      entitlements：\(entitlements.path)")
        } catch {
            log.append("ERR 生成 entitlements 失败：\(error.localizedDescription)")
            return finish("", code: 1)
        }

        var signed = false
        do {
            try NanoMuseMachSigner.sign(path: binary.path,
                                        entitlements: entData,
                                        identifier: bundle)
            signed = NanoMuseMachSigner.hasSignature(path: binary.path)
            log.append("      NanoMuseMachSigner：\(signed ? "已签名 ✓" : "未写入 LC_CODE_SIGNATURE ✗")")
        } catch {
            log.append("      NanoMuseMachSigner 失败：\(error.localizedDescription)")
        }
        if !signed, NanoMuseHelperRunner.exists("codex-sign") {
            log.append("      回退 codex-sign --entitlements…")
            let run = await Task.detached(priority: .userInitiated) {
                NanoMuseHelperRunner.run("codex-sign",
                                         arguments: ["--entitlements", entitlements.path, binary.path],
                                         timeout: 180)
            }.value
            log.append(indent(run.output))
            signed = run.exitCode == 0 || NanoMuseMachSigner.hasSignature(path: binary.path)
            log.append("      codex-sign rc=\(run.exitCode) · \(signed ? "已签名" : "仍无签名")")
        }
        if !signed {
            log.append("ERR 签名失败：可执行文件没有 LC_CODE_SIGNATURE，TrollStore 会拒绝安装。")
            return finish("", code: 1)
        }

        // ---- 7. 打包 -------------------------------------------------------
        log.append("[6/6] 打包 .tipa（NanoMuseTipaBuilder）…")
        let outputName = normalizedOutputName(output, appName: appName)
        guard !outputName.isEmpty else {
            log.append("ERR 非法输出文件名：\(output ?? "")")
            return finish("", code: 1)
        }
        let report = await NanoMuseTipaBuilder.build(appPath: app.path,
                                                     entitlements: entitlements.path,
                                                     outputName: outputName)
        log.append(report.text)
        guard report.ok, let tipa = report.tipa else {
            log.append("ERR 打包失败")
            return finish("", code: 1)
        }
        let tipaURL = URL(fileURLWithPath: tipa)
        let tipaSize = ((try? fm.attributesOfItem(atPath: tipaURL.path))?[.size] as? NSNumber)?.intValue ?? 0
        log.append("")
        log.append("编译：成功（\(sources.count) 个源文件 → 1 个 .o）")
        log.append("链接：成功（\(binarySize) B，arm64e）")
        log.append("Bundle（临时）：\(app.path)")
        log.append("    打包完成后临时目录会删除；可安装产物在下方 TIPA 路径。")
        log.append("签名：NanoMuseMachSigner（platform-application / get-task-allow / no-container）")
        log.append("TIPA：\(tipaURL.path)（\(tipaSize) B）")
        log.append("安装：用 TrollStore / Filza 打开该 .tipa 即可。")
        cleanedUp = true
        return finish("", code: 0)
    }

    // MARK: - 源码与命名

    private static func expand(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).expandingTildeInPath
    }

    private static func swiftFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: directory,
                                                         includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles],
                                                         errorHandler: nil) else { return [] }
        var files: [URL] = []
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, file.pathExtension.lowercased() == "swift" else { continue }
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func defaultName(for url: URL) -> String {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue {
            return url.lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func sanitizedName(_ raw: String?, fallback: String) -> String {
        let candidate = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let base = candidate.isEmpty ? fallback : candidate
        let allowed = CharacterSet.alphanumerics
        let cleaned = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "SwiftApp" : trimmed
    }

    private static func normalizedBundleID(_ raw: String?, appName: String) -> String {
        let candidate = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty { return candidate }
        let slug = appName.lowercased().replacingOccurrences(of: " ", with: "-")
        return "com.nanocode.\(slug)"
    }

    private static func normalizedOutputName(_ raw: String?, appName: String) -> String {
        let requested = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = sanitizedFileName(requested)
        let fallbackName = sanitizedName(appName, fallback: "SwiftApp")
        let chosen = candidate.isEmpty ? fallbackName : candidate
        let withExtension = chosen.lowercased().hasSuffix(".tipa") ? chosen : chosen + ".tipa"
        let safe = sanitizedFileName(withExtension)
        return safe.isEmpty ? "SwiftApp.tipa" : safe
    }

    /// 输出只允许文件名，不接受路径；避免把 tipa 写到 Documents 之外。
    private static func sanitizedFileName(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let name = (raw as NSString).lastPathComponent
        guard name != ".", name != ".." else { return "" }
        return name
    }

    // MARK: - Info.plist / entitlements

    private static func writeInfoPlist(to url: URL, name: String, bundleID: String) throws {
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": name,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSRequiresIPhoneOS": true,
            "MinimumOSVersion": minimumOS,
            "UIDeviceFamily": [1, 2],
            "CFBundleSupportedPlatforms": ["iPhoneOS"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml,
                                                      options: 0)
        try data.write(to: url)
    }

    /// 运行时生成 entitlements（不依赖 Tools/entitlements-app.plist 的绝对路径）。
    /// 键与 Tools/entitlements-app.plist 中 TrollStore 必需的三项一致，并保留
    /// 宿主 App 已有的 no-sandbox / disable-library-validation，便于加载 SDK 资源。
    private static func entitlementsData() throws -> Data {
        let values: [String: Any] = [
            "platform-application": true,
            "get-task-allow": true,
            "com.apple.private.security.no-container": true,
            "com.apple.private.security.container-required": false,
            "com.apple.private.security.no-sandbox": true,
            "com.apple.private.security.disable-library-validation": true,
        ]
        return try PropertyListSerialization.data(fromPropertyList: values,
                                                  format: .xml,
                                                  options: 0)
    }

    // MARK: - Mach-O 描述

    /// 读取 Mach-O 头，返回 `MH_EXECUTE arm64e` 这类摘要。
    private static func machoDescription(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "不可读" }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 16 else { return "太短" }
        let bytes = [UInt8](data)
        func le32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        guard le32(0) == 0xFEEDFACF else { return "非 MH_MAGIC_64" }
        let cpu = le32(4)
        let type = le32(12)
        let cpuName: String
        switch cpu {
        case 0x0100000C: cpuName = "arm64e"
        case 0x01000007: cpuName = "arm64"
        default: cpuName = String(format: "cpu=0x%08x", cpu)
        }
        let typeName = type == 2 ? "MH_EXECUTE" : String(format: "type=%u", type)
        return "\(typeName) \(cpuName)"
    }

    private static func indent(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "      " + String($0) }
            .joined(separator: "\n")
    }

    /// SDK 下载进度回调是任意线程；只保存 0/20/…/100% 这些档位。
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<Int> = []
        private var values: [Int] = []

        func record(_ ratio: Double) {
            let pct = max(0, min(100, Int((ratio * 100).rounded())))
            guard pct % 20 == 0 else { return }
            lock.lock()
            defer { lock.unlock() }
            guard seen.insert(pct).inserted else { return }
            values.append(pct)
        }

        func lines() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return values.sorted().map { "      下载/解包 \($0)%" }
        }
    }
}
