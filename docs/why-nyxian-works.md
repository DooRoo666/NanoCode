# 为什么 Nyxian 能编 Swift，我们不能（2026-10-29 12:40）

> 用户质问「Nyxian 都能用，为什么你不行」。本文把 CoreCompiler 二进制扒了一遍，给出实证答案。

## 1. CoreCompiler 其实不是一个可执行文件

`/private/var/mobile/Documents/nyxian/CoreCompiler.framework/CoreCompiler`：

| 字段 | 值 | 含义 |
|---|---|---|
| filetype | 6 | **MH_DYLIB**（动态库，不是 MH_EXECUTE） |
| cputype | 0x0100000c | arm64e |
| platform | 2 / minos 16.0 / sdk 26.0 | iOS 16+ 真机 |
| 大小 | 186,805,472 B | ~178 MB |
| LC_LOAD_DYLIB | 19 个 | libswiftCore.dylib、libswift_Concurrency.dylib、Foundation 等 |
| **导入符号数** | **0**（dysymtab 的 lazy+nonglazy import 范围都是 0） | **完全自包含**，Swift 运行时静态链进去了 |

结论：这个 `CoreCompiler` 不可能是「从终端敲一个命令就跑」的编译器，它**只能被某个 App 进程 dlopen 进内存后调用内部函数**。

## 2. Nyxian 到底怎么用它的

- Nyxian.app 的 App 进程 `dlopen` 这个 framework，然后**在自己的进程里直接调用** Swift driver/前端入口函数。
- 这避开了我们踩到的所有坑：根本不创建子进程，不 fork，不走 dyld 二次加载。
- 所以它「能编 Swift」不是因为它有魔法，而是因为：
  1. 它在 App 里跑（有 dyld 根、有 mmap 可执行内存，TrollStore 还替它开了 JIT）；
  2. 编译器本体是 **dylib 形式、零外部导入**，静态 Swift 运行时，直接进程内调用；
  3. 它的前端入口是 C++ 导出函数（二进制里 `swift::` 出现 50 次），不是外部可执行。

## 3. 为什么我们不能「照抄」这条路

即便把 CoreCompiler.framework 原样拷进一个自己的 App：

1. **入口符号拿不到**：字符串里 `swift_frontend_main` / `swift_driver_main` / `SwiftFrontendMain` 全为 0 处（已 strip），只剩 demangle 用的 `swift::`。没有头/签名，调用就是盲猜 ABI，崩溃概率 99%。
2. **Swift 模块缺失**：`Shared/swift/iphoneos/{arm64,arm64e}` 里只有 `libswiftCompatibility*.a`，**一个 `.swiftmodule` 都没有**；SDK 里 `.swiftinterface` 只有 arm64e 一份且是二进制（0 处 `swift-module-flags`），swift-frontend 把它当接口读会直接报错。
3. **fork 无解**：本机 `fork()` 一律 SIGBUS（forktest arm64/arm64e 都是 signal 10）。编译器的 driver 正常要 exec swift-frontend；只有**在 dylib 形态内联调用**才绕得过去，而这条路又被第 1 条堵死。

## 4. 如果要真的复制 Nyxian 的能力，需要什么

- CoreCompiler.framework 的**头文件 / 导出符号表**（Nyxian 作者有源码，我们没有）；
- 完整的 `Shared/swift/iphoneos/arm64/*.swiftmodule`（来自 CoreCompilerSupportLibs 分片包，128MB+，当前拿不到）；
- 自己的 App 有 JIT 权限（TrollStore 上需 `platform-application` + `get-task-allow`）。

## 5. 结论与路线

- **本机 Swift 编译：目前无解**（不是「我们懒」，是缺头和缺 arm64 模块）。
- **本机 C 编译：已跑通**：`/var/minis/workspace/NanoCode/capp/build.sh hello.c` → `out/hello.tipa`（arm64e Mach-O + ldid 签名，结构已校验）。
- **要 Swift 产物**：三条可行路
  A. 云端 macOS（GitHub Actions macos-15）出 .app，下载回本地用 `tipa_build` 打成 tipa（推荐，稳）
  B. 找到 Nyxian 的 CoreCompiler 头文件/源码（github: NyxianProject），自己写宿主桥接
  C. 反向工程 dyld 恢复入口（工作量极大，不建议）
