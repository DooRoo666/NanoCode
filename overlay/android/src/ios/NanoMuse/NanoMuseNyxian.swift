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

enum NanoMuseNyxian {

    // MARK: - 路径

    static var documents: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
    }

    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NanoCodex/nyxian", isDirectory: true)
    }

    /// CoreCompiler 的查找顺序：bundle 内 > 容器 Documents > App Support > iSH 桥。
    static var frameworkCandidates: [String] {
        [
            Bundle.main.bundlePath + "/Frameworks/CoreCompiler.framework/CoreCompiler",
            documents.appendingPathComponent("nyxian/CoreCompiler.framework/CoreCompiler").path,
            support.appendingPathComponent("CoreCompiler.framework/CoreCompiler").path,
            "/var/mobile/Documents/nyxian/CoreCompiler.framework/CoreCompiler",
            "/var/mobile/Documents/alpine-rootfs/data/var/minis/workspace/nyxian/CoreCompiler.framework/CoreCompiler",
        ]
    }

    /// 解包后的 iPhoneOS SDK 目录（bootstrap zip 解到这里）。
    static var sdkCandidates: [URL] {
        let roots = [documents.appendingPathComponent("nyxian", isDirectory: true),
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

    private typealias FnDriverCreate = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt8) -> UnsafeMutableRawPointer?
    private typealias FnDriverCreateJobs = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FnDriverCopySDK = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FnDriverCopySysroot = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FnJobGetType = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
    private typealias FnJobExecute = @convention(c) (UnsafeMutableRawPointer?,
                                                     UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
                                                     UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> UInt8
    private typealias FnJobSupportsMT = @convention(c) (UInt8) -> UInt8
    private typealias FnSDKCreate = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FnSDKCopyVersion = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FnDiagGetMessage = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias FnDiagGetLevel = @convention(c) (UnsafeMutableRawPointer?) -> UInt8
    private typealias FnMaxCores = @convention(c) () -> Int32

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
        func run(_ args: [String]) -> (ok: Bool, log: String) {
            var log: [String] = []
            log.append("argv: " + args.joined(separator: " "))

            let cfArgs = NanoMuseNyxian.cfArray(args)
            defer { NanoMuseNyxian.cfRelease(cfArgs) }

            guard let driver = driverCreate(nil, cfArgs, 0) else {
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
        sdkCandidates.first
    }

    // MARK: - 自检

    /// 端到端探针：dlopen → 导出符号 → 编译 hello.c → 链接成 Mach-O。
    /// 不需要 SDK：探针源码不 include 任何头文件。
    static func selfTest() -> String {
        var out: [String] = []
        let stamp = ISO8601DateFormatter().string(from: Date())
        out.append("=== Nyxian 工具链自检 \(stamp) ===")
        out.append("bundle: \(Bundle.main.bundlePath)")

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
