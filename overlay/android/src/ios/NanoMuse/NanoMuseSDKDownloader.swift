import Foundation
import CryptoKit

/// SDK 自动下载器 —— 让本体在没有外部 SDK 时自己补上。
///
/// 设计目标（用户明确要求）：
///   · 现在：本体首次运行自动下载，做到「装上就能用」
///   · 后期：改成用户自选下载（见文件底部 `TODO: 用户自选下载` 标记）
///
/// 依赖已存在的组件：
///   · NanoMuseNativeRuntime.rootDirectory —— App 包内 Runtimes/（可写）
///   · NanoMuseZip                          —— 纯 Swift 流式 zip 解包（libz inflate）
enum NanoMuseSDKDownloader {

    // MARK: - 配置

    /// SDK 包地址。
    ///
    /// ★ 来源说明（2026-10-30 定案）：使用**公开开源仓库** `xybp888/iOS-SDKs` 的
    ///   Release 资产，一份 zip 对应一个 SDK 版本。
    ///   该仓库收录 iOS 13.7 ~ 27.1 全部官方 SDK，属社区公开镜像，无需自建托管。
    ///   （早先曾用本项目自建的 Release 托管 SDK，既占仓库空间又无必要，已删除。）
    ///
    ///   同仓库还有其他版本，把 tag 换掉即可，例如：
    ///     iOS27.1-SDKs / iOS27.0-SDKs / iOS26.4.1-SDKs / iOS26.4-SDKs
    ///
    /// TODO(用户自选下载): 后期这里会改成读 `runtime-manifest.json`，
    ///   和 CoreCompiler 走同一套清单驱动，用户在设置里勾选要装哪个 SDK。
    ///   现在先写死一个默认源，保证「装上就能用」。
    static let defaultSDKURL =
        "https://github.com/xybp888/iOS-SDKs/releases/download/iOS26.5-SDKs/iPhoneOS26.5.sdk.zip"

    /// 压缩包 SHA256（GitHub Release 资产的 digest）。
    /// 用于校验下载完整性 —— 断点续传或传输截断都会导致不匹配。
    static let defaultSDKsha256 =
        "bed0f155d84e98ad8273b3bd57a0816ae5e772e1aa8539e6d79476221ce33173"

    /// 解包后应有的目录名
    static let sdkDirName = "iPhoneOS26.5.sdk"

    /// 下载完成的标记文件（避免重复下载）
    private static let markerName = ".installed"

    // MARK: - 路径

    /// `<Runtimes>/sdks`
    static var sdksRoot: URL {
        NanoMuseNativeRuntime.rootDirectory
            .appendingPathComponent("sdks", isDirectory: true)
    }

    /// `<Runtimes>/sdks/iPhoneOS26.5.sdk`
    static var installedSDKPath: URL {
        sdksRoot.appendingPathComponent(sdkDirName, isDirectory: true)
    }

    /// SDK 是否已就位（检查 SDK 根 + SDKSettings.plist）
    static func isInstalled() -> Bool {
        let fm = FileManager.default
        let sdk = installedSDKPath
        guard fm.fileExists(atPath: sdk.path) else { return false }
        // 有 SDKSettings.plist 才算完整
        let settings = sdk.appendingPathComponent("SDKSettings.plist")
        return fm.fileExists(atPath: settings.path)
    }

    // MARK: - 自动安装（当前默认行为）

    /// 确保 SDK 存在；缺失则在后台下载。
    ///
    /// - Parameters:
    ///   - progress: 0.0...1.0，用于 UI 进度
    ///   - completion: 成功返回 SDK 路径，失败返回 Error
    ///
    /// 调用时机：编译前调用一次即可，已装则立即返回。
    static func ensureInstalled(
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        if isInstalled() {
            completion(.success(installedSDKPath))
            return
        }

        // 已有外部 SDK（如 /var/mobile/Documents/nyxian/iPhoneOS26.5.sdk）时
        // 不重复下载，直接软链过来省 190MB。
        if let external = NanoMuseNyxian.detectSDK() {
            linkExternal(external)
            if isInstalled() {
                completion(.success(installedSDKPath))
                return
            }
        }

        download(progress: progress, completion: completion)
    }

    /// 把外部 SDK 以软链形式接进 Runtimes/sdks/
    private static func linkExternal(_ src: URL) {
        let fm = FileManager.default
        let dst = installedSDKPath
        guard !fm.fileExists(atPath: dst.path) else { return }
        try? fm.createDirectory(at: sdksRoot, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: dst, withDestinationURL: src)
    }

