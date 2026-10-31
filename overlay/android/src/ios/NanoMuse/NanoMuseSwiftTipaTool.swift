import Foundation

/// `swift_tipa`：C / Objective-C / Objective-C++ / Swift 源码 → 编译 → 链接
/// → .app → 签名 → .tipa。
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

    /// 可以编译的源码扩展名（小写，不带点）。
    static let supportedExtensions: Set<String> = ["swift", "c", "m", "mm"]

    /// 看起来是源码、但本工具不支持的扩展名；目录里出现时直接报错，避免静默漏编。
    private static let unsupportedSourceExtensions: Set<String> = [
        "cc", "cpp", "cxx", "c++",
        "s", "asm", "cs", "java", "kt", "kts", "rs", "go",
        "js", "jsx", "ts", "tsx", "py", "rb", "php", "lua", "dart",
    ]

    static var definition: AgentToolDefinition {
        AgentToolDefinition(
            name: toolName,
            description: """
            Compile an iOS GUI app written in C, Objective-C, Objective-C++ or Swift directly \
            into an installable .tipa on the iPhone, in-process (no fork, no iSH). Pass one source \
            file (.swift/.c/.m/.mm) or a directory containing them; every source file is compiled \
            to its own .o for arm64e with CoreCompiler, then linked against the installed iPhoneOS \
            SDK, assembled into a minimal .app bundle, signed with TrollStore entitlements and \
            packaged as Payload/ inside a .tipa. Mixed-language projects are supported \
            (e.g. main.swift + helper.c). Swift sources must call UIApplicationMain themselves \
            (otherwise the app shows a black screen or crashes on launch). For Swift calling into \
            Objective-C, a Bridging-Header.h (or <Name>-Bridging-Header.h) next to the sources is \
            picked up automatically as -import-objc-header; without one, Swift only sees Swift \
            modules. The absolute .tipa path is returned and can be opened with TrollStore.
            """,
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user. Use the user's language."),
                "source": AgentToolParam(type: .string, description: "Absolute path to a .swift/.c/.m/.mm file, or a directory searched recursively for those four extensions (mixed-language projects allowed)."),
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
            log.append("ERR 缺少 source：请传 .swift / .c / .m / .mm 文件或目录的绝对路径")
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
            let directory = URL(fileURLWithPath: input, isDirectory: true)
            sources = sourceFiles(in: directory)
            log.append("源目录：\(input)")
            log.append("发现 \(sources.count) 个源文件：")
            for file in sources { log.append("  · \(file.path)") }
            guard !sources.isEmpty else {
                log.append("ERR 目录下没有 .swift / .c / .m / .mm 源文件")
                return finish("", code: 1)
            }
            let unsupported = unsupportedSources(in: directory)
            guard unsupported.isEmpty else {
                log.append("ERR 目录里有不支持的源码扩展名：")
                for file in unsupported { log.append("  · \(file.path)") }
                log.append("    仅支持 .swift / .c / .m / .mm；请移除或改写这些文件后重试。")
                return finish("", code: 1)
            }
        } else {
            let ext = URL(fileURLWithPath: input).pathExtension.lowercased()
            guard supportedExtensions.contains(ext) else {
                log.append("ERR 不支持的源码扩展名「.\(ext)」：\(input)")
                log.append("    仅支持 .swift / .c / .m / .mm。")
                return finish("", code: 1)
            }
            sources = [URL(fileURLWithPath: input)]
            log.append("源文件：\(input)")
        }

        let swiftSources = sources.filter { $0.pathExtension.lowercased() == "swift" }
        let objcSources = sources.filter {
            let ext = $0.pathExtension.lowercased()
            return ext == "m" || ext == "mm"
        }
        let cxxSources = sources.filter { $0.pathExtension.lowercased() == "mm" }
        let clangSources = sources.filter { $0.pathExtension.lowercased() != "swift" }
        log.append("语言构成：Swift \(swiftSources.count) · C \(clangSources.count - objcSources.count) · ObjC \(objcSources.count - cxxSources.count) · ObjC++ \(cxxSources.count)")

        let appName = sanitizedName(name, fallback: defaultName(for: URL(fileURLWithPath: input)))
        let bundle = normalizedBundleID(bundleID, appName: appName)
        log.append("App：\(appName)")
        log.append("Bundle ID：\(bundle)")

        // 只受理主入口在源码里出现的情况：GUI app 若没有 UIApplicationMain，
        // 装上去必然闪退/黑屏。这里不修改源码，只给出明确可操作的错误。
        let combined = sources.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        guard combined.contains("UIApplicationMain") else {
            log.append("ERR 源码缺少 UIApplicationMain —— 编出来是终端程序，安装后会闪退/黑屏。")
            log.append("    Swift 请以 UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self)) 结尾。")
            log.append("    C / ObjC / ObjC++ 请在 main() 里调用 UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]))。")
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
        log.append("[2/6] 编译源码（CoreCompiler：swiftc / clang）…")
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

        let moduleName = moduleIdentifier(appName)
        let includeDirs = headerSearchPaths(sources: sources, root: isDir.boolValue ? input : nil)
        let bridging = bridgingHeader(sources: sources,
                                      directory: isDir.boolValue ? input : nil,
                                      module: moduleName)
        if let bridging { log.append("Bridging header：\(bridging.path)") }
        log.append("Swift module：\(moduleName)")
        log.append("头文件搜索：\(includeDirs.isEmpty ? "（无）" : includeDirs.joined(separator: ", "))")

        let compiled = compileAll(loaded: loaded,
                                  swiftSources: swiftSources,
                                  clangSources: clangSources,
                                  objectsDir: objectsDir,
                                  sdk: sdk.path,
                                  res: res,
                                  moduleCache: moduleCache,
                                  moduleName: moduleName,
                                  includeDirs: includeDirs,
                                  bridgingHeader: bridging)
        log.append(contentsOf: compiled.lines)
        guard compiled.ok, !compiled.objects.isEmpty else {
            log.append("ERR 编译失败，未产出完整的目标文件集合。")
            return finish("", code: 1)
        }
        log.append("      目标文件 \(compiled.objects.count) 个：")
        for object in compiled.objects {
            let size = ((try? fm.attributesOfItem(atPath: object.path))?[.size] as? NSNumber)?.intValue ?? 0
            log.append("        · \(object.lastPathComponent)（\(size) B）")
        }

        // ---- 4. 链接 -------------------------------------------------------
        log.append("[3/6] 链接 executable（多目标文件）…")
        try? fm.removeItem(at: binary)
        let linkLog = NanoMuseNyxian.linkAppObjects(loaded: loaded,
                                                    objs: compiled.objects,
                                                    bin: binary,
                                                    sdk: sdk.path,
                                                    res: res,
                                                    work: work,
                                                    target: target,
                                                    frameworks: ["UIKit", "Foundation"],
                                                    objc: !objcSources.isEmpty,
                                                    cxx: !cxxSources.isEmpty,
                                                    swift: !swiftSources.isEmpty,
                                                    progress: { log.append(indent($0)) })
        log.append(indent(linkLog))
        let linkedSize = ((try? fm.attributesOfItem(atPath: binary.path))?[.size] as? NSNumber)?.intValue ?? 0
        let linked = linkedSize > 0
        guard linked, fm.fileExists(atPath: binary.path) else {
            log.append("ERR 链接失败：未产出可执行文件")
            log.append("    上面「缺符号」行即链接器报告的未解析符号；也可检查 SDK 的 usr/lib/swift、usr/lib/libobjc.tbd、usr/lib/libc++.tbd 是否完整。")
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
        log.append("编译：成功（\(sources.count) 个源文件 → \(compiled.objects.count) 个 .o）")
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

    /// 目录递归收集 `.swift` / `.c` / `.m` / `.mm`，按路径排序。
    private static func sourceFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(at: directory,
                                                         includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles],
                                                         errorHandler: nil) else { return [] }
        var files: [URL] = []
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true,
                  supportedExtensions.contains(file.pathExtension.lowercased()) else { continue }
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 目录里出现「像源码但不受支持」的扩展名时返回这些文件，让工具明确报错而不是静默漏编。
    private static func unsupportedSources(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory,
                                                         includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles],
                                                         errorHandler: nil) else { return [] }
        var files: [URL] = []
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            if unsupportedSourceExtensions.contains(file.pathExtension.lowercased()) {
                files.append(file)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 每个源文件所在目录 + 它们共同的工程根目录作为 `-I`，
    /// 支持 `#import "Local.h"` 与同目录/子目录头文件，又不会把 `/` 之类塞进搜索路径。
    private static func headerSearchPaths(sources: [URL], root: String?) -> [String] {
        var dirs = Set<String>()
        for source in sources { dirs.insert(source.deletingLastPathComponent().path) }
        if let root {
            dirs.insert(root)
        } else {
            var components = sources.first?.deletingLastPathComponent().pathComponents ?? []
            for source in sources.dropFirst() {
                let other = source.deletingLastPathComponent().pathComponents
                var shared: [String] = []
                for (a, b) in zip(components, other) {
                    guard a == b else { break }
                    shared.append(a)
                }
                components = shared
            }
            if components.count > 1 {
                dirs.insert(NSString.path(withComponents: components))
            }
        }
        return dirs.sorted()
    }

    /// 自动识别 bridging header：`<Module>-Bridging-Header.h`、
    /// `Bridging-Header.h`，或任意 `*-Bridging-Header.h`（取排序第一个）。
    private static func bridgingHeader(sources: [URL], directory: String?, module: String) -> URL? {
        let fm = FileManager.default
        var roots = Set<String>()
        if let directory { roots.insert(directory) }
        for source in sources where source.pathExtension.lowercased() == "swift" {
            roots.insert(source.deletingLastPathComponent().path)
        }
        let preferred = [module + "-Bridging-Header.h", "Bridging-Header.h"]
        for root in roots.sorted() {
            for name in preferred {
                let candidate = (root as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
            }
            let items = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            for name in items.sorted() where name.hasSuffix("-Bridging-Header.h") {
                let candidate = (root as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: candidate) { return URL(fileURLWithPath: candidate) }
            }
        }
        return nil
    }

    /// 每个源文件编成独立 `.o`；Swift 用 `-primary-file` 逐文件编，`-module-name` 保持一致。
    /// 若某个 Swift 文件单独编译失败，再退回「全部 Swift 一次编成一个 .o」（原有可用路径）。
    private static func compileAll(loaded: NanoMuseNyxian.Loaded,
                                   swiftSources: [URL],
                                   clangSources: [URL],
                                   objectsDir: URL,
                                   sdk: String,
                                   res: String,
                                   moduleCache: URL,
                                   moduleName: String,
                                   includeDirs: [String],
                                   bridgingHeader: URL?) -> (ok: Bool, objects: [URL], lines: [String]) {
        let fm = FileManager.default
        let frameworks = sdk + "/System/Library/Frameworks"
        // UIKit 等框架的头文件会 include 同级的 SubFrameworks（如 UIUtilities），
        // 只加 Frameworks 会报 "module includes header from ... SubFrameworks"
        let subFrameworks = sdk + "/System/Library/SubFrameworks"
        var log: [String] = []
        var index = 0
        var swiftObjects: [URL] = []
        var clangObjects: [URL] = []
        var swiftPerFileOK = true
        var usedWholeModule = false
        var clangOK = true

        func objectURL(for source: URL) -> URL {
            index += 1
            let base = source.lastPathComponent.replacingOccurrences(of: ".", with: "_")
            let prefix = String(index)
            let padded = String(repeating: "0", count: max(0, 3 - prefix.count)) + prefix
            return objectsDir.appendingPathComponent(padded + "_" + base + ".o")
        }

        func swiftBaseArgs() -> [String] {
            var args = ["-target", target,
                        "-sdk", sdk,
                        "-isysroot", sdk,
                        "-F", frameworks,
                        "-F", subFrameworks,
                        "-I", sdk + "/usr/lib/swift",
                        "-L", sdk + "/usr/lib/swift",
                        "-module-cache-path", moduleCache.path]
            if !res.isEmpty { args += ["-resource-dir", res] }
            args += ["-module-name", moduleName]
            for dir in includeDirs { args += ["-I", dir] }
            if let bridgingHeader { args += ["-import-objc-header", bridgingHeader.path] }
            return args
        }

        // 每个 .swift 编成独立 .o：多文件时用 -primary-file，其余文件作为同模块输入，
        // -module-name 保持一致。若逐文件失败，再回退为整模块一次编译（旧路径）。
        for source in swiftSources {
            let object = objectURL(for: source)
            try? fm.removeItem(at: object)
            var args = swiftBaseArgs()
            if swiftSources.count > 1 {
                args += ["-c", "-primary-file", source.path]
                args += swiftSources.filter { $0 != source }.map(\.path)
            } else {
                args += ["-c", source.path]
            }
            args += ["-o", object.path]

            log.append("      [swift] \(source.path)")
            let started = Date()
            let result = loaded.run(args, swift: true)
            let size = ((try? fm.attributesOfItem(atPath: object.path))?[.size] as? NSNumber)?.intValue ?? 0
            log.append("      ok=\(result.ok) · \(String(format: "%.1fs", Date().timeIntervalSince(started))) · \(size) B")
            log.append(indent(result.log))
            guard result.ok, fm.fileExists(atPath: object.path), size > 0 else {
                swiftPerFileOK = false
                log.append("ERR Swift 编译失败：\(source.path)")
                log.append("    常见原因：缺少 Swift 资源目录、SDK 不匹配、源码语法错误、bridging header 路径不对。")
                continue
            }
            swiftObjects.append(object)
        }

        if !swiftPerFileOK, swiftSources.count > 1 {
            log.append("      逐文件 Swift 编译失败，回退为整模块一次编译…")
            swiftObjects = []
            let object = objectsDir.appendingPathComponent("swift-whole-module.o")
            try? fm.removeItem(at: object)
            var args = swiftBaseArgs()
            args += ["-emit-object", "-o", object.path]
            args += swiftSources.map(\.path)
            let result = loaded.run(args, swift: true)
            let size = ((try? fm.attributesOfItem(atPath: object.path))?[.size] as? NSNumber)?.intValue ?? 0
            log.append("      [swift] 整模块（\(swiftSources.count) 个文件）ok=\(result.ok) · \(size) B")
            log.append(indent(result.log))
            if result.ok, fm.fileExists(atPath: object.path), size > 0 {
                swiftObjects = [object]
                usedWholeModule = true
            } else {
                log.append("ERR Swift 整模块编译失败")
                log.append("    常见原因：缺少 Swift 资源目录、SDK 不匹配、源码语法错误、bridging header 路径不对。")
            }
        }

        for source in clangSources {
            let ext = source.pathExtension.lowercased()
            let object = objectURL(for: source)
            try? fm.removeItem(at: object)
            var args = ["-target", target,
                        "-isysroot", sdk,
                        "-F", frameworks,
                        "-F", subFrameworks,
                        "-c", source.path,
                        "-o", object.path]
            if ext == "m" || ext == "mm" {
                args += ["-fobjc-runtime=ios-26.5", "-fobjc-arc"]
            }
            if ext == "mm" {
                // ObjC++：需要 C++ 标准库
                args += ["-x", "objective-c++", "-stdlib=libc++"]
            }
            for dir in includeDirs { args += ["-I", dir] }

            log.append("      [\(ext)] \(source.path)")
            let started = Date()
            let result = loaded.run(args, swift: false)
            let size = ((try? fm.attributesOfItem(atPath: object.path))?[.size] as? NSNumber)?.intValue ?? 0
            log.append("      ok=\(result.ok) · \(String(format: "%.1fs", Date().timeIntervalSince(started))) · \(size) B")
            log.append(indent(result.log))
            guard result.ok, fm.fileExists(atPath: object.path), size > 0 else {
                clangOK = false
                log.append("ERR \(ext.uppercased()) 编译失败：\(source.path)")
                continue
            }
            clangObjects.append(object)
        }

        let objects = swiftObjects + clangObjects
        let swiftOK: Bool
        if swiftSources.isEmpty {
            swiftOK = true
        } else if swiftSources.count == 1 {
            swiftOK = swiftObjects.count == 1
        } else if usedWholeModule {
            // 整模块成功：只产出一个合并后的 .o
            swiftOK = swiftObjects.count == 1
        } else {
            // 逐文件编译：每个源文件各一个 .o
            swiftOK = swiftObjects.count == swiftSources.count
        }
        return (swiftOK && clangOK && !objects.isEmpty, objects, log)
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

    /// Swift 的 `-module-name` 必须是合法标识符（不能以数字开头），与 App 名解耦。
    private static func moduleIdentifier(_ appName: String) -> String {
        var identifier = appName.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if identifier.isEmpty { identifier = "App" }
        if let first = identifier.first, first.isNumber {
            identifier = "App" + identifier
        }
        return identifier
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
