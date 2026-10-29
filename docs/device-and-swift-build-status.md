# 设备与 Swift 编译链路 —— 唯一事实来源

> 本文件是 NanoCode「本机 Swift 编译 → tipa」这条线的权威结论。任何与此冲突的说法以本文件为准。
> 最后更新：2026-10-29 下午

---

## 1. 设备信息（不要再看错）

| 项目 | 值 | 证据 |
|---|---|---|
| 型号 | **iPhone15,2** | `uname -m` → iPhone15,2 |
| 代号 | **iPhone 14 Pro** | A16 芯片 |
| 架构 | **arm64e**（`cputype 0x0100000c`） | A12 及以后全部 arm64e |
| iOS | 26.5 | SDK 为 iPhoneOS26.5.sdk |
| 可执行架构 | arm64e **向下兼容** arm64 | 编译成 arm64e 可直接安装运行 |

> ⚠️ **常见错误纠正**：
> - 本机 **不是 arm64**，是 **arm64e**。
> - 「缺 arm64 模块」说的是 **SDK 里 arm64 目标接口为 0**，不是设备架构问题。
> - 设备是 arm64e，与 SDK（arm64e 单架构）、CoreCompiler（arm64e dylib）**三方完全一致**。

---

## 2. `.swiftmodule` 是什么

三层概念，务必分清：

| 层 | 文件 | 作用 |
|---|---|---|
| 接口层 | `.swiftmodule`（二进制）/ `.swiftinterface`（文本） | 编译器读取的**类型签名**。没有它 `import Foundation` 直接报错 |
| 库层 | `.tbd` / `.a` / `.dylib` | 链接期使用 |
| 运行时层 | 系统 `libswiftCore.dylib` | 运行期使用（iOS 26 已内联进 dyld shared cache，文件系统里看不到，属正常） |

`.swiftmodule` **不是 SDK 本体**，是 SDK 里的接口签名部分。

---

## 3. 资源盘点（全部实测）

### 3.1 SDK：`/private/var/mobile/Documents/nyxian/iPhoneOS26.5.sdk`

- `*.swiftinterface` = **254 个**，**全部是 `arm64e-apple-ios`**
- `arm64-apple-ios.swiftinterface` = **0 个** → 所以 `-target arm64-apple-ios` 会失败；用 `arm64e` 即可
- 254 个接口**全部含 `swift-module-flags` 行**，即**全部是纯文本可读格式**，可被 swift 现场编译成模块
- 样本头：
  ```
  // swift-interface-format-version: 1.0
  // swift-compiler-version: Apple Swift version 6.3.2 effective-5.10
  // swift-module-flags: -target arm64e-apple-ios26.5 -enable-objc-interop ...
  ```
- `*.tbd` = 705 个，targets 全为 `[ arm64e-ios ]`
- `*.h` = 7068，`*.modulemap` = 273
- Foundation 接口：`System/Library/Frameworks/Foundation.framework/Modules/Foundation.swiftmodule/arm64e-apple-ios.swiftinterface`
- Swift stdlib 接口：`usr/lib/swift/Swift.swiftmodule/arm64e-apple-ios.swiftinterface`
- `usr/lib/swift/` 下 **58 个** `.swiftinterface`；`System/Library/Frameworks` 下 **189 个**

### 3.2 `Shared/swift`（`/private/var/mobile/Documents/nyxian/Shared/swift`，142MB）

顶层：`apinotes/ clang/ FrameworkABIBaseline/ host/ iphoneos/ migrator/ module.modulemap shims/ swiftToCxx/`

实测统计：
- `*.swiftmodule` = **24 个**
- `*.swiftinterface` = **36 个**
- `*.swiftdoc` = 12 个

**24 个 swiftmodule 的完整清单**（全部在 `Shared/swift/` 根下，均为 `arm64-apple-ios`）：

```
SwiftBasicFormat.swiftmodule/arm64-apple-ios.swiftmodule
SwiftCompilerPluginMessageHandling.swiftmodule/arm64-apple-ios.swiftmodule
SwiftDiagnostics.swiftmodule/arm64-apple-ios.swiftmodule
SwiftIfConfig.swiftmodule/arm64-apple-ios.swiftmodule
SwiftLibraryPluginProvider.swiftmodule/arm64-apple-ios.swiftmodule
SwiftOperators.swiftmodule/arm64-apple-ios.swiftmodule
SwiftParser.swiftmodule/arm64-apple-ios.swiftmodule
SwiftParserDiagnostics.swiftmodule/arm64-apple-ios.swiftmodule
SwiftSyntax.swiftmodule/arm64-apple-ios.swiftmodule
SwiftSyntaxBuilder.swiftmodule/arm64-apple-ios.swiftmodule
SwiftSyntaxMacroExpansion.swiftmodule/arm64-apple-ios.swiftmodule
SwiftSyntaxMacros.swiftmodule/arm64-apple-ios.swiftmodule
```

**结论（重要）**：这些是 **SwiftSyntax / 编译器插件** 的模块（用于宏、语法树），**不是 stdlib**。
**stdlib / Foundation 的模块接口在 SDK 里，且是 arm64e 文本格式** → 之前「本机没有 stdlib .swiftmodule」的判断**已被推翻**。

### 3.3 CoreCompiler.framework

```
/private/var/mobile/Documents/nyxian/CoreCompiler.framework/
  CoreCompiler          186,805,472 B
  Frameworks/           lib_CompilerSwift{Parser,Syntax,...}.dylib × 13
```

