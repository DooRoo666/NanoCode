# 已验证能力清单（真机跑过的，不是理论）

> 本文档是「做到了什么」的唯一事实来源。
> 每一条都必须有**真机安装运行**或**完整命令复现**作为证据。
> 只记录已验证的事实；理论/待验证的内容放 `docs/plan-*.md`，不要混进来。

最后更新：2026-10-31

---

## 一句话结论

**Swift 和 C / ObjC / ObjC++ 都能编译并打包成可安装的 .tipa，两条路线都已真机验证通过。**

- Swift → tipa：设备端 CoreCompiler 出 `.o`，iSH 内 ld64.lld 链接 + ldid 签名 + zip 打包
- C/ObjC/ObjC++ → tipa：iSH 内 clang + ld64.lld + ldid 一条龙，无需设备端参与

---

## 1. Swift 路线 —— 真机验证 ✅

### 产物
- `UIDemo.tipa`（13 KB），已用 TrollStore 装上 iPhone
- 界面显示 **"Hello from Swift on iPhone"**，白底居中 UILabel
- 无闪退、无黑屏

### 源码形态（`docs/swift-tipa/template/main.swift`）
```swift
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication,
        didFinishLaunchingWithOptions opts: ...) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        let label = UILabel(frame: CGRect(x:0, y:300, width: w.frame.width, height: 40))
        label.text = "Hello from Swift on iPhone"
        label.textAlignment = .center
        w.addSubview(label); w.rootViewController = UIViewController()
        w.makeKeyAndVisible()
        self.window = w
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
    NSStringFromClass(AppDelegate.self))
```

### 编译产物数据
| 版本 | .o 大小 |
|---|---|
| `print` 终端版 | 4 168 B |
| UIKit 界面版 | 57 168 B |

设备端编译：`[s2] job 0 -> 1`，`diagCount=2`（仅 deprecated 警告，无错误）。
内存占用 374 MB，耗时约 30 秒。

### 链接命令（实测可用）
```sh
SDK=/path/to/iPhoneOS26.5.sdk
ld64.lld -arch arm64e -platform_version ios 17.0 26.5 \
  -syslibroot $SDK -o ui_exe _ui.o \
  -L$SDK/usr/lib/swift -L$SDK/usr/lib \
  -lswiftCore -lswiftFoundation \
  -framework UIKit -framework Foundation
```

**`-lswiftFoundation` 和 `-framework UIKit` 必须加**，否则 `UIApplicationMain` 符号缺失 → 黑屏/闪退。

### 验证方法
```sh
llvm-nm -u ui_exe | grep -c UIApplicationMain   # 必须 = 1
```
依赖确认：libswiftCore、libswiftFoundation、UIKit(9126.5.5)、Foundation、libobjc。

---

## 2. C / ObjC / ObjC++ 路线 —— 全链路打通 ✅

### 一键脚本
`/var/minis/shared/nanocode-c-app/build.sh <源码.c> <AppName>`
示例源码：`/var/minis/shared/nanocode-c-app/app.c`
产物：`/var/minis/workspace/CApp.tipa`（5 290 B）+ `CApp.app`（66-68 KB arm64e）

### 混编实测矩阵
| 输入 | 结果 |
|---|---|
| 纯 C `.c` | ✅ 536 B `.o` |
| ObjC `.m` | ✅ 6 320 B `.o` |
| ObjC++ `.mm` | ✅ 7 856 B `.o` |
| ObjC `.o` 单独链接 | ✅ 67 968 B |
| Swift `.o` + ObjC `.o` | ✅ 101 832 B |
| **Swift + ObjC + ObjC++ 三语言** | ✅ 112 080 B arm64e MH_EXECUTE |

符号验证：`-[HelperVC greeting]`、`_OBJC_CLASS_$_HelperVC`、`cppCompute` 均在最终产物中。

### 手法：纯 C + ObjC runtime C API（源码零 ObjC 语法）
```c
objc_allocateClassPair(...)          // 运行时造 delegate 类
class_addMethod(...)                 // 动态挂方法
objc_msgSend(...)                    // 派发所有 UIKit 调用
UIApplicationMain(0, NULL, cls, cls) // 启动
```

---

## 3. 编译命令（两个语言共用同一套工具）

```sh
SDK=/var/minis/shared/nanocode-toolchain/tools/iPhoneOS26.5.sdk

# C / ObjC / ObjC++
clang -target arm64e-apple-ios17.0 -isysroot "$SDK" \
  -F "$SDK/System/Library/Frameworks" \
  -F "$SDK/System/Library/SubFrameworks" \
  -fno-objc-arc -arch arm64e -x objective-c -c host.c -o host.o

ld64.lld -arch arm64e -platform_version ios 17.0 26.5 -syslibroot "$SDK" \
  -L"$SDK/usr/lib" -L"$SDK/usr/lib/swift" -o NanoHost host.o \
  -framework UIKit -framework Foundation -framework CoreFoundation \
  -lobjc -lc++abi -lSystem
```

### 三个必须记住的参数
1. **`-F <sdk>/System/Library/SubFrameworks` 必加**
   UIKit 头文件 include 同级 SubFrameworks（UIUtilities）。只加 Frameworks 会报
   `module includes header from ... SubFrameworks` → 任何 `#import <UIKit/UIKit.h>` 都挂。
   SDK 里 `Frameworks/`（279 个）和 `SubFrameworks/` 是**两个不同目录**。
2. **链接必须带 `-lc++abi` 和 `-lSystem`**
   否则 ObjC++ 的 `__Unwind_Resume`、`_memcpy` 解析不了。
