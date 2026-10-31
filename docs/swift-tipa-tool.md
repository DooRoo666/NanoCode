# `swift_tipa`：Swift 源码直接产出 .tipa

`swift_tipa` 是 Codex 的宿主工具。Agent 写完 Swift 源码后，一次调用即可在
iPhone 宿主 App 进程内完成：编译 → 链接 → 组装 `.app` → 签名 → 打包 `.tipa`。
全程 **不 fork、不经过 iSH、不调用 shell**。

实现文件：`overlay/android/src/ios/NanoMuse/NanoMuseSwiftTipaTool.swift`

## 参数

| 参数 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `tool_title` | string | 是 | 展示给用户的 5–10 字摘要 |
| `source` | string | 是 | `.swift` 文件绝对路径，或包含多个 `.swift` 的目录绝对路径 |
| `name` | string | 否 | App 名与可执行文件名；默认取源文件/目录名 |
| `bundle_id` | string | 否 | `CFBundleIdentifier`；默认 `com.nanocode.<name>`（小写） |
| `output` | string | 否 | 输出文件名；默认 `<name>.tipa`，自动补 `.tipa` 后缀 |

Swift 签名：

```swift
NanoMuseSwiftTipaTool.execute(
    source: String,
    name: String?,
    bundleID: String?,
    output: String?
) async -> Outcome   // exitCode: Int32, text: String
```

工具声明使用 `AgentToolDefinition`，与 `tipa_build` 同一套参数模型。

## 示例

```json
{
  "tool_title": "编译 Swift 并打包 TIPA",
  "source": "/private/var/mobile/Documents/HelloSwift/main.swift",
  "name": "HelloSwift",
  "bundle_id": "com.nanocode.helloswift",
  "output": "HelloSwift.tipa"
}
```

源码末尾必须有 GUI 入口（没有则工具直接拒绝编译并说明原因）：

```swift
UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
```

模板见 `docs/swift-tipa/template/main.swift`。

## 完整流程

```mermaid
flowchart LR
  A[source 文件 / 目录] --> B[收集 .swift 并检查 UIApplicationMain]
  B --> C[确保 SDK 就位<br/>isInstalled → detectSDK → ensureInstalled]
  C --> D[全部源码一次编译为一个 .o<br/>NanoMuseNyxian.load().run(..., swift: true)]
  D --> E[链接 .o<br/>NanoMuseNyxian.swiftLink(...)]
  E --> F[组装 name.app<br/>可执行文件 0755 + Info.plist]
  F --> G[签名主程序<br/>NanoMuseMachSigner.sign]
  G --> H[打包 .tipa<br/>NanoMuseTipaBuilder.build]
  H --> I[TrollStore 安装]
```

各步骤的具体调用：

| 步骤 | 实际调用 |
|---|---|
| 1. 解析源码 | `swiftFiles(in:)`；目录递归收集 `.swift`，文件模式只接受单个 `.swift` |
| 2. SDK | `NanoMuseSDKDownloader.isInstalled()` → `NanoMuseNyxian.detectSDK()` → `NanoMuseSDKDownloader.ensureInstalled(progress:completion:)` |
| 3. 编译 | `NanoMuseNyxian.load()` 得到 `Loaded`，把全部源文件作为同一模块调用 `loaded.run(args, swift: true)`，`-emit-object` 产出单个 `.o` |
| 4. 链接 | `NanoMuseNyxian.swiftLink(loaded:obj:bin:sdk:res:work:target:isolated:frameworks:progress:)` |
| 5. 组包 | `writeInfoPlist(to:name:bundleID:)` + `FileManager.setAttributes([.posixPermissions: 0o755])` |
| 6. 签名 | `NanoMuseMachSigner.sign(path:entitlements:identifier:)`；失败时回退 `NanoMuseHelperRunner.run("codex-sign", ["--entitlements", …, binary])` |
| 7. 打包 | `NanoMuseTipaBuilder.build(appPath:entitlements:outputName:)` |

### 编译参数

目标三元组固定为 `arm64e-apple-ios26.5`（SDK 仅带 arm64e，设备为 A16/arm64e）。

```text
-target arm64e-apple-ios26.5
-sdk <SDK>
-isysroot <SDK>
-F <SDK>/System/Library/Frameworks
-I <SDK>/usr/lib/swift
-L <SDK>/usr/lib/swift
-module-cache-path <work>/ModuleCache
-resource-dir <NanoMuseNyxian.detectSwiftResources()>
-module-name main
-emit-object -o <work>/objects/main.o <all .swift>
```

### 链接参数

`swiftLink` 会按顺序尝试多组参数，成功条件是可执行文件非空且 Mach-O CPU 类型为
`arm64e`。核心参数：

```text
-sdk <SDK> -target arm64e-apple-ios26.5
-L <SDK>/usr/lib/swift -L <Shared>/swift/iphoneos
-F <SDK>/System/Library/Frameworks
-framework UIKit -framework Foundation
-lswiftCore -lswiftFoundation
-o <name>.app/<name> <main.o>
```

### Info.plist

运行时用 `PropertyListSerialization` 写入，字段：

- `CFBundleIdentifier` = `bundle_id`
- `CFBundleExecutable` / `CFBundleName` = `name`
- `CFBundlePackageType` = `APPL`
- `CFBundleShortVersionString` = `1.0`，`CFBundleVersion` = `1`
- `LSRequiresIPhoneOS` = `true`
- `MinimumOSVersion` = `26.0`
- `UIDeviceFamily` = `[1, 2]`
- `CFBundleSupportedPlatforms` = `[iPhoneOS]`

### 签名

entitlements 由 `PropertyListSerialization` 在临时目录运行时生成，包含：