    // MARK: - 下载

    private static func download(
        progress: ((Double) -> Void)?,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let url = URL(string: defaultSDKURL) else {
            completion(.failure(NSError(
                domain: "NanoMuseSDK", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "SDK 下载地址无效"])))
            return
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk_download.zip")

        let task = URLSession.shared.downloadTask(with: url) { location, response, error in
            let deliver: (Result<URL, Error>) -> Void = { r in
                DispatchQueue.main.async { completion(r) }
            }

            if let error {
                deliver(.failure(error)); return
            }
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                deliver(.failure(NSError(
                    domain: "NanoMuseSDK", code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey:
                        "SDK 下载失败 HTTP \(http.statusCode)"])))
                return
            }
            guard let location else {
                deliver(.failure(NSError(
                    domain: "NanoMuseSDK", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "SDK 下载无输出"])))
                return
            }

            do {
                let fm = FileManager.default
                try? fm.removeItem(at: tmp)
                try fm.moveItem(at: location, to: tmp)

                // SHA256 校验：断点续传 / 传输截断都会导致不匹配
                if !defaultSDKsha256.isEmpty {
                    let digest = try sha256(of: tmp)
                    guard digest == defaultSDKsha256 else {
                        try? fm.removeItem(at: tmp)
                        deliver(.failure(NSError(
                            domain: "NanoMuseSDK", code: -5,
                            userInfo: [NSLocalizedDescriptionKey:
                                "SDK 校验失败（sha256 不匹配），已丢弃重下"])))
                        return
                    }
                }

                // 解包前先清掉半成品
                try? fm.removeItem(at: installedSDKPath)
                try fm.createDirectory(at: sdksRoot, withIntermediateDirectories: true)

                // ★ 流式解包：逐条目读取 + 边解压边写盘，
                //   解压后约 330MB，**不会**整体驻留内存（旧 tar.gz 方案会）。
                //   解包器会自动跳过 __MACOSX/ 冗余条目。
                let zip = try NanoMuseZip(path: tmp.path)
                let result = try zip.extract(to: sdksRoot.path) { done, total in
                    if total > 0 {
                        let ratio = Double(done) / Double(total)
                        progress?(0.1 + ratio * 0.85)
                    }
                }
                try? fm.removeItem(at: tmp)

                guard result.files > 0 else {
                    deliver(.failure(NSError(
                        domain: "NanoMuseSDK", code: -6,
                        userInfo: [NSLocalizedDescriptionKey: "SDK 解包后为空"])))
                    return
                }

                // 校验
                guard isInstalled() else {
                    deliver(.failure(NSError(
                        domain: "NanoMuseSDK", code: -3,
                        userInfo: [NSLocalizedDescriptionKey:
                            "SDK 解包后结构不对，缺 SDKSettings.plist"])))
                    return
                }
                deliver(.success(installedSDKPath))
            } catch {
                deliver(.failure(error))
            }
        }

        // 进度回调
        if let progress {
            let session = URLSession(configuration: .default) { configuration in
                configuration.timeoutIntervalForResource = 60 * 60
                return configuration
            }
            let observer = DownloadProgressObserver(task: task) { p in
                DispatchQueue.main.async { progress(p) }
            }
            task.resume()
            observer.start()
        } else {
            task.resume()
        }
    }

    // MARK: - SHA256

    /// 流式计算文件 SHA256（分块读，不把整个文件塞进内存）
    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - TODO: 用户自选下载

    // 后期规划（用户明确要求「后期会换成自己的工具列表」）：
    //   1. SDK 条目移入 runtime-manifest.json，与 CoreCompiler 走同一套清单驱动
    //   2. 设置页列出可选版本（26.5 / 27.0 / 27.1 …）+ 显示体积
    //   3. 支持用户自选镜像源 / 自建托管
    //   4. 支持「仅下载最小必要集」（usr/lib/swift + Frameworks/*/Modules），
    //      跳过 28MB 的 usr/include（C 头文件，编 Swift 用不到）
    //   5. 下载进度、断点续传、多源回退统一到清单的 download_proxy_prefixes
    //
    // 当前 NanoMuseSDKDownloader 本身可原样保留，只需把 URL/SHA 换成清单驱动。
}
