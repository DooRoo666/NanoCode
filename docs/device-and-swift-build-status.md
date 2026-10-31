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

- **2026-10-29 晚间：CreateJobs 闪退新线索与当前测试包**：设备日志确认 `dlopen`、`CCDriverCreate` 成功，最新终止为 `SIGABRT`，栈在 `llvm::report_bad_alloc_error → llvm::SmallVectorBase<unsigned int>::grow_pod → CCDriverCreateJobs`。此前把 allocator 当根因不成立。对照 C API 包装：`CCDriverCreate` 会内部加入 `swiftc`，宿主又显式加入 `swiftc`，造成 argv[0] 重复；已移除宿主重复项，保留 `kCFAllocatorSystemDefault`，重建 `NanoCodeHost-argv-fix.tipa`。ZIP 校验通过；尚未在设备端验证，不能宣称修复成功。若仍崩溃，下一步应从报告符号化确认 `CreateJobs` 抛出的分配大小，并检查参数传入约定，不再猜 allocator。

## 2026-10-29 晚：路线纠正 —— 必须移植 Nyxian 的 ObjC 包装层

**结论**：不再用裸 C 调用 CoreCompiler。Nyxian 的可用性来自完整的 ObjC 包装层 + CFRuntime 桥接：
- `Frameworks/MobileDevelopmentKit/Support/MDKCFType.{h,m}`：所有 `MDK*` 类型的基类，负责 `CFRuntimeCreateInstance`/`CFType` 互转
- `Tools/MDKDriver.{h,m}`：`[MDKDriver initWithDriverType:arguments:]` → `CCDriverCreate`，`-createJobs` → `CCDriverCreateJobs`
- `Tools/MDKJob.{h,m}`：`-execute` → `CCJobExecuteJob`
- `Tools/Compiler/MDKSwiftCompiler.{h,m}`：Swift 编译 Job 构造

裸 C 宿主在 `CCDriverCreateJobs` 里 SIGABRT（bad_alloc / SmallVector grow_pod），已排除 allocator、argv、CFArray 可变性、UInt8 枚举等猜测项 —— 说明问题在「没有 ObjC 实例/桥接」这条路径上，而不是某个参数。

**新路线**：在 iSH 用 `clang -target arm64e-apple-ios26.5` 把 MobileDevelopmentKit 的 `.m` 源码编进宿主（链接 CoreFoundation + libobjc），宿主只做 `[MDKDriver ...]` 调用，和 Nyxian 完全一致。若 `MDKCFType` 依赖私有头（org.coolstar.* 的 NSObject 私有 API），需裁剪成最小可编译子集。

**状态**：尚未构建出通过验证的 TIPA；此前所有裸 C 测试包（argv / allocator / cfarray / abi / bridge / diagnostic）均为失败路径，不可作为可用版本。

### 实施：ObjC 包装层宿主已构建（2026-10-29 22:20）

- 源码就位：`host/mdk/`（MDKCFType / MDKDriver / MDKJob / MDKDiagnostic / MDKSDK，全部来自 Nyxian 原文件），`host/include/{MobileDevelopmentKit,CoreCompiler}/` 为头文件镜像，`host/main.m` 宿主
- **无需裁剪**：Nyxian 的 MDK 源码用本 SDK（/tmp/tpk/iPhoneOS26.5.sdk）直接编过，Foundation 编译链接正常（objc/arc/blocks）
- API 实际签名：`+[MDKDriver driverWithArguments:withType:]`、`-[MDKDriver generateJobs]`、`-[MDKJob executeJobWithOutDiagnostics:withOutMainSource:]`、`MDKDriverTypeSwift`；诊断属性是 `message` 不是 `formatMessage`
- 链接：`-undefined dynamic_lookup` + `-lobjc -framework Foundation -framework CoreFoundation`，dlopen `Frameworks/CoreCompiler.framework/CoreCompiler` 后按需解析 CC* 符号 → 产物 98KB arm64e Mach-O
- 产物：`/var/minis/attachments/NanoCodeHost-objc.tipa`（65MB，Payload/17 文件，含 CoreCompiler.framework 及 9 个 SwiftSyntax dylib），ldid -Sent.plist 已签
- 日志：宿主写 `/var/mobile/Documents/nyxian/out.txt`（stdout/stderr + buffered NSLog 一并落盘）—— 上次设备运行 out.txt 为空，说明从未跑到我们的输出，本轮必须先看这个文件
- 待设备验证：装 → 打开 → 看 out.txt 是否出现 "CoreCompiler loaded" 与 "JOB OK / FAILED"

