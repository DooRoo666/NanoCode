//
//  NanoMuseNyxian.swift
//  Nyxian CoreCompiler（clang / swiftc / ld64）的宿主侧封装。
//
//  Nyxian 把 clang、Swift driver、ld64 全部编进了 CoreCompiler.framework，
//  对外只暴露一组 C API：argv → driver → jobs → 逐个执行。
//  这里不碰 MobileDevelopmentKit（它是 Swift 类，框架里既无 headers 也无
//  .swiftmodule，只能反射猜 selector），直接用 C API。
//
//  API 形状来自 Nyxian 0.10.3 的源码（CoreCompiler/CCBase.h、Tools/CCSDK.h、
//  Support/CCJob.h、Tools/CCDriver.h），与二进制导出的符号一致。
//

import Foundation
import CoreFoundation
import Darwin

enum NanoMuseNyxian {

    // MARK: - 路径

    static var documents: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
    }

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NanoCodex/nyxian", isDirectory: true)
    }

    /// 包内可写运行时根（打包时已 chown 501:501 / chmod 0777）。
    /// 只有放在 App 包内的代码才能被 dlopen：包外（Documents 等）在 iOS 16 + TrollStore
    /// 下由内核 AMFI 判定，只认 Apple 真证书或 TrustCache，伪造 CMS 也报
    /// `code signature invalid`；巨魔只放行 exec（同一目录的可执行文件能跑）。
    static var runtimes: URL {
        URL(fileURLWithPath: Bundle.main.bundlePath).appendingPathComponent("Runtimes", isDirectory: true)
    }

    /// CoreCompiler 的查找顺序：包内可写 Runtimes > bundle Frameworks > 容器 Documents > App Support > iSH 桥。
    static var frameworkCandidates: [String] {
        [
            runtimes.appendingPathComponent("frameworks/CoreCompiler.framework/CoreCompiler").path,
            Bundle.main.bundlePath + "/Frameworks/CoreCompiler.framework/CoreCompiler",
            documents.appendingPathComponent("nyxian/CoreCompiler.framework/CoreCompiler").path,
            support.appendingPathComponent("CoreCompiler.framework/CoreCompiler").path,
            "/var/mobile/Documents/nyxian/CoreCompiler.framework/CoreCompiler",
            "/var/mobile/Documents/alpine-rootfs/data/var/minis/workspace/nyxian/CoreCompiler.framework/CoreCompiler",
        ]
    }

    /// 解包后的 iPhoneOS SDK 目录（bootstrap zip 解到这里）。
    static var sdkCandidates: [URL] {
        let roots = [runtimes.appendingPathComponent("sdks", isDirectory: true),
                     documents.appendingPathComponent("nyxian", isDirectory: true),
                     support]
        var out: [URL] = []
        let fm = FileManager.default
        for root in roots {
            if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension == "sdk" {
                    out.append(item)
                }
            }
            let nested = root.appendingPathComponent("sdk", isDirectory: true)
            if let items = try? fm.contentsOfDirectory(at: nested, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension == "sdk" {
                    out.append(item)
                }
            }
        }
        return out
    }

    // MARK: - C API 签名（参数一律按裸指针传递，避免 CF 桥接类型在
    //          @convention(c) 里的兼容问题）

    typealias FnDriverCreate = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt8) -> UnsafeMutableRawPointer?
    typealias FnDriverCreateJobs = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias FnDriverCopySDK = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias FnDriverCopySysroot = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias FnJobGetType = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
    typealias FnJobExecute = @convention(c) (UnsafeMutableRawPointer?,
                                                     UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                                                     UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UInt8
    typealias FnJobSupportsMT = @convention(c) (UInt8) -> UInt8
    typealias FnSDKCreate = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias FnSDKCopyVersion = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias FnDiagGetMessage = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    typealias FnDiagGetLevel = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
    typealias FnMaxCores = @convention(c) () -> Int32

    /// 一份已经 dlopen 好的 CoreCompiler。
    final class Loaded {
        let path: String
        let handle: UnsafeMutableRawPointer
        let driverCreate: FnDriverCreate
        let driverCreateJobs: FnDriverCreateJobs
        let driverCopySDK: FnDriverCopySDK
        let driverCopySysroot: FnDriverCopySysroot?
        let jobGetType: FnJobGetType
        let jobExecute: FnJobExecute
        let jobSupportsMT: FnJobSupportsMT?
        let sdkCreate: FnSDKCreate?
        let sdkCopyVersion: FnSDKCopyVersion?
        let diagGetMessage: FnDiagGetMessage?
        let diagGetLevel: FnDiagGetLevel?
        let maximumCores: FnMaxCores?

        init(path: String, handle: UnsafeMutableRawPointer) throws {
            self.path = path
            self.handle = handle

            func req<T>(_ name: String) throws -> T {
                guard let sym = dlsym(handle, name) else {
                    throw NanoMuseNyxian.Error.missingSymbol(name)
                }
                return unsafeBitCast(sym, to: T.self)
            }
            func opt<T>(_ name: String) -> T? {
                guard let sym = dlsym(handle, name) else { return nil }
                return unsafeBitCast(sym, to: T.self)
            }

            driverCreate = try req("CCDriverCreate")
            driverCreateJobs = try req("CCDriverCreateJobs")
            driverCopySDK = try req("CCDriverCopySDK")
            driverCopySysroot = opt("CCDriverCopySysrootURL")
            jobGetType = try req("CCJobGetType")
            jobExecute = try req("CCJobExecuteJob")
            jobSupportsMT = opt("CCJobTypeSupportsMultithreading")
            let createFromFile: FnSDKCreate? = opt("CCSDKCreateWithFileURL")
            let createFromDirectory: FnSDKCreate? = opt("CCSDKCreateWithDirectoryURL")
            sdkCreate = createFromFile ?? createFromDirectory
            sdkCopyVersion = opt("CCSDKCopyVersion")
            diagGetMessage = opt("CCDiagnosticGetMessage")
            diagGetLevel = opt("CCDiagnosticGetLevel")
            maximumCores = opt("CCGetMaximumPerformanceCores")
        }

        // MARK: 执行

        /// 跑一次 driver（等价于一次 clang 命令行）。返回是否全部成功 + 日志。
        func run(_ args: [String], swift: Bool = false) -> (ok: Bool, log: String) {
            var log: [String] = []
            log.append("argv: " + args.joined(separator: " "))

            let cfArgs = NanoMuseNyxian.cfArray(args)
            defer { NanoMuseNyxian.cfRelease(cfArgs) }

            let driver = swift ? driverCreate(nil, cfArgs, 1) : driverCreate(nil, cfArgs, 0)
            guard let driver = driver else {
                return (false, log.joined(separator: "\n") + "\nCCDriverCreate 返回 nil（argv 被拒）")
            }
            defer { NanoMuseNyxian.cfRelease(driver) }

            if let sdk = driverCopySDK(driver) {
                var version = "?"
                if let versionPtr = sdkCopyVersion?(sdk) {
                    version = NanoMuseNyxian.cfString(versionPtr) ?? "?"
                }
                log.append("driver 解析到 SDK: \(version)")
                NanoMuseNyxian.cfRelease(sdk)
            } else {
                log.append("driver 没解析到 SDK（缺 -isysroot？）")
            }
            if let sysrootPtr = driverCopySysroot?(driver) {
                log.append("sysroot: " + (NanoMuseNyxian.cfString(sysrootPtr) ?? "?"))
                NanoMuseNyxian.cfRelease(sysrootPtr)
            }

            guard let jobsPtr = driverCreateJobs(driver) else {
                return (false, log.joined(separator: "\n") + "\nCCDriverCreateJobs 返回 nil")
            }
            let jobs = Unmanaged<CFArray>.fromOpaque(jobsPtr).takeRetainedValue()
            let count = CFArrayGetCount(jobs)
            log.append("jobs: \(count)")

            var allOK = true
            for i in 0..<count {
                guard let rawJob = CFArrayGetValueAtIndex(jobs, i) else { continue }
                let job = UnsafeMutableRawPointer(mutating: rawJob)
                let type = jobGetType(job)
                var diags: UnsafeMutableRawPointer?
                var mainSource: UnsafeMutableRawPointer?
                let ok = jobExecute(job, &diags, &mainSource) != 0
                if let mainSource { NanoMuseNyxian.cfRelease(mainSource) }
                let typeName = NanoMuseNyxian.jobTypeName(type)
                log.append("job#\(i) type=\(typeName) -> \(ok ? "ok" : "failed")")

                if let diags {
                    let arr = Unmanaged<CFArray>.fromOpaque(diags).takeRetainedValue()
                    for d in 0..<CFArrayGetCount(arr) {
                        guard let raw = CFArrayGetValueAtIndex(arr, d) else { continue }
                        let diag = UnsafeMutableRawPointer(mutating: raw)
                        let level = diagGetLevel?(diag) ?? 0
                        let message = diagGetMessage?(diag).flatMap { NanoMuseNyxian.cfString($0) } ?? "(no message)"
                        log.append("  [\(NanoMuseNyxian.levelName(level))] \(message)")
                    }
                }
                if !ok { allOK = false }
            }
            return (allOK, log.joined(separator: "\n"))
        }
    }

    enum Error: Swift.Error, CustomStringConvertible {
        case notFound([String])
        case dlopenFailed(String, String)
        case missingSymbol(String)
        case failed(String)

        var description: String {
            switch self {
            case .notFound(let paths): return "找不到 CoreCompiler：" + paths.joined(separator: " | ")
            case .dlopenFailed(let path, let message): return "dlopen(\(path)) 失败：\(message)"
            case .missingSymbol(let name): return "缺符号 \(name)"
            case .failed(let detail): return detail
            }
        }
    }

    // MARK: - 加载

    private static var cached: Loaded?
    private static let lock = NSLock()
    private(set) static var lastPreloadNotes: [String] = []

    /// CoreCompiler 内部那 13 个 `@rpath/lib_Compiler*.dylib` 没有可用的 rpath，
    /// 先按绝对路径 dlopen 成 GLOBAL，dyld 解析依赖时能按 install name 命中已加载映像。
    @discardableResult
    static func preloadNested(around frameworkPath: String) -> [String] {
        let dir = URL(fileURLWithPath: frameworkPath)
            .deletingLastPathComponent()
            .appendingPathComponent("Frameworks", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var notes: [String] = []
        for name in items.sorted() where name.hasSuffix(".dylib") {
            let path = dir.appendingPathComponent(name).path
            if dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil {
                notes.append("ok \(name)")
            } else {
                notes.append("fail \(name): " + (dlerror().map { String(cString: $0) } ?? "?"))
            }
        }
        return notes
    }

    static func load() -> Result<Loaded, Error> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return .success(cached) }

        var tried: [String] = []
        var failures: [String] = []
        for path in frameworkCandidates {
            tried.append(path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            lastPreloadNotes = preloadNested(around: path)
            guard let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
                let message = dlerror().map { String(cString: $0) } ?? "unknown"
                failures.append("dlopen(\(path)) 失败：\(message)")
                continue
            }
            do {
                let loaded = try Loaded(path: path, handle: handle)
                cached = loaded
                return .success(loaded)
            } catch let error as Error {
                failures.append(error.description)
            } catch {
                failures.append("\(error)")
            }
        }
        if failures.isEmpty { return .failure(.notFound(tried)) }
        return .failure(.failed(failures.joined(separator: " | ")))
    }

    static var isAvailable: Bool {
        if case .success = load() { return true }
        return false
    }

    // MARK: - 编译

    /// 把一组源文件编成可执行文件（够跑 hello world 的最小链路）。
    static func buildExecutable(sources: [URL], output: URL, target: String = "arm64-apple-ios16.0") -> (ok: Bool, log: String) {
        switch load() {
        case .failure(let error):
            return (false, "\(error)")
        case .success(let toolchain):
            var args = ["clang", "-target", target, "-O1"]
            if let sdk = detectSDK() {
                args += ["-isysroot", sdk.path]
            }
            args += ["-o", output.path]
            args += sources.map { $0.path }
            let result = toolchain.run(args)
            let exists = FileManager.default.fileExists(atPath: output.path)
            return (result.ok && exists, result.log + "\n产物: \(exists ? "已生成 \(fileSize(output))" : "缺失")")
        }
    }

    /// 编译单个源文件到目标文件（不需要 SDK，适用于无 include 的探针）。
    static func compileObject(source: URL, output: URL, target: String = "arm64-apple-ios16.0") -> (ok: Bool, log: String) {
        switch load() {
        case .failure(let error):
            return (false, "\(error)")
        case .success(let toolchain):
            let args = ["clang", "-target", target, "-c", source.path, "-o", output.path]
            let result = toolchain.run(args)
            let exists = FileManager.default.fileExists(atPath: output.path)
            return (result.ok && exists, result.log + "\n产物: \(exists ? "已生成 \(fileSize(output))" : "缺失")")
        }
    }

    static func detectSDK() -> URL? {
        let fm = FileManager.default
        for url in sdkCandidates where fm.fileExists(atPath: url.path) { return url }
        return nil
    }

    // MARK: - 自检

    /// 端到端探针：dlopen → 导出符号 → 编译 hello.c → 链接成 Mach-O。
    /// 不需要 SDK：探针源码不 include 任何头文件。
    static func selfTest() -> String {
        var out: [String] = []
        let stamp = ISO8601DateFormatter().string(from: Date())
        out.append("=== Nyxian 工具链自检 \(stamp) ===")
        out.append("bundle: \(Bundle.main.bundlePath)")

        // 包内可写运行时根：决定 App 能不能自己把编译器 / dylib / SDK 下载进来
        let fm = FileManager.default
        let root = runtimes
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let probe = root.appendingPathComponent(".wtest")
        var writable = false
        if (try? "ok".write(to: probe, atomically: true, encoding: .utf8)) != nil {
            writable = true
            try? fm.removeItem(at: probe)
        }
        let attrs = (try? fm.attributesOfItem(atPath: root.path)) ?? [:]
        let owner = attrs[.ownerAccountID] as? Int ?? -1
        let perm = attrs[.posixPermissions] as? Int ?? -1
        out.append("运行时根: \(root.path) \(writable ? "可写 ✅" : "不可写 ❌") owner=\(owner) mode=\(String(perm, radix: 8))")

        for path in frameworkCandidates {
            let exists = FileManager.default.fileExists(atPath: path)
            let size = exists ? fileSize(URL(fileURLWithPath: path)) : "-"
            out.append("候选: \(path) \(exists ? "[有 \(size)]" : "[无]")")
        }

        switch load() {
        case .failure(let error):
            out.append("加载失败: \(error)")
            return out.joined(separator: "\n")
        case .success(let toolchain):
            out.append("已加载: \(toolchain.path)")
            out.append("性能核数: \(toolchain.maximumCores?() ?? -1)")
            if !lastPreloadNotes.isEmpty {
                out.append("嵌套库预加载: ")
                for note in lastPreloadNotes { out.append("  · \(note)") }
            }
            out.append("SDK: \(detectSDK()?.path ?? "未安装（编译无 include 的源码不受影响）")")
            out.append("Swift 资源: \(detectSwiftResources()?.path ?? "未安装（-resource-dir 缺省）")")
        }

        let work = documents.appendingPathComponent("nyxian-out", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let source = work.appendingPathComponent("probe.c")
        let object = work.appendingPathComponent("probe.o")
        let binary = work.appendingPathComponent("probe")
        let code = "int main(void) { return 42; }\n"
        do {
            try code.write(to: source, atomically: true, encoding: .utf8)
        } catch {
            out.append("写探针源码失败: \(error)")
            return out.joined(separator: "\n")
        }

        let started = Date()
        let compiled = compileObject(source: source, output: object)
        out.append("--- 编译 (\(String(format: "%.1fs", Date().timeIntervalSince(started))))")
        out.append(compiled.log)
        out.append("object header: \(firstBytes(object))")

        let linked = buildExecutable(sources: [object], output: binary)
        out.append("--- 链接")
        out.append(linked.log)
        out.append("binary header: \(firstBytes(binary))")
        out.append(linked.ok ? "结论: 工具链可用 ✅" : "结论: 链路有断点 ❌")

        // --- Swift 编译探针：多组参数，取第一组成功的
        let probeFlag = documents.appendingPathComponent("nyxian-probe-enable").path
        if case .success(let toolchain) = load(), FileManager.default.fileExists(atPath: probeFlag) {
            let sres = swiftProbe(loaded: toolchain, work: work)
            out.append("--- Swift 编译")
            out.append(sres.log)
            out.append(sres.ok ? "SWIFT_OK: swiftc 可用 ✅" : "SWIFT_FAIL: swiftc 未打通 ❌")
        } else {
            out.append("SWIFT_SKIP: 框架未加载")
        }
        return out.joined(separator: "\n")
    }

    /// 自检并写入 Documents/nyxian-diag.txt（外部可直接读，不用点 UI）。
    @discardableResult
    static func writeDiagnostics() -> String {
        let text = selfTest()
        let url = documents.appendingPathComponent("nyxian-diag.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return text
    }

    /// 监听参数文件：App 只要还活在前台，改 Documents/nyxian-swift-args.txt 就会重跑 Swift 探测，
    /// 不用杀进程重启（迭代编译参数时省掉每次重开 App）。
    static var swiftWatch: Task<Void, Never>?

    static func startSwiftWatch() {
        guard swiftWatch == nil else { return }
        let fm0 = FileManager.default
        let cfg = documents.appendingPathComponent("nyxian-swift-args.txt")
        if !fm0.fileExists(atPath: cfg.path) {
            try? "# ID|source|额外参数\n".write(to: cfg, atomically: true, encoding: .utf8)
        }
        swiftWatch = Task.detached(priority: .utility) {
            let fm = FileManager.default
            let out = documents.appendingPathComponent("nyxian-diag.txt")
            let work = documents.appendingPathComponent("nyxian-out", isDirectory: true)
            func stamp() -> TimeInterval {
                let a = (try? fm.attributesOfItem(atPath: cfg.path)) as? [FileAttributeKey: Any] ?? [:]
                return (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            }
            var last = stamp()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let now = stamp()
                if now != last {
                    last = now
                    try? fm.createDirectory(at: work, withIntermediateDirectories: true)
                    let flag = documents.appendingPathComponent("nyxian-probe-enable")
                    guard fm.fileExists(atPath: flag.path) else { continue }
                    guard case .success(let toolchain) = load() else { continue }
                    let r = swiftProbe(loaded: toolchain, work: work)
                    let text = "\n=== 手动触发 Swift 探测 \(ISO8601DateFormatter().string(from: Date())) ===\n"
                        + r.log + "\n" + (r.ok ? "SWIFT_OK: swiftc 可用 ✅" : "SWIFT_FAIL: swiftc 未打通 ❌") + "\n"
                    if let handle = try? FileHandle(forWritingTo: out) {
                        handle.seekToEndOfFile()
                        handle.write(text.data(using: .utf8) ?? Data())
                        try? handle.close()
                    }
                }
            }
        }
    }

    // MARK: - Swift

    /// 找 swiftc 需要的资源目录（clang 内建头 / swift migrator / libclang_rt）。
    static func detectSwiftResources() -> URL? {
        let fm = FileManager.default
        let paths = [
            runtimes.appendingPathComponent("toolchains/nyxian").path,
            runtimes.appendingPathComponent("toolchains").path,
            documents.appendingPathComponent("nyxian/Shared").path,
            documents.appendingPathComponent("nyxian").path,
            support.appendingPathComponent("nyxian/Shared").path,
            "/var/mobile/Documents/alpine-rootfs/data/var/minis/workspace/nyxian/Shared",
        ]
        for p in paths {
            if fm.fileExists(atPath: p + "/swift") || fm.fileExists(atPath: p + "/include") {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    /// 在 fork 出的子进程里执行编译。
    /// CoreCompiler 在失败路径上有 CFRelease(NULL) 的坑，会把宿主进程直接带崩；
    /// 放进子进程后崩溃只杀子进程，父进程拿到信号号，自检不会闪退。
    /// iOS 的 Swift Darwin overlay 把 fork() 标成 unavailable（编译期就报错），
    /// 这里 dlsym 取地址绕过声明检查；运行时被系统拒绝就退回进程内执行。
    private static func callFork() -> Int32 {
        guard let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "fork") else { return -1 }
        let sym = unsafeBitCast(s, to: (@convention(c) () -> Int32).self)
        return sym()
    }

    static func isoRun(loaded: Loaded, args: [String], swift: Bool, work: URL) -> (ok: Bool, log: String) {
        let out = work.appendingPathComponent("iso-" + String(UUID().uuidString.prefix(8)) + ".txt")
        let pid: Int32 = callFork()
        if pid == 0 {
            let r = loaded.run(args, swift: swift)
            let text = (r.ok ? "OK" : "ERR") + "\n" + r.log
            _ = try? text.write(to: out, atomically: true, encoding: .utf8)
            _exit(0)
        }
        if pid < 0 {
            // fork 被系统拒绝：退回进程内执行（可能崩，但至少不丢功能）
            return loaded.run(args, swift: swift)
        }
        var status: Int32 = 0
        var ticks = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0 { break }
            usleep(200_000)
            ticks += 1
            if ticks > 900 {   // 180s 兜底，避免子进程卡死拖住自检
                _ = kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
                return (false, "子进程超时 180s 被强杀")
            }
        }
        if let text = try? String(contentsOf: out, encoding: .utf8) {
            _ = try? FileManager.default.removeItem(at: out)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let ok = (lines.first ?? "") == "OK"
            if !lines.isEmpty { lines.removeFirst() }
            return (ok, lines.joined(separator: "\n"))
        }
        let sig = status & 0x7f
        let how = sig > 0 ? "子进程被信号 \(sig) 终止（编译器崩溃，已隔离）" : "子进程异常退出 status=\(status)"
        return (false, how)
    }

    /// Swift 编译探测：编译 + 链接。
    /// 参数组可从 Documents/nyxian-swift-args.txt 注入（ID|source|参数；参数含 %SRC% 等占位符时按模板整组替换）。
    /// 源可用 Documents/nyxian-probe.swift 覆盖（source 写 file）。
    static func swiftProbe(loaded: Loaded, work: URL) -> (ok: Bool, log: String) {
        let fm = FileManager.default
        let src = work.appendingPathComponent("probe.swift")
        let obj = work.appendingPathComponent("probe_swift.o")
        let bin = work.appendingPathComponent("probe_swift_bin")
        let cache = work.appendingPathComponent("modulecache", isDirectory: true)
        let overrideSrc = documents.appendingPathComponent("nyxian-probe.swift")
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        guard let sdk = detectSDK() else { return (false, "没有 SDK，Swift 无法编译") }
        let sdkPath = sdk.path
        let resDir = detectSwiftResources()?.path ?? documents.appendingPathComponent("nyxian/Shared").path
        let swiftLib = sdkPath + "/usr/lib/swift"
        let frameworks = sdkPath + "/System/Library/Frameworks"
        var log: [String] = ["SDK: \(sdkPath)", "资源: \(resDir)"]
        func expand(_ raw: String) -> String {
            var t = raw
            t = t.replacingOccurrences(of: "%SRC%", with: src.path)
            t = t.replacingOccurrences(of: "%OBJ%", with: obj.path)
            t = t.replacingOccurrences(of: "%BIN%", with: bin.path)
            t = t.replacingOccurrences(of: "%SDK%", with: sdkPath)
            t = t.replacingOccurrences(of: "%RES%", with: resDir)
            t = t.replacingOccurrences(of: "%WORK%", with: work.path)
            return t
        }
        func content(_ kind: String) -> String {
            switch kind {
            case "plain":
                return "let n: Int = 42\nprint(\"plain ok \\(n)\")\n"
            case "uikit":
                return "import UIKit\nlet v = UIView(frame: .zero)\nprint(\"uikit ok\", v.bounds.width)\n"
            case "swiftui":
                return "import SwiftUI\nstruct V: View { var body: some View { Text(\"hi\") } }\nlet _ = V.self\n"
            case "file":
                return (try? String(contentsOf: overrideSrc, encoding: .utf8)) ?? "let n: Int = 1\nprint(n)\n"
            default:
                return "import Foundation\nlet d = Date()\nprint(\"foundation ok \\(d.timeIntervalSince1970 > 0)\")\n"
            }
        }
        let xres = ["-Xcc", "-resource-dir", "-Xcc", resDir]
        let common: [String] = ["-target", "arm64-apple-ios16.0", "-sdk", sdkPath, "-isysroot", sdkPath,
                                "-F", frameworks, "-I", swiftLib, "-L", swiftLib,
                                "-module-cache-path", cache.path, "-resource-dir", resDir]
        let tail = ["-c", src.path, "-o", obj.path]
        var variants: [(String, String, [String])] = [
            ("A Foundation", "foundation", xres),
            ("B UIKit", "uikit", xres),
            ("C SwiftUI", "swiftui", xres),
            ("D 文件", "file", xres),
        ]
        let cfg = documents.appendingPathComponent("nyxian-swift-args.txt")
        if let text = try? String(contentsOf: cfg, encoding: .utf8) {
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.components(separatedBy: "|")
                if parts.count < 2 { continue }
                let extra = parts.count > 2 ? parts[2].split(separator: " ").map(String.init) : []
                variants.append(("注入:" + parts[0], parts[1], extra))
            }
        }
        for (name, kind, rawArgs) in variants {
            try? fm.removeItem(at: obj)
            try? fm.removeItem(at: bin)
            do { try content(kind).write(to: src, atomically: true, encoding: .utf8) }
            catch { return (false, "写 probe.swift 失败: \(error)") }
            let isTemplate = rawArgs.contains { $0.contains("%") }
            // 模板行（含占位符）自己负责完整参数；普通注入行只写额外 flag，源/产物参数统一补在末尾
            let args = isTemplate ? rawArgs.map(expand) : common + rawArgs.map(expand) + tail
            let r = isoRun(loaded: loaded, args: args, swift: true, work: work)
            let size = ((try? fm.attributesOfItem(atPath: obj.path))?[.size] as? NSNumber)?.intValue ?? 0
            log.append("[\(name)/\(kind)] ok=\(r.ok) obj=\(size)B")
            if size > 0 {
                log.append("编译成功参数: " + args.joined(separator: " "))
                log.append("--- 链接")
                log.append(swiftLink(loaded: loaded, obj: obj, bin: bin, sdk: sdkPath, res: resDir, work: work))
                return (true, log.joined(separator: "\n"))
            }
            let hits = r.log.split(separator: "\n").filter { $0.lowercased().contains("error") }
            for line in hits.prefix(4) { log.append("    " + String(line)) }
        }
        return (false, log.joined(separator: "\n"))
    }

    /// 把 .o 链接成可执行文件（Swift 需要拉 swiftCore 等 tbd）
    ///
    /// - Parameters:
    ///   - target: 目标三元组。默认保留原来的 `arm64-apple-ios16.0`，调用方可传
    ///     `arm64e-apple-ios26.5` 产出设备原生 arm64e 可执行文件。
    ///   - isolated: true 时走 `isoRun`（自检用，编译器崩溃不会带崩宿主）；
    ///     工具链需要在宿主进程内直接编译时传 false。
    ///   - frameworks: 链接时额外 `-framework` 的名称（GUI app 需要 UIKit / Foundation）。
    ///   - progress: 每次尝试前的日志回调，让工具层能实时回显。
    static func swiftLink(loaded: Loaded,
                          obj: URL,
                          bin: URL,
                          sdk: String,
                          res: String,
                          work: URL,
                          target: String = "arm64-apple-ios16.0",
                          isolated: Bool = true,
                          frameworks: [String] = [],
                          progress: ((String) -> Void)? = nil) -> String {
        let fm = FileManager.default
        let lib = sdk + "/usr/lib/swift"
        let fw = sdk + "/System/Library/Frameworks"
        let frameworkArgs = frameworks.flatMap { ["-framework", $0] }
        let resLib = res + "/swift/iphoneos"
        let objectArgs = [obj.path]
        var out: [String] = []
        // 自检仍走原来的三组参数，避免改变既有行为；带 target / framework 的
        // 调用（如 swift_tipa）则优先尝试完整 GUI 链接组合。
        let legacy = target == "arm64-apple-ios16.0" && frameworks.isEmpty
        let sets: [[String]]
        if legacy {
            sets = [
                ["-sdk", sdk, "-target", target, "-L", lib, "-F", fw, "-o", bin.path] + objectArgs,
                ["-sdk", sdk, "-target", target, "-L", lib, "-L", resLib, "-F", fw, "-o", bin.path] + objectArgs,
                ["-sdk", sdk, "-target", target, "-L", lib, "-F", fw, "-lswiftCore", "-o", bin.path] + objectArgs,
            ]
        } else {
            sets = [
                ["-sdk", sdk, "-target", target, "-L", lib, "-L", resLib, "-F", fw]
                    + frameworkArgs
                    + ["-lswiftCore", "-lswiftFoundation", "-o", bin.path] + objectArgs,
                ["-sdk", sdk, "-target", target, "-L", lib, "-L", resLib, "-F", fw]
                    + frameworkArgs
                    + ["-o", bin.path] + objectArgs,
                ["-sdk", sdk, "-target", target, "-L", lib, "-L", resLib, "-F", fw]
                    + frameworkArgs
                    + ["-lswiftCore", "-o", bin.path] + objectArgs,
                ["-sdk", sdk, "-target", target, "-L", lib, "-F", fw]
                    + frameworkArgs
                    + ["-lswiftCore", "-lswiftFoundation", "-o", bin.path] + objectArgs,
            ]
        }
        for (i, args) in sets.enumerated() {
            try? fm.removeItem(at: bin)
            progress?("[链接尝试 \(i + 1)/\(sets.count)] " + args.joined(separator: " "))
            let r = isolated
                ? isoRun(loaded: loaded, args: args, swift: true, work: work)
                : loaded.run(args, swift: true)
            let size = ((try? fm.attributesOfItem(atPath: bin.path))?[.size] as? NSNumber)?.intValue ?? 0
            out.append("[(\(i + 1))] ok=\(r.ok) bin=\(size)B")
            if size > 0 {
                out.append("链接成功参数: " + args.joined(separator: " "))
                return out.joined(separator: "\n")
            }
            let hits = r.log.split(separator: "\n").filter { $0.lowercased().contains("error") }
            for line in hits.prefix(3) { out.append("    " + String(line)) }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - 小工具

    static func cfArray(_ strings: [String]) -> UnsafeMutableRawPointer {
        let array = strings as NSArray
        let cf = unsafeBitCast(array, to: CFArray.self)
        return Unmanaged.passRetained(cf).toOpaque()
    }

    static func cfRelease(_ pointer: UnsafeMutableRawPointer) {
        Unmanaged<AnyObject>.fromOpaque(pointer).release()
    }

    static func cfString(_ pointer: UnsafeMutableRawPointer) -> String? {
        Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func fileSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return "?" }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    private static func firstBytes(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "无文件" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8)) ?? Data()
        return data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func jobTypeName(_ type: UInt8) -> String {
        switch type {
        case 0: return "compiler"
        case 1: return "driver"
        case 2: return "swift-compiler"
        case 3: return "swift-driver"
        case 4: return "linker"
        default: return "unknown(\(type))"
        }
    }

    private static func levelName(_ level: UInt8) -> String {
        switch level {
        case 0: return "unknown"
        case 1: return "note"
        case 2: return "warning"
        case 3: return "error"
        case 4: return "fatal"
        default: return "level(\(level))"
        }
    }
}

/// 启动后由 NanoMuseAutoDiag 调用，把结果落到 Documents/nyxian-diag.txt。
@_cdecl("nm_run_nyxian_diag")
public func nm_run_nyxian_diag() {
    DispatchQueue.global(qos: .utility).async {
        _ = NanoMuseNyxian.writeDiagnostics()
    }
}
