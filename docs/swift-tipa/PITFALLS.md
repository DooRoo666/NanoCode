# 踩坑清单（全部为真机实测结论）

按「症状 → 根因 → 解法」组织。遇到问题先从这份表里查。

---

## 1. 装上去闪退 / 黑屏

**根因**：二进制里没有 `UIApplicationMain`。Swift 顶层裸代码（如 `print("hi")`）
编出的是**终端程序**，不是 GUI app。

**验证**：
```sh
llvm-nm -u YourApp.app/YourApp | grep -c UIApplicationMain
# 0 = 一定闪退，1 = 正常
```

**解法**：
- 源码结尾必须调 `UIApplicationMain(...)`，见 `template/main.swift`
- 链接必须带 `-framework UIKit` 和 `-lswiftFoundation`

---

## 2. 链接报 `undefined symbol: _UIApplicationMain`

**根因**：漏了 `-framework UIKit` 或 `-lswiftFoundation`。

**解法**：完整链接参数（缺一不可）：
```sh
-lswiftCore -lswiftFoundation -framework UIKit -framework Foundation
```

---

## 3. `llvm-objdump -f` 报 `Invalid/Unsupported object file format`

**根因**：**误报**。`ldid` 签名会在文件尾追加签名段并修改 load command 布局，
`objdump` 的部分解析路径处理不好。

**验证方式**：改用
```sh
xxd -l 16 YourApp.app/YourApp          # 看魔数
llvm-nm -u YourApp.app/YourApp          # 看符号
llvm-objdump --macho --dylibs-used ...  # 看依赖
llvm-objdump --macho --private-headers  # 看签名段
```
这些都正常就说明文件没问题。

---

## 4. 设备编译看起来「卡住」

**根因**：不是死锁，是真慢。首次编译要解析 SDK 里 **507 个 `.swiftinterface``**，
内存从 199MB 爬到 934MB 后稳定（非泄漏），约 30–40 秒返回。

**判断标准**：看日志有没有 `[s2] job 0 -> 1` 和 `[s2] DONE`。
内存停在某个值不再增长 = 正常工作中。

**加速**：第二次运行有 ModuleCache，会明显变快。

---

## 5. 传 `-parse-as-library` 报 `expressions are not allowed at the top level`

**根因**：源码里有顶层语句（如 `UIApplicationMain(...)` 调用）。
`-parse-as-library` 要求纯声明。

**解法**：**不要传这个参数**。app 模式的 `main.swift` 本来就需要顶层 `UIApplicationMain`。

---

## 6. 链接警告 `version 26.5.0, which is newer than target minimum of 17.0`

**根因**：目标文件来自 SDK 26.5，而 `-platform_version` 写的最低版本是 17.0。

**结论**：**无害**，可忽略。产物能正常安装运行（已验证）。

---

## 7. 宿主进程内编译 SIGSEGV，`far=0x456`，栈在 `CCDriverCreateJobs`

**根因**（四个错误叠加）：
1. 传了 `NULL` allocator（必须用 `kCFAllocatorSystemDefault`）
2. 重复传了 `argv[0]="swiftc"`（CCDriver 内部会自己 prepend）
3. target 三元组格式错误
4. **漏传 `-resource-dir`** ← 最主要原因，Swift 前端找不到 stdlib

**正确参数**：
```
-target arm64-apple-ios26.5
-sdk <SDK路径>
-resource-dir <Shared/swift 路径>
-module-cache-path <ModuleCache 路径>
-module-name main
-emit-object -o <out.o> <src.swift>
```

---

## 8. Swift 编译过程中崩溃在 `objc_retain`

**根因**：block 里捕获了 ObjC 对象。`__copy_helper_block` 会 retain，
而 objc_msgSend 返回的裸指针在此时已失效。

**解法**：block 内部只用 C 缓冲区（如 `snprintf` 到 `static char[]`）。
验证：产物里 `objc_retain` 出现次数必须为 **0**。

---

## 9. 编译启动即崩溃（watchdog 杀掉）

**根因**：在 `UIApplicationMain` 之前同步跑重活，触发启动看门狗。

**解法**：
- 放进 `didFinishLaunching` 之后，再 `dispatch_async` 到后台队列
- 后台冻结问题用 `beginBackgroundTaskWithExpirationHandler:` 申请延时
  （必须在 block **外**用 objc_msgSend 直接调），可延至约 30 秒

---

## 10. 读诊断信息时崩溃

**根因**：`diags` 数组里的元素是 `CCDirector` C 对象（`__NSCFType`），不是 NSString。
直接调 `_getCString:` 必崩。

**解法**：先判断类型再取串：
```c
if (CFGetTypeID(obj) == CFStringGetTypeID()) { ... }
```

---

## 11. `file system sandbox blocked mmap()` / CoreCompiler 加载失败

**根因**：Mach-O 不能从沙盒外路径 `dlopen`。

**铁律**：CoreCompiler.framework 及其依赖必须放在 `.app/Frameworks/` 内。
SDK、`.swift` 源码、resource-dir 是普通数据文件，可以放在沙盒外（如 Documents）。

---

## 12. iSH 与宿主文件不互通

**事实**：
- iSH 里 `/var/mobile/Documents` ≠ 宿主真实 Documents
- 宿主看不到 `/var/minis`
- **宿主 → iSH 单向可用**：在 host_exec 里 `cat <宿主路径> > /private/var/mobile/Library/MinisChat/minis/<会话UUID>/workspace/_name`
- **iSH → 宿主不通**

**解法**：需要跨端传文件时走单向 `cat` 重定向；产物一律放
`/var/minis/attachments/`，用户可直接在 App 里下载。

---

## 13. 签名后装上打不开 / 缺权限

**解法**：`ldid -S<ent.plist>`，ent.plist 需要：
```xml
platform-application   = true
get-task-allow         = true
no-container           = true
```

---

## 快速自检

不确定哪里出错时，先跑：
```sh
sh verify-tipa.sh YourApp.tipa
```
14 项检查会直接指出问题在架构、符号、依赖、签名还是 Info.plist。