### 闪退根因（2026-10-29 22:30）：MDK 类缺失，dyld 加载期直接 abort

崩溃报告 `/var/mobile/Library/Logs/CrashReporter/NanoCodeHost-2026-10-29-222046.ips`：
```
Exception: EXC_CRASH (SIGABRT)
dyld | failed to instantiate Objective-C class 'MDKOSVersion' (errno=2 ...)
abort_with_payload -> NSPlaceholderString
```
out.txt 为空 → 崩在 `main` 之前，日志永远不会写。

缺的 4 个类：`MDKFile` `MDKFileSourceLocation` `MDKOSVersion` `MDKSourceLocation`（加进 `host/mdk/` 后仍未解析，因为**原因在头文件**）：
- `host/include/CoreCompiler/{CCFile,CCASTUnit,CCLinker,CCJob...}.h` 里有一批是 GitHub 404 页面（14 字节 `404: Not Found`），导致 `MDKFile.m` 编译失败被跳过
- 修复：用 `/tmp/nyxian-src/Frameworks/CoreCompiler/{,Support/}*.h` 覆盖全部 CoreCompiler 头
- `MDKOSVersion.m` 依赖 UIKit 头，而精简 SDK 的 UIKit 头链断裂（`UIUtilities/UIDefines.h` 缺失）→ 只加最小 `UIDevice` 前向声明 + idiom 枚举，去 `#import <UIKit/UIKit.h>`
- 验证方法已固化：`llvm-nm -u <binary> | grep MDK` 必须为 0，否则 dyld 必崩

### 第三次闪退（2026-10-29 22:34）：+load 期就碰 CoreCompiler

`NanoCodeHost-2026-10-29-223419.ips` 比前两次长（7213B），说明已经不是 dyld 缺类，而是执行到了 `+load`：
所有 MDK 类都实现了 `+ (void)load` 去做 C 类型 ↔ ObjC 类注册（如 `MDKDiagnostic+load` 调 CC 侧注册函数）。
进程启动阶段 dylib 还没加载时这些 +load 就会跑，碰 CoreCompiler 符号即崩 —— out.txt 依然 0 字节。

**处理**：把 7 个类里的 `+ (void)load` 全部改名为 `+ (void)mdk_registerBridge`（逻辑不变、暂不调用），
让进程先活着跑进 main，由 main 显式决定何时初始化。已知这只是「延后」，不是修复 —— 桥接注册终究要跑。
**下一步必须在 main 里先 dlopen 再显式调用这些注册方法**，否则 CoreCompiler 初始化后仍会缺类型。

### 第四次「闪退」＝无崩溃报告（2026-10-29 22:44）：缺 LC_RPATH

现象：CrashReporter 里最后一条仍是 22:34:19，`out.txt` 0 字节 → 进程在 dyld 阶段被 **静默终止，不生成 ips**。
已确认装的是新包（`/private/var/containers/Bundle/Application/76479DE9-.../NanoCodeHost.app`，可执行 149075 B）。

根因：`Frameworks/CoreCompiler.framework/CoreCompiler` 的 LC_LOAD_DYLIB 含 9 条
`@rpath/lib_Compiler*.dylib`（SwiftSyntax 插件），实体在
`CoreCompiler.framework/Frameworks/`。宿主二进制 **LC_RPATH 数量 = 0**，dyld 解析失败即 abort，
且因发生在 pre-main/装载期，系统不落 crash log。

修复：链接加 `-Wl,-rpath,@executable_path/Frameworks`（并补 `@executable_path/Frameworks/CoreCompiler.framework/Frameworks`）。
校验清单（每次打包必须过）：
1. `llvm-nm -u | grep MDK` = 0
2. `llvm-otool -l | grep LC_RPATH` ≥ 1
3. `llvm-otool -L Frameworks/CoreCompiler.framework/CoreCompiler | grep @rpath` 与 `LC_RPATH` 能对上

### 2026-10-30 07:00 突破：日志路径写错 + 找到真实失败点

