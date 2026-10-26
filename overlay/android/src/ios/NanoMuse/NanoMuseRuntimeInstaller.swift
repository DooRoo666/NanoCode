import Foundation
import CryptoKit

/// 运行时下载安装器 —— 「自身小、其余全下载」的执行体。
///
/// 设计要点（全部来自实测）：
/// 1. **装进 .app**。iOS 只信任被 TrollStore 签进 App 包的 Mach-O；放在 Library/ 里
///    的二进制即使权限正确，dyld 也会拒绝它依赖的私有 dylib。MT-Agent 的
///    TheosRuntime / PythonRuntime 属主是 mobile:501，就是这么写进去的。
/// 2. **下载源直接用 MT 的**（susu123oss/CodexApp-Runtime 的 release 包），
///    不自己维护镜像。
/// 3. 校验 SHA256 后才落盘解压，失败不留半成品。
enum NanoMuseRuntimeInstaller {

    enum InstallError: LocalizedError {
        case unknownRuntime(String)
        case http(Int)
        case checksum(String)
        case unpack(String)

        var errorDescription: String? {
            switch self {
            case .unknownRuntime(let n): return "清单里没有名为 \(n) 的运行时"
            case .http(let c): return "下载失败（HTTP \(c)）"
            case .checksum(let n): return "\(n) 校验不通过（SHA256 不符）"
            case .unpack(let s): return "解压失败：\(s)"
            }
        }
    }

    // MARK: - 安装位置

    /// 运行时的根：**优先 .app 内**。
    /// `Bundle.main.bundlePath` 本身永远不可写（root:root 0755），
    /// 所以必须实探子目录能不能建出来，而不是直接判断 bundlePath。
    static var installRoot: URL {
        let bundled = URL(fileURLWithPath: Bundle.main.bundlePath)
            .appendingPathComponent("Runtimes", isDirectory: true)
        if NanoMuseStorage.canWrite(bundled.path) {
            return bundled
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("NanoCodex/runtimes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 主入口

    /// 按清单里的 id 安装一个运行时。
    @discardableResult
    static func installNamed(_ name: String,
                             log: @escaping (String) -> Void) async throws -> URL {
        log("读取运行时清单…")
        let manifest = try await NanoMuseRuntimeManifest.fetch()
        guard let package = manifest.packages.first(where: { $0.id == name }) else {
            throw InstallError.unknownRuntime(name)
        }
        log("目标：\(package.displayName)　\(package.sizeText)")

        let dstRoot = installRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dstRoot, withIntermediateDirectories: true)
        log("安装到：\(dstRoot.path)")

        let archive = try download(package, proxies: manifest.proxies, log: log)
        defer { try? FileManager.default.removeItem(at: archive) }

        try unpackRaw(archive: archive, into: dstRoot, log: log)
        log("完成：\(package.displayName)")
        return dstRoot
    }

    // MARK: - 下载

    private static func download(_ package: NanoMuseRuntimeManifest.Package,
                                 proxies: [String],
                                 log: @escaping (String) -> Void) throws -> URL {
        var candidates = [package.archiveURL]
        for prefix in proxies {
            // 清单里的代理前缀形如 "https://gh-proxy.com/" 或 "https://ghproxy.net/"
            guard !prefix.isEmpty else { continue }
            candidates.append(prefix + package.archiveURL)
        }

        var lastError: Error = InstallError.http(0)
        for (index, candidate) in candidates.enumerated() {
            do {
                log("下载中 (\(index + 1)/\(candidates.count))…")
                return try fetch(candidate, package: package, log: log)
            } catch {
                log("  该源失败：\(error.localizedDescription)")
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetch(_ urlString: String,
                              package: NanoMuseRuntimeManifest.Package,
                              log: @escaping (String) -> Void) throws -> URL {
        guard let url = URL(string: urlString) else { throw InstallError.http(0) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.setValue("Minis/1.0 (NanoCode)", forHTTPHeaderField: "User-Agent")

        var failure: Error?
        var payload: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error { failure = error; return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else {
                failure = InstallError.http(code)
                return
            }
            payload = data
        }.resume()
        sem.wait()

        if let failure { throw failure }
        guard let data = payload else { throw InstallError.http(0) }
        log("  收到 \(String(format: "%.1f", Double(data.count) / 1048576)) MB")

        if !package.sha256.isEmpty {
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            guard hex == package.sha256.lowercased() else {
                throw InstallError.checksum(package.displayName)
            }
            log("  SHA256 校验通过")
        }

        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("rt-\(package.id).tar.gz")
        try data.write(to: dst)
        return dst
    }

    // MARK: - 解压

    /// 用内置的纯 Swift tar.gz 解包器（NanoMuseTarGz）。
    /// 不用外部 tar：首次安装时包里还没有 tar，会形成鸡生蛋问题。
    private static func unpackRaw(archive: URL, into dir: URL, log: (String) -> Void) throws {
        let n = try NanoMuseTarGz.unpack(archive: archive, into: dir)
        log("   解出 \(n) 个条目 → \(dir.path)")
    }

}
