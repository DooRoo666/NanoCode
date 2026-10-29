# Nyxian 编译器内核嵌入本工具（知识库 / 防上下文丢失）

> 维护约定：本文件是这条线的**唯一事实来源**。每次有实质结论（新发现、修复、参数变更、构建结果）就追加到「变更记录」并在对应章节更正。上下文压缩后先读这份。

## 1. 目标

把 Nyxian 的编译能力（`CoreCompiler.framework` = clang + Swift driver + ld64）嵌入本工具，实现「Swift 源码 → 本机打包成 .tipa → TrollStore 装 → 能跑」。

对标 Nyxian 原版：`prepare → build(compile+link) → install(sign) → package(zip)`

## 2. 设备与环境事实

- 设备：**iPhone 14 Pro（A16，arm64e），iOS 16.x**，TrollStore 环境；本 App = `Minis.app`（nanoMuse）
- 注意：设备上的 SDK 是 `iPhoneOS26.5.sdk`（只是 SDK 版本号），**部署目标仍是 ios16.0**（探测参数已按 ios16.0）
- App 包路径（会随重装变化）：
  `/private/var/containers/Bundle/Application/5593ECD4-90C1-4C7B-85CE-58387BC3BBFF/Minis.app`
  每次重装 UUID 变，从 `nyxian-diag.txt` 第 2 行 `bundle:` 读最新值
- 重装会清空：`/var/minis/shared/`（含 gh_token）、`/var/minis/memory/`；**不**清 `/var/minis/workspace/`
- 安装包必须自带运行时（见 §3），否则编译能力全废

## 3. 运行时 CoreCompiler.framework（编译内核）

- 组成：`CoreCompiler`（clang + Swift driver + ld64 一体，约 186.8MB）+ `Frameworks/` 下 13 个 `lib_CompilerSwift*.dylib`（约 21.3MB）+ `Info.plist`
- 本机副本：
  - `/var/minis/workspace/nyxian/CoreCompiler.framework/`（工作副本）
  - `/root/nyx/Payload/emexDE.app/Frameworks/CoreCompiler.framework/`
  - 设备侧已 ldid 重签：`/var/mobile/Documents/nyxian/CoreCompiler.framework/`
- **血泪结论：外置路径（Documents / Application Support）一律 `code signature invalid`**
  已证明不是签名问题（`machosig.py` 校验：签名块覆盖到 EOF，45253 个页哈希全匹配）。
  Minis.app 有 `disable-library-validation`、`platform-application`、`get-task-allow`，但**没有** `dynamic-codesigning` / `run-unsigned-code`，
  故只有**包内**二进制享受豁免 → 运行时必须由 CI 打进 `Minis.app/Runtimes/frameworks/`。
- CI 打包来源：GitHub release `runtime-deps`（id `427346598`）资产 `CoreCompiler.zip`（67.8MB）

## 4. 崩溃根因（三条，都已定位）

1. **签名/路径**（已修）：外置 dylib 加载失败 → `dlopen` 返回 NULL（`symbol lookup error: dlsym(0x0, `）。修法=包内预置（§3）。
2. **`CCSwiftCompilerJobExecute` 失败路径有 `CFRelease(NULL)` → SIGTRAP + 0x50 地址**
   即「编译器一报错，App 就崩」，与我们的源码无关。修法=**子进程隔离**（`fork` 后子进程跑编译，父进程只读结果）。
3. **Swift 的 Darwin overlay 禁用 `fork()`**（编译期报错 `'fork()' is unavailable` → CI 构建失败）
   修法=`dlsym(RTLD_DEFAULT,"fork")` 取符号指针再调用；同时给子进程加 180s 超时 `SIGKILL` 兜底。

相关代码：`overlay/android/src/ios/NanoMuse/NanoMuseNyxian.swift` 里的 `callFork()` / `isoRun()`

## 5. Nyxian 原版流水线与参数（源码实证）

源码：`/tmp/Nyxian-main`（宿主副本 `/var/mobile/Documents/alpine-rootfs/data/tmp/Nyxian-main`）
对应文件：`Nyxian/LindChain/IDEFoundation/NXCodeTemplate.m`、`.../Compiler/NXCompile.m`、`NXBuildOnce.m`、`NXLockup.m`