**前四轮判断全部作废**：一直查的 `out.txt` 并非宿主日志。宿主的日志是
`/var/mobile/Documents/nyxian/nanolog.txt`（main.m 里写死）。该文件一直有内容：
```
[nano] start pid=%d
[nano] dlopen failed: %s
```
`%d`/`%s` 未替换 = LOG 宏把 fmt 直接当 %s 打印（已修成 va_list + initWithFormat）。

**真实结论：进程其实进到了 main，卡在 `dlopen(CoreCompiler)` 失败，main 返回 2。**
之前所有「没有日志 = 没进 main」的推断都是错的。

**执行验证方法（重要，以后照此）**：
- iSH `/var/minis/workspace/` == host `/var/mobile/Library/MinisChat/minis/01F19022-D3C7-4DDE-A125-46D604821622/workspace/`
  → **跨端通道是通的**，host 侧可直接执行 iSH 编译出的二进制（用于测试）
- 直接运行 iSH 编译 + ldid 签名的裸二进制 → `Bad executable (or shared library)` / exit 127
  → 裸文件不走 TrollStore 信任链，必须有 tipa 安装才可执行
- 已安装的旧版（149075B）可执行，`exit=2` 证实 main 跑到 dlopen

**下一步**：让 dlopen 成功。怀疑点排序：
1. CoreCompiler 在 `/var/mobile/Documents/nyxian/`（非 app 容器），沙箱外读取/映射可能被拒
2. 该文件被改动过（设备上 186857747 vs 原始 186805472，+52275）
3. 需 `RTLD_NOW` 或预先加载其 9 个 SwiftSyntax 依赖

## 【铁律】所有资源必须在 .app 内（用户 2026-10-30 明确要求）

**不要从 `/var/mobile/Documents/` 或任何沙箱外路径 dlopen / 读取可执行资源。**

- 原因：iOS 对沙箱外映射 Mach-O 有严格限制，会导致 dlopen 失败
- 正确位置：`NanoCodeHost.app/Frameworks/CoreCompiler.framework/`
  - 主库：`Frameworks/CoreCompiler.framework/CoreCompiler`
  - 嵌套依赖：`Frameworks/CoreCompiler.framework/Frameworks/`（13 个 `@rpath/lib_Compiler*.dylib`）
- 路径解析统一用 `[[NSBundle mainBundle] bundlePath]` 相对拼接，禁止硬编码绝对路径
- 需要外部文件（SDK 等）时，先复制进 bundle 或容器，再使用

**唯一例外**：调试日志可写 `/var/mobile/Documents/nyxian/nanolog.txt`（host 侧可读），
写失败自动回落 `NSTemporaryDirectory()`。

### 打包前必查三项
1. `llvm-nm -u <exe> | grep MDK` == 0
2. `llvm-otool -l <exe> | grep LC_RPATH` >= 1，且含 `@executable_path/Frameworks`
3. CoreCompiler 的每条 `@rpath` 依赖都能被某个 LC_RPATH 解析

## 【里程碑 2026-10-30 07:31】宿主链路全线打通：dlopen + dlsym 成功

改为 app 内路径后，`nanolog.txt` 记录完整：

```
[nano] start pid=21427
[nano] bundle=/private/var/containers/Bundle/Application/76479DE9-.../NanoCodeHost.app
[nano] depsDir exists=1
[nano] dep count=13
[nano] dlopen ok handle=0xf7b306d0
[nano] dlsym CCDriverCreate -> 0x10d908fc8
[nano] dlsym CCDriverCreateJobs -> 0x10d909548
[nano] dlsym CCJobExecuteJob -> 0x10d8f0bcc
[nano] stage1 done, log=/var/mobile/Documents/nyxian/nanolog.txt
```

**结论：dlopen CoreCompiler 成功、三个核心 C API 符号全部解析到真实地址。**
之前的失败 100% 是因为从 `/var/mobile/Documents/nyxian/` 沙箱外路径加载 → 印证「资源必须放 .app 内」这条铁律。

### 关于「闪退」
CrashReporter 里最后一条 NanoCodeHost 崩溃是 10-29 22:34，本次运行（10-30 07:31）
**没有产生任何崩溃报告** → 进程是**正常退出**，不是 crash。
原因：宿主是**无窗口 Console App**，stage1 跑完 main 返回即终止，iOS 表现为「一闪而过」。