3. **混编时只有一个 `.o` 能带 `main`**
   Swift + ObjC 都定义 `main` 会 `duplicate symbol: _main`。
   正确形态：Swift 侧提供 `UIApplicationMain` 入口，ObjC 侧只导出类/函数。

### 踩坑记录（真实踩到，不是抄的）
- `-x c` 编译含 `#import <UIKit/UIKit.h>` 的文件会挂 → 必须 `-x objective-c`
- `-fobjc-arc` 会因 CFString/UIColor 桥接报错 → 纯 C 手管内存用 `-fno-objc-arc`
- arm64 上 `objc_msgSend_stret` 标记 unavailable → struct 返回值（如 `CGRect bounds`）也走 `objc_msgSend`
- ObjC runtime 的 SEL 必须 `sel_registerName("...")`，不能写字面量字符串
- 所有传 CGRect/CGPoint 等 struct 的 `objc_msgSend` 必须用变量，内联 `(CGRect){{0,0},{100,100}}` 会报 "couldn't apply complete type to ABI"
- `-x objective-c++` 与只给 `-stdlib=libc++` 产物完全一致（clang 靠扩展名已识别），显式指定更保险
- Swift `.o` 编译版本 26.5.0 > target minimum 17.0 出 warning，链接用 `-platform_version ios 26.5 26.5` 可消除

---

## 4. 签名与打包

### 签名
```sh
ldid -S ent.plist Payload/X.app/X
```
entitlements 需要 `platform-application` + `get-task-allow`。

**Linux 版 ldid 的陷阱**：遇到不认识的 Mach-O 会打印
`ldid: Unknown header magic` 但**仍然返回 0** → 只看退出码等于没校验。
必须在签名后回读二进制确认 entitlements 真写进去了
（`docs/toolchain/engine/build.py` 的 `read_entitlement_keys()` 就是干这个的）。

### 打包 —— `tipa_build` 有嵌套 bug
`tipa_build` 产出结构是 `Payload/Payload/X.app/X`（多一层 Payload），
TrollStore 装报**错误 301**。

**必须用 iSH 侧 zip 重打**：
```sh
mkdir -p Payload && cp -r X.app Payload/ && zip -qr out.tipa Payload
unzip -l out.tipa | head -3   # 必须看到 Payload/X.app/X
```
不要用 `-0`（不压缩）。186 MB 的 CoreCompiler 默认压缩能从 200 MB → 62 MB。

### 验证
`llvm-objdump -f` 对 ldid 签名后文件报 Invalid 属**误报**，用 `llvm-nm` / `--private-headers` 验证。
`docs/swift-tipa/scripts/verify-tipa.sh` 提供 14 项完整性自检，实测全通过。

---

## 5. 不可违反的硬约束

1. **源码必须有 `UIApplicationMain`**
   否则是终端程序 → 黑屏/闪退。这是最高频失败原因。
2. **Swift 源码 → `.o` 必须在设备端做**
   iSH 里 `fork` 被 PAC 阻断（SIGBUS，forktest-arm64 和 forktest-arm64e 都是 signal 10），
   而 CoreCompiler 的 Swift 前端要 `posix_spawn` swift-frontend 子进程。
   C 不需要 fork，所以 iSH 内可全自动一键出 tipa。
3. **设备是 iPhone15,2 = iPhone 14 Pro，A16 → arm64e**
   cputype `0x0100000c`。**不是 arm64**。iOS 26.5。
   arm64e 向下兼容 arm64，编 arm64e 可直接装。
4. **SDK 必须用完整版**
   残包（framework 目录空、无 UIKit 模块）会让 `import UIKit` 直接失败。
   完整版 = 279 framework / 11 526 文件 / 含 UIKit+Foundation+Swift 模块与 stdlib 153 项。

---

## 6. 待验证（明确未做，不要写进"已验证"）

- CoreCompiler 内置链接器（`CCLinkerJobExecute`）在设备端进程内直接链接
  —— 符号已确认导出，源码路径 `Frameworks/CoreCompiler/Tools/Linker/CCLinker.h`，
  但**尚未跑通**。若成功可彻底摆脱「设备编译 + iSH 链接」两段式，也无需下载 ld64.lld。
  详见 `docs/swift-tipa/LINKER_INSIDE.md`、`docs/swift-tipa/SINGLE_PROCESS.md`。
- `NanoHost.tipa` 装上设备后，dlopen 设备上那份 CoreCompiler 能否成功、
  dlsym 4 个符号是否齐、Swift 编译能否跑出 `.o`。
- C/ObjC 支持并进 `docs/toolchain/engine/build.py`（目前 C 走独立脚本
  `nanocode-c-app/build.sh`，build.py 只认 `.o` / `.swift`）。

---

## 7. 相关文档索引

| 文档 | 内容 |
|---|---|
| `device-and-swift-build-status.md` | 设备信息 + Swift 编译链路定论（394 行） |
| `nyxian-embedding.md` | CoreCompiler C API 与调用链 |
| `ccdriver-argv-semantics.md` | CCDriverCreate 的 argv 重复陷阱 |
| `swift-tipa/PITFALLS.md` | 13 条踩坑清单（症状→根因→解法） |
| `swift-tipa/README.md` | 六阶段流程 + 实测数据 |
| `swift-tipa/LINKER_INSIDE.md` | CoreCompiler 内置链接器证据链 |
| `swift-tipa/SINGLE_PROCESS.md` | 进程内单跑设计 |
| `why-nyxian-works.md` | Nyxian 为什么能跑 |
| `decision-2026-10-29.md` | 放弃本机 Swift 编译的决策依据 |
