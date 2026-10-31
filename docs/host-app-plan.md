# CoreCompiler 宿主 App 实施方案（2026-10-29 下午）

唯一事实来源。上下文压缩后先读本文件。

## 一、已验证的事实（实测）

### 1.1 CoreCompiler 二进制
- 路径（主机侧）：`/private/var/mobile/Documents/nyxian/CoreCompiler.framework/CoreCompiler`
- 大小 186,805,472 B；**MH_DYLIB**（filetype 6），cputype `0x0100000c` = **arm64e**
- 导入符号 **0 个** → 完全自包含，Swift 运行时静态链接在库内
- 导出 `_CC*` 符号 128 个（见 `docs/corecompiler-symbols.txt`）
- Swift 版本 **6.3.2**

### 1.2 调用链（源码实证，cc/ 目录 = Nyxian 原版 CoreCompiler 源码）
`cc/CCDriver.cpp:130` → `swift::performFrontend(args, "swift-frontend", nullptr, &obs)`
→ **进程内直调，不 fork、不 exec**。全部 CC 源码 grep exec/fork/spawn **零命中**。
→ 推翻旧结论「fork SIGBUS 是阻塞项」。

### 1.3 C API（头文件在 `cc/`，可直接 include）
```
CCDriverRef CCDriverCreate(CFAllocatorRef, CFArrayRef args, CCDriverType);
CFArrayRef  CCDriverCreateJobs(CFAllocatorRef, CCDriverRef);
CCJobRef    CCJobCreate(CCAllocatorRef, CCJobType, CFArrayRef cc1Args, CFArrayRef inputs, CFArrayRef outputs);
CFArrayRef  CCJobCreateArguments(CCAllocatorRef, CCJobRef);
Boolean     CCJobExecuteJob(CCJobRef, CFArrayRef *outDiag, CFStringRef *outMainSrc);
Boolean     CCSwiftCompilerJobExecute(CCJobRef, CFArrayRef *outDiag, CFStringRef *outMainSrc);
CFTypeID    CCSDKGetTypeID(void);
```
`CCDriverType`: kCCDriverTypeSwift / kCCDriverTypeClang / kCCDriverTypeLinker
`CCJobType`: kCCJobTypeCompiler=0, kCCJobTypeDriver, kCCJobTypeSwiftCompiler, kCCJobTypeSwiftDriver, kCCJobTypeLinker, kCCJobTypeUnknown

### 1.4 Driver 参数流
`CCDriverCreate` 收 `CFArrayRef args`（swiftc 风格命令行）→
`CCDriverCreateJobs` 内部 `driver->swiftDriver->buildCompilation(...)` →
逐 job 取 `J->getArguments()` → 组装 `CCJobType` + args 数组 → `CCJobCreate`。
Job kind 映射（`CCDriver.cpp:251`）：
- CompileJob / BackendJob / MergeModuleJob / ModuleWrapJob / GeneratePCHJob /
  AutolinkExtractJob / VerifyModuleInterfaceJob → **kCCJobTypeSwiftCompiler**
- DynamicLinkJob / StaticLinkJob → kCCJobTypeDriver

### 1.5 工具链与 SDK（设备上真实存在）
- Swift 资源目录：`/private/var/mobile/Documents/nyxian/Shared/swift`（142MB）
- SDK：`/private/var/mobile/Documents/nyxian/iPhoneOS26.5.sdk`
- 二进制本体：`.../nyxian/CoreCompiler.framework/CoreCompiler`（MH_DYLIB）
  → **Nyxian 运行时就是从 Documents 目录 dlopen 它**，我们照做即可，**不必打包 186MB 进 .app**

### 1.6 执行环境（实测）
| 事实 | 证据 |
|---|---|
| iSH 可交叉编译 arm64e-iOS 可执行文件 | clang19 + `-fuse-ld=lld` + `-isysroot iPhoneOS26.5.sdk` 成功 |
| iSH `ldid` 坏了 | `ldid -S` → `mmap: Invalid argument` |
| 宿主有 `codex-sign` | `/private/var/containers/Bundle/Application/*/Minis.app/Helpers/codex-sign`，支持 `--adhoc-only` `--entitlements` |
| **裸 ad-hoc 二进制在设备上跑不了** | `./_hello3` → SIGKILL(137)；加 entitlements 也 `Bad executable` |
| **已安装 .app 的主程序可以直接 exec** | 复制 Minis.app 主程序 → 直接运行成功（dyld 正常加载） |
| 宿主 fork 不可用 | `forktest-arm64e` → `child killed by signal 10` |
| 宿主 posix_spawn 可用 | nsh 本身基于 posix_spawn |

**结论：自编工具必须打包成 .app（tipa）安装，不能裸跑。**

### 1.7 传输通道（实测可用）
- iSH → 主机：写 `/var/minis/workspace/X` 即可，主机在
  `/private/var/mobile/Library/MinisChat/minis/<会话UUID>/workspace/X` 可见
  （本会话 UUID = `01F19022-D3C7-4DDE-A125-46D604821622`）
- 主机 → iSH：`host_exec cat <主机路径> > /private/var/mobile/Library/MinisChat/minis/<UUID>/workspace/_x`
- 注意：**iSH 的 `/var/mobile/Documents` 与主机真实 Documents 是两套目录**
- 注意：宿主没有 `cat`/`tee`/`cp`/`mkdir`，只有 Helpers 里那 30 来个；用 `cat >` 重定向写文件

## 二、剩余唯一工作

写宿主 App（Objective-C/C，无 Swift 依赖）：
1. `dlopen` CoreCompiler 路径
2. `dlsym` 取 `_CCDriverCreate` `_CCDriverCreateJobs` `_CCJobExecuteJob` 等
3. 构造 swiftc 风格 args → Create → CreateJobs → 逐 job Execute
4. 处理 diagnostics
5. 链接 → ldid 签名 → tipa_build → 用户安装

## 三、编译宿主 App 的技术要点
- 目标：`arm64e-apple-ios14.0`，`-isysroot /tmp/tpk/iPhoneOS26.5.sdk`
- iSH 里的 SDK 解压在 `/tmp/tpk/iPhoneOS26.5.sdk`（213MB）
- 链接用 `-fuse-ld=lld`
- 签名用宿主 `codex-sign`（iSH 的 ldid 已坏）
- `tipa_build` 工具可把任意 .app 打包成 tipa

## 四、待验证风险
- CoreCompiler 内部会找 `-resource-dir` / `-sdk` / `-target`；由 driver 的 swiftToolChain 提供，
  需确认它指向 `Shared/swift` 与 `iPhoneOS26.5.sdk`（Nyxian 运行时配置未知，可能在 Info.plist 或代码里）
- `import Foundation` 是否成功：SDK 里 Foundation.swiftinterface **是文本 arm64e**，
  配 `-target arm64e-apple-ios26.5` 应可现场编译模块

## 五、变更记录
- 2026-10-29 下午：建立本文档，固化全部实测事实