### 下一步（stage2）
1. 让进程常驻：加 `UIApplicationMain` + 最小 AppDelegate（或 runloop + 无人值守执行完即停但不秒退）
2. 调 `CCDriverCreate(alloc, args, kCCDriverTypeSwift)` 建 driver
3. 调 `CCDriverCreateJobs` → `CCJobExecuteJob` 真正跑编译
4. 已知硬缺口仍在：swift-frontend 需 fork、stdlib .swiftmodule 缺 arm64

### stage2-常驻版（2026-10-30 07:36）

方案 A：把宿主改成常驻 UIApplication。

**关键约束**：SDK 里 `UIKit/UIKitDefines.h` 引用了 `UIUtilities/UIDefines.h`，
但 `UIUtilities.framework` 是 Apple 内部框架、**不在公开 SDK**，导致 `#import <UIKit/UIKit.h>` 直接编译失败。
**解决**：完全不 include UIKit 头，改用纯 runtime 调用：
- `objc_getClass("UIApplication")` / `"UIWindow"` / `"UIColor"` / `"UILabel"`
- `objc_msgSend` 分发所有消息
- 只 `-framework UIKit` 让 ldid 记录 LC_LOAD_DYLIB（UIKit 是公开库，加载没问题）

Info.plist 同步修改：**删掉 `UIApplicationSceneManifest`**（没有 SceneDelegate 会黑屏/闪退），
改用旧式 app delegate + `UIApplicationMain(argc, argv, nil, "NCHAppDelegate")`。

日志仍是 `/var/mobile/Documents/nyxian/nanolog.txt`（host 可读），失败回落 tmp。

校验：`nm -u | grep MDK` = 0；`LC_RPATH` = 1；binary 109032 B。

### CC 导出符号实测（2026-10-30 07:40，mmap 扫描 186MB 二进制）

共 **90 个 `_CC*` 导出符号**。**修正**：`CCJobCreateArguments` **在 6.3.2 里没有导出**
（头文件 CCJob.h 有声明但二进制里查不到，可能是 hidden/static），dlsym 返回 0x0 属正常。

**真实可用签名**（来自 cc/Support/CCJob.h）：
```c
CCJobRef CCJobCreate(CFAllocatorRef allocator, CCJobType type,
                     CFArrayRef CC1Arguments, CFArrayRef inputFileURLs, CFURLRef outputFileURL);
Boolean  CCJobExecuteJob(CCJobRef job, CFArrayRef *outDiagnostic, CFStringRef *outMainSource);
```

**stage2 所需符号全部存在**：
- `CCDriverCreate` / `CCDriverCreateJobs` / `CCDriverCopySysrootURL`
- `CCJobCreate` / `CCJobExecuteJob`
- `CCFileCreateWithFilePath` / `CCFileCreateWithCString`
- `CCSwiftCompilerJobExecute` / `CCCompilerJobExecute`

### 关于「黑屏」
日志有 `didFinishLaunching` 但**没有 `window created`** → 窗口创建代码没执行到。
所以黑屏＝窗口未建立，不是渲染问题。不影响编译链路，暂不修。

### stage2 上机版（2026-10-30 07:49）— 首个真正执行编译的版本

**决定性结论：不需要 fork。**
`cc/CCSwiftCompiler.cpp:130` → `swift::performFrontend(args,"swift-frontend",nullptr,&obs)`
是**进程内直调**，CC 源码全文 grep `exec/fork/spawn` 零命中。
→ 之前「fork SIGBUS 导致本机无法编 Swift」的结论**作废**，这条不是阻塞项。

`CCSwiftCompilerJobExecute` 自身会移除首参等于 `-frontend` 的元素，
再调 `initializeSwiftModules()`（swift 内部，call_once 保护），
并 `LLVMInitializeAArch64*` → 产出 **arm64** 对象。

stage2 流程（host/stage2.c）：
1. dlopen CoreCompiler.framework/CoreCompiler
2. dlsym: CCDriverCreate / CCDriverCreateJobs / CCJobExecuteJob / CCDriverCopySysrootURL
3. 建 CFArray 参数：swiftc -c -target arm64e-apple-ios26.5 -sdk <sdk> -o /tmp/stage2_out.o
4. CCDriverCreate(base,args,type=1 swift) → CCDriverCreateJobs → 逐 job CCJobExecuteJob
5. 打印 diag 数组每条诊断

接线：main.m didFinishLaunching 里调 stage2_run(...)，日志仍进 nanolog.txt。
产物：/var/minis/attachments/NanoCodeHost-s2.tipa（62MB）
