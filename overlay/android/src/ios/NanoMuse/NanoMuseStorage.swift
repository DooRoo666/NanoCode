import Foundation

/// 工具 / 运行时 / 缓存 的**存储统计与清理**。
///
/// 目标：像 MT-Agent 的「存储管理」那样，让用户一眼看到
///   · 每个工具占多少空间
///   · 哪些是缓存可以直接清
///   · 一键清理 / 单项删除
///
/// 统计的是「我们自己能安全删的东西」，绝不碰别人的容器。
enum NanoMuseStorage {

    // MARK: - 统计

    struct Item: Identifiable, Sendable {
        let id: String
        let title: String
        let detail: String
        let bytes: Int64
        /// true = 缓存类，可安全清理（不含用户数据）
        let isCache: Bool
        /// 对应的目录 / 文件路径（清理时用）
        let paths: [String]

        var sizeText: String { NanoMuseStorage.format(bytes) }
    }

    static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        let mb = Double(bytes) / 1048576
        if mb < 1 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }

    /// 目录总大小（不跟随符号链接，避免把整个盘算进来）
    static func size(of path: String) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: URL(fileURLWithPath: path),
                                        includingPropertiesForKeys: keys,
                                        options: [.skipsPackageDescendants],
                                        errorHandler: nil) else { return 0 }
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isRegularFile == true { total += Int64(v.fileSize ?? 0) }
        }
        return total
    }

    // MARK: - 各项位置

    private static var docs: String { NSHomeDirectory() + "/Documents" }
    private static var library: String { NSHomeDirectory() + "/Library" }
    private static var caches: String { library + "/Caches" }
    private static var tmp: String { NSTemporaryDirectory() }

    /// 探测目录是否可写（原在 TheosRuntime 里，已迁出）
    static func canWrite(_ dir: String) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let probe = dir + "/.write-probe-\(UUID().uuidString.prefix(8))"
        let ok = fm.createFile(atPath: probe, contents: Data("x".utf8))
        if ok, fm.fileExists(atPath: probe) {
            try? fm.removeItem(atPath: probe)
            return true
        }
        try? fm.removeItem(atPath: probe)
        return false
    }

    /// 运行时安装根目录（codex / python / node …）
    static var runtimesRoot: String { NanoMuseNativeRuntime.rootDirectory.path }

    /// 收集所有条目
    static func items() async -> [Item] {
        var list: [Item] = []

        // ① 运行时（codex / core tools / python / node …）
        for id in NanoMuseNativeRuntime.installedIDs() {
            let dir = NanoMuseNativeRuntime.directory(for: id)
            let size = self.size(of: dir.path)
            list.append(Item(id: "runtime:" + id,
                             title: displayName(forRuntime: id),
                             detail: "已安装运行时",
                             bytes: size,
                             isCache: false,
                             paths: [dir.path]))
        }

        // ③ 下载残留（我们自己的 .tar.gz / 分片）
        var leftovers: [String] = []
        /* 预留：后续新增运行时下载残留在此登记 */
        let leftoverSize = leftovers.reduce(Int64(0)) { $0 + size(of: $1) }
        if leftoverSize > 0 {
            list.append(Item(id: "downloads",
                             title: "下载残留",
                             detail: "解包完成的压缩包，可安全删除",
                             bytes: leftoverSize,
                             isCache: true,
                             paths: leftovers))
        }

        // ④ 聊天与作品
        let conv = size(of: docs + "/conversations")
        let gallery = size(of: docs + "/gallery")
        if conv + gallery > 0 {
            list.append(Item(id: "content",
                             title: "聊天与作品",
                             detail: "会话记录、生成的文件",
                             bytes: conv + gallery,
                             isCache: false,
                             paths: [docs + "/conversations", docs + "/gallery"].filter {
                                 FileManager.default.fileExists(atPath: $0)
                             }))
        }

        // ⑤ 缓存（可安全清）
        let cacheSize = size(of: caches)
        if cacheSize > 0 {
            list.append(Item(id: "caches",
                             title: "可清理缓存",
                             detail: "模型列表、图片、Web 缓存等",
                             bytes: cacheSize,
                             isCache: true,
                             paths: [caches]))
        }

        // ⑥ 临时文件
        let tmpSize = size(of: tmp)
        if tmpSize > 0 {
            list.append(Item(id: "tmp",
                             title: "临时文件",
                             detail: "安装日志、下载中间文件",
                             bytes: tmpSize,
                             isCache: true,
                             paths: [tmp]))
        }

        return list
    }

    /// 运行时 id → 友好名称
    static func displayName(forRuntime id: String) -> String {
        let map = [
            "codex": "Codex 核心组件",
            "core_tools": "CoreTools 工具包",
            "core-tools": "CoreTools 工具包",
            "python": "Python 环境",
            "node": "Node.js 环境",
            "reverse_tools": "ReverseTools 逆向工具",
            "reverse-tools": "ReverseTools 逆向工具",
            "ollvm": "OLLVM 混淆器",
            "build_tools": "BuildTools 编译工具",
            "build-tools": "BuildTools 编译工具",
        ]
        return map[id] ?? id
    }

    // MARK: - 清理

    /// 删除单个条目
    @discardableResult
    static func remove(_ item: Item) -> Bool {
        let fm = FileManager.default
        var ok = true
        for path in item.paths {
            // 运行时目录用 NativeRuntime 自己的卸载逻辑（会一并清标记）
            if item.id.hasPrefix("runtime:") {
                let id = String(item.id.dropFirst("runtime:".count))
                do { _ = try NanoMuseNativeRuntime.uninstall(id); continue }
                catch { if fm.fileExists(atPath: path) { ok = false }; continue }
            }
            do {
                try fm.removeItem(atPath: path)
            } catch {
                // 目录不存在算成功
                if fm.fileExists(atPath: path) { ok = false }
            }
        }
        return ok
    }

    /// 清所有缓存类条目
    @discardableResult
    static func clearCaches() -> Int64 {
        var freed: Int64 = 0
        let fm = FileManager.default
        // 只清我们自己容器里的缓存
        for path in [caches, tmp] {
            freesDirectory(path, into: &freed, fm: fm)
        }
        return freed
    }

    /// 清空目录内容但保留目录本身（有些系统组件要求目录存在）
    private static func freesDirectory(_ path: String, into freed: inout Int64, fm: FileManager) {
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return }
        for name in names {
            let p = path + "/" + name
            // 不要删掉正在用的 sqlite / 当前进程的锁文件
            if name.hasSuffix("-shm") || name.hasSuffix("-wal") { continue }
            freed += size(of: p)
            try? fm.removeItem(atPath: p)
        }
    }
}