四阶段：`prepare`（生成 .m/.swift 包装、Info.plist、entitlements）→ `build`（compile+link）→ `install`（ldid 签名）→ `package`（zip）

**App 类型默认 Swift 参数（原文）**
```
-target arm64-apple-ios$(NXDeploymentTarget)
-Xllvm -aarch64-use-tbi
-Xfrontend -enable-objc-interop
-sdk $(SDKROOT)
-resource-dir $(BSROOT)/swift
-module-cache-path $(BSROOT)/ModuleCache
-parse-as-library            # 仅 App 类型
```
注意：**target 是 arm64，不是 arm64e**；`-resource-dir` 指向 bootstrap 的 `swift/`，**不是** SDK 里的 `usr/lib/swift`。
ObjC 侧还需：`-fobjc-arc`、`-fmodules`、`-fobjc-runtime=ios-*`、`-Wno-...` 等（见 NXCompile.m）。

## 6. 当前最大缺口：`swift` 资源目录（BSROOT/swift）

- 设备上**不存在**该目录（已全盘搜过容器）；Nyxian 的 bootstrap 从未下载完整。
- 它来自 Nyxian 依赖包：`CoreCompilerSupportLibs.tar.gz.part-aa/ab/...`（合计 128MB+），公开 release 可下。
- 它提供 Swift 标准库/overlay 的 `.swiftmodule`（含 Foundation 的 arm64 二进制模块），**没有它 `import Foundation` 必失败**。
- 之前的做法：把 SDK 的 `usr/lib/swift` 当 resource-dir → 头文件/模块缺失，走的是错误路径。

## 7. 本机探测机制（App 内自检，用于代替真机调试）

- 开关文件：`Documents/nyxian-probe-enable`（存在=开机跑探测）
- 参数文件：`Documents/nyxian-swift-args.txt`，行格式 `名称|kind|参数…`，kind ∈ {app, exe, dylib, object}
  支持占位符 `%SDK% %RES% %WORK% %SRC% %OBJ%`；`#` 开头为注释
- 结果文件：`Documents/nyxian-swift.log`、`Documents/nyxian-diag.txt`（末 12 行：版本/编译结果/dlopen 尝试）
- 每个参数组独立子进程执行 → 一组挂掉不影响其它组

## 8. CI 与构建

- 仓库：`DooRoo666/NanoCode`，分支 `refactor/runtime-download`；workflow `ios-tipa.yml`（仅 workflow_dispatch）
- Token：`/var/minis/shared/secrets/gh_token`（**App 重装会被清掉，需重新提供**）
- 触发：
```bash
T=$(cat /var/minis/shared/secrets/gh_token)
curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "Authorization: token $T" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/DooRoo666/NanoCode/actions/workflows/ios-tipa.yml/dispatches \
  -d '{"ref":"refactor/runtime-download"}'
```
- 单次约 19 分钟（brew 装 llvm/lld 占大头，xcodebuild ~6 分钟）
- **看日志必须**用 python zipfile 读（`unzip` 会因中文 `→` 文件名失败）：
```python
import zipfile
z=zipfile.ZipFile('logs.zip')
for n in z.namelist():
    if 'Build (unsigned)' in n:
        print('\n'.join(l for l in z.read(n).decode('utf-8','replace').splitlines() if 'error:' in l))
```
- Swift 的 `fork()` 在 iOS 上被 Darwin overlay 标 unavailable → 必须 `dlsym` 取符号（已修，2026-10-29）

## 9. 宿主（iOS）操作限制 —— 踩过的坑

- `host_exec` **没有** `cp / mv / mkdir / rm / du`；能用：`cat`（含 `>` 重定向）、`tarx`（解包）、`ln`、`unzip`/`zip`（CodexApp 目录内）、`git`、`grep`、`file`、`xxd`、`chmod`、`plutil`
  - 建目录：`cat /dev/null > /path/.keep`
  - 移动文件：`ln -s` 或从 git 仓库里拷（CI 产物自带目录结构）
