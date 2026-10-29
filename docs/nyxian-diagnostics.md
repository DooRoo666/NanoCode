# Nyxian 编译器嵌入 — 实测诊断记录（2026-10-29）

## 结论先行

1. **不缺 swift resource dir**：设备上已有 `/var/mobile/Documents/nyxian/Shared/swift`（142MB，`host/`、`iphoneos/arm64/`、`iphoneos/swiftmodule/`、`clang/include`、`module.modulemap` 都在）。旧结论「缺 128MB CoreCompilerSupportLibs 分片」作废。
2. **设备上的 CoreCompiler 是 Swift 6.3.2（swift-6.3.2-RELEASE）**，工作区里那份 186MB 的也是 6.3.2。
3. 真正阻塞（待最终验证）：
   - **① 编译器是 Unix 式 driver**：二进制里 14 处 `posix_spawn`，会 spawn `swift-frontend` 子进程；而本机 fork 不可用（`Helpers/forktest-arm64`、`forktest-arm64e` 均 `child killed by signal 10`，iOS 26.5 arm64e 对非越狱 app 的 fork 子进程判 PAC 失败）。Minis 自带 bash 也为此改成了无 fork 的 nsh + bash.real 混合。
   - **② Foundation 只有 `arm64e-apple-ios.swiftinterface` 的 SDK 里，给它编 arm64 目标时 `import Foundation` 会失败**（需要 6.3.2 自己的 resource dir 里带 Apple-like 的 `Foundation.swiftmodule`）。

## 已确认的事实（带证据）

- 本机 SDK：`iPhoneOS26.5.sdk/System/Library/Frameworks/Foundation.framework/Modules/Foundation.swiftmodule/` 里只有 `arm64e-apple-ios.swiftinterface` + `arm64e-apple-ios.swiftdoc` + `module.modulemap`，**没有 arm64 变体**。
- 那份 swiftinterface 头是 `swift-interface-format-version: 1.0` / `compiler-version: 1200.x`（Apple Xcode 风味），编译时它是**和当前 Swift 版本编译出的模块锁死**的，所以必须由同一 6.3.2 构建生成的主 resource dir 提供 Foundation。
- resource dir 只找到「module.modulemap + shims + clang/include + iphoneos/arm64」这些，`swift/include/` 是符号链接且已被抹平（打包脚本只保留 `lib/swift/clang/include` 的链接）。
- 从 swiftlang/swift 源码 tag `swift-6.3-RELEASE`（sha aa782beb）的 git tree 里找到了与 6.3.2 为同源的 stdlib `.swiftinterface`（`test/ModuleInterface/swift_build_sdk_interfaces/Inputs/mock-sdk/usr/lib/swift/*.swiftinterface`，含 Swift、Foundation、Dispatch、Observation、_Concurrency 等），可通过 `api.github.com/.../contents/...?ref=<sha>` 下载（工作区 `fetch_resdir.sh` 已写好）。
- 上游构建：`emexlab/LLVM-On-iOS`（master 分支），`Scripts/build-swift-toolchain.sh` 产出 `SwiftToolchain.zip`，Swift 版本取自 `Config.xcconfig`（工作区 6.4.0，需改成 6.3.2），产物 `usr/` 下是 `share/swift/include`、`lib/swift/iphoneos` + `swiftStatic`，Nyxian 侧安装到 `Shared/SwiftToolchain`。**该流水线依赖真 Mac/Xcode，不能在设备上跑。**
- 网络：`download.swift.org` 直连可通，下载 6.3.2-RELEASE 的 osx.pkg 约 256KB/s（1.5GB ≈ 1.5h+），磁盘 `/` 剩余 7GB。
- 备选：绕开 fork 需要 `swift-frontend` 单进程形态（6.3.2 同批构建），或改走 C/C++（Clang 有进程内 API）。

## 用户已有 token

GitHub token 已重新配在 `/var/minis/shared/secrets/gh_token`（账号 DooRoo666）。**不要在文档/日志里写 token 明文。**

## 变更记录

- 2026-10-29：建立本文档；推翻「缺分片包」结论；定位 fork 与 arm64e-only 的 Foundation 接口两个阻塞点；准备从 swift 源码 tag 拉 6.3.2 的 swiftinterface。

## 变更记录（2026-10-29 下午·重要推翻）

本文档的「两个阻塞点」结论**均已被推翻**，详见新文档
`docs/device-and-swift-build-status.md`（唯一事实来源）：

- ❌「编译器是 Unix 式 driver，14 处 posix_spawn 会 spawn swift-frontend 子进程」→ **错**。
  `Tools/Compiler/CCSwiftCompiler.cpp:130` 实际是 `swift::performFrontend(args,"swift-frontend",nullptr,&obs)`，
  **进程内直调，不 fork 不 exec**。全部 CC 源码 grep exec/fork/spawn 零命中。fork SIGBUS 不再是阻塞项。
- ❌「Foundation 只有 arm64e 接口，编 arm64 会失败」→ **前提错了**。设备是 **arm64e**（iPhone15,2 / A16），
  直接用 `-target arm64e-apple-ios26.5` 即可；SDK 里 254 个 `.swiftinterface` **全是文本 arm64e 且可读**，
  现场即可编译成模块，不需要什么 6.3.2 专属 resource dir。
- ✅ 新结论：`Shared/swift` 的 24 个 `.swiftmodule` 是 SwiftSyntax/编译器插件，不是 stdlib；
  stdlib 接口从 SDK 取即可。

