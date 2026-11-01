import SwiftUI
import Foundation

// 编译工具链：用户自选下载（不再自动下载）
//
// 设计：2026-11-01 起，App 包内**不内置**任何重型运行时，启动也**不自动下载**。
// 所有可下载项集中在本页列出，用户自己勾选安装 / 删除。
// 已安装的项由 NanoMuseSDKDownloader / NanoMuseCoreCompilerDownloader 探测。

enum NanoMuseToolchain {

    /// 启动时只记录状态，不做任何下载动作。
    static func recordStartupState() {
        let sdk = NanoMuseSDKDownloader.isInstalled()
        let cc = NanoMuseCoreCompilerDownloader.isInstalled()
        let line = "toolchain: sdk=\(sdk ? "ok" : "missing") corecompiler=\(cc ? "ok" : "missing")\n"
        let fm = FileManager.default
        guard let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("toolchain-state.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// 目录占用（递归求和，失败返回 0）。
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                     options: [.skipsHiddenFiles], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            if let size = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    static func sizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "—" }
        let mb = Double(bytes) / 1_048_576.0
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

struct NanoMuseToolchainPage: View {
    @State private var sdkInstalled = NanoMuseSDKDownloader.isInstalled()
    @State private var ccInstalled = NanoMuseCoreCompilerDownloader.isInstalled()
    @State private var sdkBusy = false
    @State private var ccBusy = false
    @State private var sdkNote = ""
    @State private var ccNote = ""

    var body: some View {
        NanoMusePage(title: "编译工具链") {
            NanoMuseCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("按需安装")
                        .font(.system(size: 15, weight: .semibold))
                    Text("App 自带的部分只有引擎本体。下面这些体积较大的组件**不会**自动下载，也不会随包分发——需要用到设备内编译时，自己选一项下载即可。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }

            item(
                title: "iPhoneOS SDK",
                detail: "26.5 · 编译 Swift/C/ObjC 所需头文件与系统库",
                approx: "约 49 MB",
                installed: sdkInstalled,
                busy: sdkBusy,
                note: sdkNote,
                path: NanoMuseSDKDownloader.installedSDKPath,
                install: installSDK,
                remove: removeSDK
            )

            item(
                title: "CoreCompiler",
                detail: "186 MB framework · 把源码编成 arm64e 目标文件",
                approx: "约 71 MB 压缩包",
                installed: ccInstalled,
                busy: ccBusy,
                note: ccNote,
                path: NanoMuseCoreCompilerDownloader.installedFrameworkPath,
                install: installCompiler,
                remove: removeCompiler
            )

            NanoMuseCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("下载源")
                        .font(.system(size: 15, weight: .semibold))
                    Text("· SDK：NanoCode runtime-deps（GitHub Release）")
                    Text("· CoreCompiler：NanoCode runtime-deps（GitHub Release）")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func item(title: String,
                      detail: String,
                      approx: String,
                      installed: Bool,
                      busy: Bool,
                      note: String,
                      path: URL,
                      install: @escaping () -> Void,
                      remove: @escaping () -> Void) -> some View {
        NanoMuseCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    Text(installed ? "已安装" : "未安装")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(installed ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                        .foregroundStyle(installed ? Color.green : Color.orange)
                        .clipShape(Capsule())
                    Spacer(minLength: 0)
                    Text(installed ? NanoMuseToolchain.sizeText(NanoMuseToolchain.directorySize(path)) : approx)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    if busy {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("处理中…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else if installed {
                        Button(role: .destructive, action: remove) {
                            Text("删除")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button(action: install) {
                            Text("下载安装")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    // MARK: - 动作

    private func installSDK() {
        sdkBusy = true
        sdkNote = "开始下载…"
        NanoMuseSDKDownloader.ensureInstalled(progress: { ratio in
            DispatchQueue.main.async {
                sdkNote = String(format: "下载中 %.0f%%", max(0, min(1, ratio)) * 100)
            }
        }, completion: { result in
            DispatchQueue.main.async {
                sdkBusy = false
                switch result {
                case .success(let url):
                    sdkInstalled = true
                    sdkNote = "已安装：\(url.lastPathComponent)"
                case .failure(let error):
                    sdkNote = "失败：\(error.localizedDescription)"
                }
            }
        })
    }

    private func installCompiler() {
        ccBusy = true
        ccNote = "开始下载…"
        NanoMuseCoreCompilerDownloader.ensureInstalled(progress: { ratio in
            DispatchQueue.main.async {
                ccNote = String(format: "下载中 %.0f%%", max(0, min(1, ratio)) * 100)
            }
        }, completion: { result in
            DispatchQueue.main.async {
                ccBusy = false
                switch result {
                case .success(let url):
                    ccInstalled = true
                    ccNote = "已安装：\(url.lastPathComponent)"
                case .failure(let error):
                    ccNote = "失败：\(error.localizedDescription)"
                }
            }
        })
    }

    private func removeSDK() {
        do {
            try FileManager.default.removeItem(at: NanoMuseSDKDownloader.installedSDKPath)
            sdkInstalled = NanoMuseSDKDownloader.isInstalled()
            sdkNote = "已删除"
        } catch {
            sdkNote = "删除失败：\(error.localizedDescription)"
        }
    }

    private func removeCompiler() {
        do {
            try FileManager.default.removeItem(at: NanoMuseCoreCompilerDownloader.installedFrameworkPath)
            ccInstalled = NanoMuseCoreCompilerDownloader.isInstalled()
            ccNote = "已删除"
        } catch {
            ccNote = "删除失败：\(error.localizedDescription)"
        }
    }
}
