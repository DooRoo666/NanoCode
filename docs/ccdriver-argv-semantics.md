# __CCDriver argv 语义 —— 上游行为说明

> 目的：`cc/` 目录是从 Nyxian（`github.com/emexlab/Nyxian`）拉来的 **CoreCompiler 参考源码**，
> 用于阅读 C API 实现。**它不参与我们的真机构建**（CI 的 CoreCompiler 来自 release
> `runtime-deps` 资产 `CoreCompiler.zip`，是预编译 dylib）。
>
> 所以 `cc/CCDriver.cpp` 上的本地修改**不是"上游修复"**，只是我们读源码时加的注释与
> 一处与上游不一致的本地标注。下面逐条说明。

## 1. 关键结论：传给 driver 的 argv 不能带程序名前缀

`CCDriverCreate` 内部会自己 prepend 程序名：

- clang 模式：`"clang"` + `-fuse-ld=lld`
- swift 模式：`"swiftc"`

见 `cc/CCDriver.cpp` 的 `CCDriverCreate`：

```cpp
if (driverRef->type == kCCDriverTypeSwift) {
    driverRef->argStorage.insert(driverRef->argStorage.begin(), "swiftc");
} else {
    driverRef->argStorage.insert(driverRef->argStorage.begin(), "clang");
    driverRef->argStorage.insert(driverRef->argStorage.begin()+1, "-fuse-ld=lld");
}
```

**宿主侧（Swift）调用时只能传"参数数组"，不能传 `["clang", "-c", ...]`。**
否则 argv 变成 `clang clang -c ...` → 重复程序名 → `llvm::report_bad_alloc_error`
崩溃。这正是 2026-10-29 真机崩溃 `SIGABRT` 的根因
（栈：`report_bad_alloc_error` → `SmallVectorBase<unsigned>::grow_pod` → `CCDriverCreateJobs`）。

> 对应的宿主侧代码：`overlay/android/src/ios/NanoMuse/NanoMuseNyxian.swift`
> （旧版有 "clang" 前缀，已修；新版走 `swiftLink` 参数化路径）。

## 2. `argStorage` / `argPtr` 两个 SmallVector

```cpp
llvm::SmallVector<std::string, 64> argStorage;   // 拥有字符串
llvm::SmallVector<const char *, 64> argPtr;      // 指向 argStorage 的裸指针
```

- `argStorage` 保存 argv 的**所有权**（`std::string`）。
- `argPtr` 保存对应的 `const char*` 视图，供 `CCDriverCreateJobs` 传给
  `llvm::cl::` / `swift::driver::` 使用。
- 生命周期必须严格配对：init 里 placement-new，finalize 里 `std::destroy_at`。
  **上游漏了 `argStorage` 的构造/析构**（只对 `argPtr` 做了 placement-new），
  这是一个真实的 UB —— 本地补丁补齐了两者。

## 3. `_CFRuntimeCreateInstance` 的 size 语义

`cc/CFRuntime.h` 中：

```cpp
void *_CFRuntimeCreateInstance(CFAllocatorRef allocator, CFTypeID type,
                                size_t extraBytes, const void *proto);
```

`extraBytes` 是**在 CFRuntimeBase 之外额外分配的字节数**，不是总大小。

`struct __CCDriver` 本身**已经包含** `CFRuntimeBase` 作为第一个成员，
所以正确写法是：

```cpp
sizeof(struct __CCDriver) - sizeof(CFRuntimeBase)
```

上游写成了 `sizeof(struct __CCDriver) + sizeof(CFRuntimeBase)`，
**多分配了 `sizeof(CFRuntimeBase)` 字节**（对齐后通常 16 字节的越界余量）。
这不会立刻崩，但会让 `argStorage`/`argPtr` 落在分配区之外 ——
配合上面缺失的 placement-new，就是潜在的内存破坏源。

本地补丁已把它改成 `- sizeof(CFRuntimeBase)`，并把 `+ sizeof(CFRuntimeBase)`
标注为 `// 上游疑似笔误`。

## 4. finalize 的对称性

上游 `CCDriverFinalize` 里，swift 分支漏析构了：

- `swiftPrintingDiagnosticConsumer`
- `swiftSourceManager`

两者都在 init 里被 placement-new，finalize 必须 `std::destroy_at`，
否则 SmallVector/裸指针成员泄漏。本地补丁补齐。

## 5. 与我们自己的实现的关系

以上都是 **CoreCompiler（预编译 dylib）内部**的行为，我们改不了 dylib。

但结论对我们有效：

- 宿主侧构造 argv 时不要带程序名前缀（已修）。
- `swift_tipa` 工具若走 `CCDriverCreate` → `CCDriverCreateJobs` →
  `CCJobExecuteJob` 的路径，参数数组同样必须遵守第 1 条。

## 变更记录

- 2026-10-31：初版。整理 `cc/CCDriver.cpp` 本地补丁并归档为参考文档。