```text
platform-application                                  = true
get-task-allow                                        = true
com.apple.private.security.no-container               = true
com.apple.private.security.container-required         = false
com.apple.private.security.no-sandbox                 = true
com.apple.private.security.disable-library-validation = true
```

与 `Tools/entitlements-app.plist` 的 TrollStore 必需项一致。优先使用仓库自带的
`NanoMuseMachSigner`（纯 Swift、ad-hoc、SHA1 CodeDirectory），失败才用宿主
`Helpers/codex-sign` 的 `--entitlements` 模式。`NanoMuseTipaBuilder` 在复制到
`Payload/` 后会再次调用 `codex-sign` 处理主程序，最终包内签名以打包阶段为准。

## 复用的现有模块

| 文件 | 复用内容 |
|---|---|
| `overlay/android/src/ios/NanoMuse/NanoMuseNyxian.swift` | `load()`、`Loaded.run(...)`、`detectSDK()`、`detectSwiftResources()`、`swiftLink(...)` |
| `overlay/android/src/ios/NanoMuse/NanoMuseSDKDownloader.swift` | `isInstalled()`、`installedSDKPath`、`ensureInstalled(...)` |
| `overlay/android/src/ios/NanoMuse/NanoMuseMachSigner.swift` | `sign(path:entitlements:identifier:)`、`hasSignature(path:)` |
| `overlay/android/src/ios/NanoMuse/NanoMuseTipaBuilder.swift` | `build(appPath:entitlements:outputName:)`（复制、Mach-O 重签、进程内 ZIP） |
| `overlay/android/src/ios/NanoMuse/NanoMuseHelperRunner.swift` | `exists(_:)`、`run(_:arguments:timeout:)`（codex-sign 回退） |
| `overlay/android/src/ios/NanoMuse/NanoMuseNativeRuntime.swift` | 由 SDK 下载器间接使用，指向 App 包内 `Runtimes/` |
| `Tools/patch_upstream.py` | 注入 `NanoMuseSwiftTipaTool.definition` 与 `case "swift_tipa"` |

没有重写 zip、签名或打包逻辑；新代码只做流程编排与临时目录/plist 组装。

## 已知限制

- **SDK 依赖**：必须存在 `iPhoneOS26.5.sdk`（`NanoMuseSDKDownloader.isInstalled()`、
  `NanoMuseNyxian.detectSDK()` 或自动下载三选一）。没有 SDK 会明确失败，不会产出坏包。
- **arm64e only**：目标三元组固定 `arm64e-apple-ios26.5`；链接后会检查产物 CPU 类型，
  非 arm64e 直接失败。
- **CoreCompiler 依赖**：需要约 186MB 的 `CoreCompiler.framework`，由运行时装好；
  缺失时返回安装指引。
- **Swift 资源依赖**：建议安装 `swiftrt`（`Shared/swift`）；缺 `-resource-dir` 时
  `import Foundation/UIKit` 可能失败。
- **GUI 程序约束**：源码必须包含 `UIApplicationMain`，否则工具拒绝编译。
- **多文件语义**：目录内所有 `.swift` 作为同一个模块一次编译成一个 `.o`；
  不生成独立 Swift 模块。
- **签名强度**：`NanoMuseMachSigner` 是 ad-hoc/SHA1 格式；TrollStore 可用，但不等于
  Apple 公证签名。
- **首次编译较慢**：CoreCompiler 首次解析 SDK 的 `.swiftinterface` 可能耗时数十秒、
  峰值内存较高，属正常现象。
- **设备端验证**：仓库内没有 Swift 编译器，无法在本环境跑 `swiftc`；只能做静态检查和
  patch 脚本检查，最终产物需在设备上验证。

## 如何验证

### 仓库内（不需要设备）

```sh
# JSON 注册表合法
python3 -c 'import json; json.load(open("docs/toolchain/registry/tools.json"))'

# patch 脚本语法
python3 -m py_compile Tools/patch_upstream.py

# 若上游树存在，检查注入是否会成功（不写文件）
python3 Tools/patch_upstream.py --root <upstream>/android/src/ios --check
```

### 设备上

1. 让 Codex 调用 `swift_tipa`，传 `docs/swift-tipa/template/main.swift`。
2. 检查返回 text 中的 `[1/6]`…`[6/6]` 每步日志，以及最终 `.tipa` 绝对路径。
3. 用 TrollStore 打开 `.tipa` 安装并启动。
4. 可选：解包检查 `Payload/<name>.app/Info.plist` 与可执行文件：

```sh
unzip -l HelloSwift.tipa
xxd -l 16 Payload/HelloSwift.app/HelloSwift   # cffaedfe ... 0c000001 = arm64e
```

### 失败排查

| 现象 | 检查点 |
|---|---|
| `CoreCompiler 加载失败` | 设置 → Codex 的原生运行时是否安装；`Runtimes/frameworks/CoreCompiler.framework` |
| `SDK 缺失且下载失败` | 手动放置 `iPhoneOS26.5.sdk` 到 `Documents/nyxian/` 或 `Runtimes/sdks/` |
| 编译报找不到模块 | `Shared/swift` 是否安装；`detectSwiftResources()` 路径是否正确 |
| 链接 undefined `UIApplicationMain` | 源码入口；`UIKit` / `Foundation` framework 是否完整 |
| `链接产物不是 arm64e` | SDK 架构与 `-target` 是否匹配 |
| 签名失败 | `NanoMuseMachSigner` 日志；`Helpers/codex-sign` 是否存在且可执行 |
| 打包失败 | `NanoMuseTipaBuilder` 的 `report.text`；输出目录写权限 |