- CodexApp 的 unzip **拒绝** `/private/var/containers` 路径 → 解包到 iSH 路径（`/var/mobile/Documents/alpine-rootfs/data/...`）再进 iSH 处理
- **AMFI 只信任 bundle 内的二进制**：`Documents/` 下的 framework 任何签名都 `code signature invalid`（外部 dylib 一律不信任；TrollStore 的白名单只覆盖主 Bundle）
- 运行时因此必须在 **bundle 内** `Runtimes/frameworks`（CI 用 `if: always()` 从缓存的 `runtime/` 拷入）
- iOS 26 SDK（文件版本）允许 `arm64e` 的 Swift 模块被 `-target arm64` 导入（已实测，这不构成 errSecUnknownFormat）
- iSH 内有 `ldid`（`/usr/local/bin/ldid`），`ldid -S <macho>` 可 ad-hoc 重签

## 10. 进度与待办

| 项 | 状态 |
|---|---|
| 运行时签名/哈希校验 | ✅ 45253 页全部匹配，结构合法 |
| 运行时放 bundle 内加载 | ✅ 已改到 `Runtimes/frameworks`（等新构建验证） |
| 自检崩溃（CFRelease NULL → SIGTRAP） | 🔧 fork 隔离已写，`fork()` 编译错误已修（`ae5b58c`） |
| Swift 编译 → 可执行 | ✅ 单文件 C/Swift 均出 `.o`，C 已链接出 33KB 可执行 |
| `import Foundation` | ❌ 待验证（需先补 swift resource dir） |
| 参数注入 bug（缺 `-c`/`-o`） | ✅ 已修 |
| swift resource dir / CoreCompilerSupportLibs | ⬜ 未下载（128MB+ 分片，公开 release） |
| Info.plist 模板 / 组包 / tipa | ⬜ 未做（原版也不做 actool） |

**下一步（顺序不能乱）**
1. 新构建装好 → 验「不闪退 + 包内 dlopen 成功」（看 `nyxian-diag.txt`）
2. 拉 support libs（`CoreCompilerSupportLibs.tar.gz.part-*`），按 Nyxian 的 `BSROOT/swift` 结构铺好
3. 用**原样参数**（含 `-resource-dir`、`-Xllvm -aarch64-use-tbi`、`-target arm64-...`）重跑 Foundation
4. Foundation 通了 → builder 四阶段（prepare/build/install/package）→ 出 tipa

## 11. 可行性评估（2026-10-29）

| 环节 | 把握 | 依据 |
|---|---|---|
| 单文件 Swift 编译 | 100% | 实测出 `.o` |
| 链接成可执行 | 90% | C 路径已通 |
| Foundation / UIKit | ~85% | 参数已拿到原文；缺件有明确来源 |
| 多文件工程 → 可执行 | 90% | 驱动自己拆 job |
| Info.plist/资源（无 actool） | 95% | 原版也不编译资源 |
| 签名 + tipa | 95% | `tipa_build` 现成 + TrollStore trust cache |
| 不闪退 | 85% | fork 可用性未知，已加回退/超时 |

**综合 ≈ 8 成**。剩余风险：①framework 与 support libs 版本错配（换成配套一套即可）；②iOS 16 拒绝 fork（**概率比 iOS 26 低**，TrollStore 环境下更可能放行；退进程内即稳定性下降）；③自编译 App 的签名校验（iOS 16 + TrollStore 安装可绕过，比 iOS 26 宽松）。

## 12. 时间线

- `2b76274` 首个能装能跑的构建（无 fork 隔离，自检必崩）
- `778f12e` 加 fork 隔离 → **构建失败**：`'fork()' is unavailable`（Swift Darwin overlay 禁用）
- `63828db` 修参数注入（`-c`/`-o`）、加开关文件
- `ae5b58c` fork 改 dlsym + 180s 超时强杀 → 构建中

- 08:40 ae5b58c 构建成功（fork 隔离 + 包内运行时预置 + 参数注入修复）→ 待装包验证
- 08:55 更正设备事实：iPhone 14 Pro / iOS 16.x（非 iOS 26），部署目标 ios16.0；fork 与签名风险相应下调
