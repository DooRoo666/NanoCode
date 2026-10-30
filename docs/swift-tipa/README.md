# Swift → Tipa 完整链路（iPhone 真机已验证）

> 验证日期：2026-10-30
> 结论：Swift 源码可以在 iPhone 上编译、链接、签名、打包成可运行的 tipa。
> 证据：`UIDemo.app` 在 TrollStore 安装后正常显示「Hello from Swift on iPhone」，无闪退无黑屏。

## 链路总览

```
main.swift
   │  ① 设备内编译（CoreCompiler / NanoCodeHost）
   ▼
stage2_out.o        arm64e MH_OBJECT，57 KB
   │  ② iSH 内链接（ld64.lld）
   ▼
ui_exe              arm64e MH_EXECUTE，51 KB
   │  ③ 放入 .app 结构 + 签名（ldid）
   ▼
UIDemo.app
   │  ④ 打包（zip Payload/）
   ▼
UIDemo.tipa         13 KB → TrollStore 安装 → 运行
```

## 环境前提

| 项目 | 路径 |
|---|---|
| SDK | `/private/var/mobile/Documents/nyxian/iPhoneOS26.5.sdk` |
| Swift resource dir | `/private/var/mobile/Documents/nyxian/Shared/swift` |
| ModuleCache | `/var/mobile/Documents/nyxian/ModuleCache` |
| 链接器 | iSH 内 `ld64.lld` |
| 签名工具 | iSH 内 `ldid` |
| entitlements | `NanoCode/host/ent.plist` |

iSH 侧 SDK 副本：`/tmp/tpk/iPhoneOS26.5.sdk`（解压自 SDK zip）。

## ① 编译（设备内）

由 `NanoCodeHost.app` 在进程内调用 CoreCompiler 完成。源码放在
`/private/var/mobile/Documents/nyxian/hello.swift`，产物到 `/private/var/tmp/stage2_out.o`。

实际使用的参数（`host/stage2.c`）：

```
-target arm64-apple-ios26.5
-sdk /private/var/mobile/Documents/nyxian/iPhoneOS26.5.sdk
-resource-dir /private/var/mobile/Documents/nyxian/Shared/swift
-module-cache-path /var/mobile/Documents/nyxian/ModuleCache
-module-name main
-emit-object -o <out.o> <src.swift>
```

成功标志：

```
[s2] job 0 -> 1
[s2] diagCount=0      ← 0 或仅 deprecated 警告
[s2] DONE
```

## ② 链接（iSH）

```bash
SDK=/tmp/tpk/iPhoneOS26.5.sdk
ld64.lld -arch arm64 -platform_version ios 17.0 26.5 \
  -syslibroot $SDK \
  -o ui_exe stage2_out.o \
  -L$SDK/usr/lib/swift -L$SDK/usr/lib \
  -lswiftCore -lswiftFoundation \
  -framework UIKit -framework Foundation
```

**必须包含 `-lswiftFoundation` 和 `-framework UIKit`。** 缺任何一个都会导致
`UIApplicationMain` 符号缺失 → 黑屏或闪退。

无害警告（可忽略）：

```
warning: stage2_out.o has version 26.5.0, which is newer than target minimum of 17.0
```

## ③ 签名与打包

```bash
mkdir UIDemo.app
cp ui_exe UIDemo.app/UIDemo
chmod +x UIDemo.app/UIDemo
cp Info.plist UIDemo.app/Info.plist

ldid -Sent.plist UIDemo.app/UIDemo

mkdir -p pk && cp -a UIDemo.app pk/
cd pk && zip -r ../UIDemo.tipa Payload/
```

Info.plist 必需字段：

```xml
<key>CFBundleExecutable</key><string>UIDemo</string>
<key>CFBundleIdentifier</key><string>com.nanocode.uidemo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>MinimumOSVersion</key><string>15.0</string>
```

entitlements（`ent.plist`）：

```xml
<key>platform-application</key><true/>
<key>get-task-allow</key><true/>
<key>com.apple.private.security.no-container</key><true/>
```

## 关键约束（踩过的坑）

### 1. 源码必须有 UIApplicationMain

顶层 `print()` 编出来的是**终端程序**，不是 GUI app。iOS 前台 app 必须：

```swift
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv,
                  nil, NSStringFromClass(AppDelegate.self))
```

否则进程打印完就退出 → 闪退；若系统留了空窗口则表现为黑屏。

### 2. 不要传 -parse-as-library

有顶层可执行语句时传它会报：

```
error: expressions are not allowed at the top level
```

### 3. block 不能捕获 ObjC 对象

`_Block_copy` 会 `objc_retain` 捕获的对象，裸指针（`objc_msgSend` 返回值）此时崩溃。
解法：block 内只用 C 缓冲区。

### 4. 启动 watchdog

编译必须放在 `didFinishLaunching` 里 `dispatch_async` 到后台队列，不能在此之前同步跑。

### 5. 后台冻结

`beginBackgroundTaskWithExpirationHandler:` 必须在 block **外**申请，可延长约 30 秒。

### 6. 诊断对象类型

`diags` 元素是 `__NSCFType`（CCDirector C 对象）不是 NSString。
必须先 `CFGetTypeID() == CFStringGetTypeID()` 再取串，否则 `_getCString:` 崩溃。

### 7. objdump 误报

`llvm-objdump -f` 对 ldid 签名后的文件报 `Invalid/Unsupported object file format`，
因签名段改变布局。属误报，用 `llvm-nm` / `--dylibs-used` / `--private-headers` 验证。

## 验证清单

```bash
# 架构与类型
xxd -l 16 app_exe
# cffaedfe = MH_MAGIC_64，0c000001 = arm64e，02000000 = MH_EXECUTE

# UI 入口存在
llvm-nm -u app_exe | grep -c UIApplicationMain
# 必须 = 1

# 依赖库
llvm-objdump --macho --dylibs-used app_exe
# 应含 UIKit.framework、libswiftCore.dylib、libswiftFoundation.dylib

# 签名段
llvm-objdump --macho --private-headers app_exe | grep -c LC_CODE_SIGNATURE
# 必须 = 1
```

## 性能实测

| 源码 | 耗时 | 峰值内存 |
|---|---|---|
| `import Foundation` + print | ~40 s | 934 MB |
| UIKit 完整 UI（首次） | ~30 s | 374 MB |

首次编译主要是解析 SDK 里 507 个 `.swiftinterface`。ModuleCache 建好后后续更快。

## 跨环境文件传递

iSH 看不到宿主的 `/private/var/tmp`。

**宿主 → iSH（唯一可用方向）：**

```bash
# host_exec 中执行
H=/private/var/containers/Bundle/Application/<UUID>/Minis.app/Helpers
S=/private/var/mobile/Library/MinisChat/minis/<会话UUID>/workspace/_s2o.o
$H/cat /private/var/tmp/stage2_out.o > $S
```

iSH 侧即出现在 `/var/minis/workspace/_s2o.o`。

**iSH → 宿主：不通。** 但 iSH 写到 `/var/minis/attachments/*.tipa` 用户可直接下载。

## 待办：进程内闭环

当前是两段式（设备编译 + iSH 链接打包）。要做到「手机上点一下直接出 tipa」：

1. 检查 CoreCompiler 是否导出链接器符号（如 `_CCLinkerJobExecute`）
2. 若无，用 `posix_spawn` 调 `ld64.lld` 做外部链接
3. 把 ldid 签名逻辑改为进程内实现（或复用现有工具）