- `CoreCompiler` = **MH_DYLIB**（filetype 6），cputype `0x0100000c` = **arm64e**，platform iOS，minos 16.0 / sdk 26.0
- 只能被 `dlopen` 进进程，**不能直接 spawn**
- 无 `Headers/` 目录（头文件要从 GitHub 源拉）

---

## 4. C API 能否直接调用 → **能**

### 4.1 导出符号实测

`CoreCompiler` 导出 **90 个 `_CC*` 符号**，全部 `N_EXT` + `sect=1`（已导出）。关键：

```
_CCDriverCreate                    _CCJobCreate
_CCDriverCreateJobs                _CCJobGetType
_CCDriverCopySysrootURL            _CCJobCreateArguments
_CCDriverCopySDK                   _CCJobExecuteJob
_CCSDKGetTypeID                    _CCSwiftCompilerJobExecute
_CCDiagnosticCreate                ...
```

**`swift::performFrontend` 在库内是静态链接**（二进制里能搜到 mangled 名 `_ZN5swift15performFrontendEN4llvm8ArrayRefIPKcEES3_PvPNS_16FrontendObserverE`）。

### 4.2 头文件已拉全（`/var/minis/workspace/NanoCode/cc/`）

```
CCDriver.h   CCSDK.h   CCDependency.h
Compiler/CCCompiler.h   Compiler/CCSwiftCompiler.h
Support/CCJob.h  Support/CCDiagnostic.h  Support/CCFile.h
Support/CCFileSourceLocation.h  Support/CCSourceLocation.h
```
来源：`https://github.com/emexlab/Nyxian` → `Frameworks/CoreCompiler/`

### 4.3 关键源码结论：**不 fork，不 exec**

`Tools/Compiler/CCSwiftCompiler.cpp:130`：

```cpp
int status = swift::performFrontend(args, "swift-frontend", nullptr, &obs);
```

→ Swift 前端**在进程内直接调用**，**没有 fork/exec swift-frontend 子进程**。

对全部 `CCDriver.cpp / CCSDK.cpp / CCSwiftCompiler.cpp / CCCompiler.cpp` grep `exec|fork|spawn|dlopen` → **仅命中上面这一行 performFrontend，无任何 exec/fork/spawn**。

> ⚠️ **推翻旧结论**：早前记录说「编译器是 driver，编 .swift 时会 exec 自身 swift-frontend 子进程 → 本机 fork 必 SIGBUS」。
> 这是 **swift-driver 通用行为**，但 **Nyxian 用的这条路径不走 driver 进程模型**：
> `CCDriverCreate(type=kCCDriverTypeSwift)` 只做**任务规划**（生成 job 列表），
> 真正执行的是 `CCJobExecuteJob` → `CCSwiftCompilerJobExecute` → **进程内 performFrontend**。
> **因此不需要 fork，fork 不可用不再是阻塞项。**

### 4.4 调用链（可直接照写）

```
CCDriverCreate(alloc, argsArray, kCCDriverTypeSwift)
  → CCDriverCreateJobs(alloc, driver)          // 得到 CCJobRef 数组
  → CCJobExecuteJob(job, &diags, &mainSource)  // → CCSwiftCompilerJobExecute
       → swift::performFrontend(args, "swift-frontend", nullptr, &obs)
```

---

## 5. 结论：本机能不能编 Swift → **能**

| 要素 | 状态 | 说明 |
|---|---|---|
| 设备 arm64e | ✅ | 与 SDK/编译器一致 |
| SDK arm64e stdlib/Foundation 接口 | ✅ | 254 个文本 `.swiftinterface`，可现场编译成模块 |
| CoreCompiler dylib | ✅ | 在 `/private/var/mobile/Documents/nyxian/` |
| C API 可调用 | ✅ | 90 个 `_CC*` 导出符号 |
| 无 fork 依赖 | ✅ | 进程内 `performFrontend` |
| 宿主程序（写 C/ObjC 调用上述 API） | ❌ | **这是唯一剩下的活** |
| 链接期 `.tbd` / `-L` 路径 | ✅ | SDK 内 705 个 tbd |
| 打包成 tipa | ✅ | `tipa_build` 工具可用 |

### 目标三元组（写代码时必须用这个）

```
-target   arm64e-apple-ios26.5
-sdk      /private/var/mobile/Documents/nyxian/iPhoneOS26.5.sdk
-resource <SDK>/usr/lib/swift   (以及 Shared/swift 的 module.modulemap)
```

### 剩余工作清单

1. 写宿主 App：用 `dlopen` 加载 `CoreCompiler.framework/CoreCompiler`，`dlsym` 取 `_CCDriverCreate` / `_CCJobExecuteJob` 等
2. 组装 swiftc 风格参数（`-frontend` 开头的会被 `CCSwiftCompiler.cpp` 自动剥掉）
3. 收集诊断 → 映射为 UI 报错
4. 产物 `.o` → 用 `ld64.lld` + SDK `.tbd` 链接成 arm64e Mach-O → `ldid` 签名 → `.app` → `tipa_build`

---

## 6. 变更记录

- **2026-10-29 下午**：推翻「本机缺 stdlib .swiftmodule」与「必须 fork swift-frontend」两条旧结论；
  实测 SDK 的 254 个 `.swiftinterface` 全为文本 arm64e，且 CCSwiftCompiler 走进程内 `performFrontend`。
  判定本机 Swift 编译可行，剩余工作为编写宿主程序。
