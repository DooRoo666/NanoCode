# Nyxian 开源仓库 → 我们能复刻的编译路径

## 仓库事实
- 开源：**是**。https://github.com/emexlab/Nyxian 公开可读（本次用 token 调 API 抓取源码）
- 子模块：`libroot`、`TrollStore`、**`LLVM-On-iOS`**（emexlab/LLVM-On-iOS）
- `Frameworks/CoreCompiler/Tools/` 有完整 `CCDriver.cpp` / `CCCompiler.cpp` / `CCSwiftCompiler.cpp`
- `Frameworks/CoreCompiler/Tools/Compiler/CCSwiftCompiler.cpp` 7.3KB

## 它确实是在**进程内**编 Swift（不 fork）
`CCSwiftCompiler.cpp` 直接 include 了 Swift 的 C++ 前端头文件并调用：
```cpp
#include <swift/Frontend/PrintingDiagnosticConsumer.h>
// 构造 swift::CompilerInvocation，跑前端
void parsedArgs(swift::CompilerInvocation &invocation) override
```
即：**把 swift-frontend 的 C++ 源码编进了 CoreCompiler.dylib**，App 里 `dlopen` 这个 dylib 然后调 C API。没有子进程 → 不需要 fork → 不需要 dyld 根。

## 关键：这个 dylib 是第三方能"构建"出来的
- 源码在 `LLVM-On-iOS` 子模块：Swift 的 `libswiftFrontend` + clang，被编成 iOS dylib
- `Frameworks/CoreCompiler` 只是**包了一层 C API**（CCDriver/CCJob/CCCompiler/CCSwiftCompiler）
- 我们手上的 `CoreCompiler.framework`（186MB，filetype 6 MH_DYLIB）就是这个产物的二进制版
- 二进制里确实有 `CCJob`(24次)、`CCDriver`(20次)、`CCJobType`(5次) 等 API 字符串 → C API 名字没完全 strip

## 复刻可行性（对我们）
方案 A（**可行，但重**）：用 `emexlab/LLVM-On-iOS` 自己编一套 iOS 版 Swift 前端 dylib。
 - 需要：macOS + Xcode + 完整 LLVM/Swift 源码树（几十 GB）+ 数小时构建
 - 本机 iSH 做不到（没有 macOS 工具链），只能云端 macOS 跑
方案 B（**快，本地**）：Nyxian 已经把这个 dylib 生成好放在 `Documents/nyxian/CoreCompiler.framework`。
 - 我们需要的只是：**一个宿主 App，dlopen 它，然后按 CCDriver.h 调 C API**
 - 但缺 `swiftmodule`（设备上 Shared/swift/iphoneos/arm64 只有 .a）→ 编译 `import Foundation` 的 Swift 仍会失败
 - 需要从 Nyxian.app 的 `Documents/nyxian/Shared` 或 CoreCompilerSupportLibs 分片包补上 arm64 接口
方案 C（**最省力**）：直接让用户装 Nyxian 用它编；或走 GitHub Actions macOS 编 Swift 再回来打 tipa。

## 结论
Nyxian 能做的事第三方**原理上完全可以复刻**，因为它把一切放在一个 dylib 里 + 一个 C API 头。
难点不在"能不能"，而在：①带 Swift 前端的大 dylib 二进制我们已经有了；②真正缺的是 arm64 的 `.swiftmodule` 资源；
③写宿主 App 只需要 ~200 行 Objective-C/C，调用 CCInitialize → CCJob 生成 → CCDriver run。
