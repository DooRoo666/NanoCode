import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// CoreCompiler 按需下载器。
///
/// 动机：CoreCompiler.framework 解压后约 200 MB，打进 TIPA 会让包体从
/// ~50 MB 涨到 131 MB。所以构建时不再内置，改为首次使用时从 GitHub
/// release `runtime-deps` 拉取，落到 `Runtimes/frameworks/`，
/// 与 `NanoMuseNyxian` 的第一优先查找路径完全一致。
///
/// 压缩包内部顶层就是 `CoreCompiler.framework/`（含 `CoreCompiler` 主二进制
/// 和 `Frameworks/*.dylib` 共 13 个），因此直接解压到 `Runtimes/frameworks/`
/// 即得到 `Runtimes/frameworks/CoreCompiler.framework/CoreCompiler`。
enum NanoMuseCoreCompilerDownloader {

    /// CoreCompiler.framework 所在目录（与 Nyxian 第一优先级一致）
    static var frameworksRoot: URL {
        NanoMuseNativeRuntime.rootDirectory
            .appendingPathComponent("frameworks", isDirectory: true)
    }

    static var installedFrameworkPath: URL {
        frameworksRoot.appendingPathComponent("CoreCompiler.framework",
                                              isDirectory: true)
    }

    static var installedBinaryPath: URL {
        installedFrameworkPath.appendingPathComponent("CoreCompiler")
    }

    /// 下载源：用户自己的仓库 release，可随时替换。
    static let defaultURL =
        "https://github.com/DooRoo666/NanoCode/releases/download/runtime-deps/CoreCompiler.zip"

    /// 整包 SHA256（大文件必须校验：断点续传/截断都会静默产出坏包，
    /// 而 dlopen 失败时的报错信息完全无法指向这个根因）
    static let defaultSHA256 =
        "8b9c34d197dc3379cadf4959feae20e40df1e659c2704fa83892aa1ae9f4739c"

    /// 是否已就位（主二进制存在且非空即可，dylib 缺失会在 dlopen 阶段暴露）
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: installedBinaryPath.path),
              let attrs = try? fm.attributesOfItem(atPath: installedBinaryPath.path),
              let size = attrs[.size] as? NSNumber, size.intValue > 0
        else { return false }
        return true
    }

    /// 已安装版本体积（字节），用于设置页展示
    static func installedSize() -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: installedFrameworkPath,
                                    includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            if let s = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(s)
            }
        }
        return total
    }

    /// 确保 CoreCompiler 就位。已装则立刻回调成功。
    /// - Parameters:
    ///   - progress: 0.0–1.0，主线程回调
    ///   - completion: 主线程回调，成功时给出 CoreCompiler.framework 路径
    static func ensureInstalled(
        urlString: String = defaultURL,
        sha256 expected: String = defaultSHA256,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if isInstalled() {
            DispatchQueue.main.async { completion(.success(installedFrameworkPath)) }
            return
        }
        download(urlString: urlString, expected: expected,
                 progress: progress, completion: completion)
    }

    // MARK: - 下载

    private static func download(
        urlString: String,
        expected: String,
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(fail(-1, "CoreCompiler 下载地址无效")))
            return
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("corecompiler_download.zip")

        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            let deliver: (Result<URL, Error>) -> Void = { r in
                DispatchQueue.main.async { completion(r) }
            }

            if let error { deliver(.failure(error)); return }

            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                deliver(.failure(fail(http.statusCode,
                                      "CoreCompiler 下载失败 HTTP \(http.statusCode)")))
                return
            }
            guard let location else {
                deliver(.failure(fail(-2, "CoreCompiler 下载无输出"))); return
            }

            do {
                let fm = FileManager.default
                try? fm.removeItem(at: tmp)
                try fm.moveItem(at: location, to: tmp)

                // 先校验再解包：200MB 的包解完才发现坏了要重来一遍
                if !expected.isEmpty {
                    let digest = try NanoMuseSDKDownloader.sha256(of: tmp)
                    guard digest.lowercased() == expected.lowercased() else {
                        try? fm.removeItem(at: tmp)
                        deliver(.failure(fail(-5,
                            "CoreCompiler 校验失败（sha256 不匹配），已丢弃重下")))
                        return
                    }
                }

                // 清理半成品，避免解出嵌套目录
                try? fm.removeItem(at: installedFrameworkPath)
                try fm.createDirectory(at: frameworksRoot, withIntermediateDirectories: true)

                // 流式解包，200MB 不整体驻留内存
                let zip = try NanoMuseZip(path: tmp.path)
                let count = try zip.extract(to: frameworksRoot.path) { done, total in
                    if total > 0 {
                        progress?(0.1 + Double(done) / Double(total) * 0.85)
                    }
                }
                try? fm.removeItem(at: tmp)

                guard count > 0 else {
                    deliver(.failure(fail(-6, "CoreCompiler 解包后为空"))); return
                }
                guard isInstalled() else {
                    deliver(.failure(fail(-3,
                        "CoreCompiler 解包后结构不对，缺 CoreCompiler.framework/CoreCompiler")))
                    return
                }
                deliver(.success(installedFrameworkPath))
            } catch {
                deliver(.failure(error))
            }
        }

        task.resume()
    }

    private static func fail(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "NanoMuseCoreCompiler", code: code,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
