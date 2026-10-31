# 安装与构建指南（含易错点）

> 目标：**下载完就能直接编译**，不需要任何手工 chmod / 拷贝 / 改路径。
> 本文记录所有已验证的结论与踩过的坑，出错时先对照「排错速查表」。

---

## 一、现在能不能「下载完直接编译」？

**能，已验证。** 全新的机器上：

```sh
sh engine/tc.sh install-all     # 约 1~2 分钟，自动下载 ld64 / ldid / sdk
python3 engine/build.py 你的源码.m --name MyApp --bundle-id com.you.myapp
```

中间**不需要**：
- ❌ 手动 `chmod +x`
- ❌ 手动把二进制搬到 `/tmp`
- ❌ 手动改任何路径

原因见第三节（noexec 桥接）。实测：清空 `tools/` 与缓存 → `install-all`（1 分 26 秒）→ 直接构建 → 产出合法 `.tipa`。

---

## 二、分工：什么在 iSH 跑，什么必须在宿主跑

这是最容易搞错的一点。**不是「iSH 不行」，而是分两类**：

| 工具 | 格式 | 在哪跑 | 说明 |
|---|---|---|---|
| `ld64.lld` | musl aarch64 **ELF** | ✅ iSH 内 | iSH 原生兼容，链接 .o → 可执行 |
| `ldid` | musl aarch64 **ELF** | ✅ iSH 内 | Mach-O 签名，TrollStore 必需 |
| SDK | 头文件 + tbd | ✅ iSH 内 | 供 clang 编译时读 |
| `CoreCompiler`（Swift 前端） | **Mach-O**（iOS） | ❌ 只能宿主/dyld | iSH 无法加载，只能设备端跑 |

**结论：**

| 语言 | 流程 |
|---|---|
| C / ObjC / ObjC++ | iSH 内**一条命令到 `.tipa`** |
| Swift | **宿主**用 CoreCompiler 编出 `.o` → 把 `.o` 丢给 iSH 链接签名 |

### Swift 的两段式构建

```sh
# ① 宿主（iOS 设备端，能加载 Mach-O 的环境）
CoreCompiler -target arm64e-apple-ios15.0 \
    -sdk <SDK路径> -c App.swift -o App.o

# ② iSH 内：.o 直通分支，链接 + 校验 + 签名 + 打包
python3 engine/build.py App.o --name MyApp --bundle-id com.you.myapp
```

`.o` 输入走 `build.py` 的**直通分支**，跳过编译，直接链接→签名→打包。

---

## 三、必须知道的机制：noexec 桥接

### 现象
在 iSH 里直接跑工具，报：
```
/bin/sh: ./ld64.lld: Permission denied
```

### 原因
工作区 `/var/minis` 在 iSH 的 fakefs 下**不可执行**（类似 noexec 挂载）。而且：
- `os.access(path, os.X_OK)` 会**误报为 True**（chmod 位确实能置上）
- `/proc/mounts` 里**查不到** noexec 标志（整机只有一个 fake 挂载）

→ 两种常规静态探测全部失效，**只有真的 spawn 一次才知道能不能跑**。

### 解决（已内置，无需你操作）
`engine/build.py` 的 `_runnable()`：
1. 实际试执行一次（`--version` / `-h`）
2. 失败 → 复制到 `/tmp/nanocode-bin/<size.mtime>/原名` 再执行
3. 带 size+mtime 指纹缓存，同一文件不重复拷贝；进程内也有缓存

### 关键细节：**文件名不能改**
lld 是多路复用驱动，靠 `argv[0]` 判断自己该当 `ld64.lld` / `ld.lld` / `lld-link`。
如果缓存时改名成 `ld64.lld.123456`，会报：

```
lld is a generic driver.
Invoke ld.lld (Unix), ld64.lld (macOS), lld-link ... instead
```

所以缓存**用子目录做指纹隔离、保留原始文件名**：
`/tmp/nanocode-bin/67648.1793441424/ld64.lld` ✅

---

## 四、编译参数里的坑（已在 `compile_source` 修好）

编译 ObjC 时，缺少下面任一路径都会失败：

| 缺什么 | 报错 |
|---|---|
| `-isysroot <SDK>` | 找不到 UIKit/Foundation 头文件 |
| `-F .../PrivateFrameworks` | 私有头解析失败 |
| `-F .../SubFrameworks` | `fatal error: 'UIUtilities/UIDefines.h' file not found` |

`UIUtilities.framework` 在 **`System/Library/SubFrameworks`**，不在 PrivateFrameworks，所以三个 `-F` 都要加。当前实现：

```
-target arm64e-apple-ios15.0
-isysroot <SDK>
-F <SDK>/System/Library/{PrivateFrameworks,SubFrameworks,Frameworks}
-fembed-bitcode -fobjc-arc -O2
```

---

## 五、工具注册表：`saveAs` 的位置（踩过）

`saveAs` 必须写在 **`install` 区块内部**，不是工具名那一层：

```json
{
  "tools": {
    "ldid": {
      "install": { "type": "file", "url": "ldid", "saveAs": "bin/ldid" },  // ✅ 对
      "probe":   { "file": "bin/ldid" }
    }
  }
}
```

```json
{
  "tools": {
    "ldid": {
      "saveAs": "bin/ldid",                                                // ❌ 错，不会生效
      "install": { ... }
    }
  }
}
```

**铁律：`install.saveAs` 必须与 `probe.file` 完全一致**，否则「装上了但检测显示未安装」。默认 `saveAs` = 工具名。

当前四项的对应关系：

| 工具 | saveAs | probe.file |
|---|---|---|
| ld64 | `bin/ld64.lld` | `bin/ld64.lld` |
| ldid | `bin/ldid` | `bin/ldid` |
| sdk | `iPhoneOS26.5.sdk` | `iPhoneOS26.5.sdk/SDKSettings.json` |
| corecompiler | `CoreCompiler.framework` | `CoreCompiler.framework/CoreCompiler` |

---

## 六、排错速查表

| 症状 | 原因 | 处理 |
|---|---|---|
| `Permission denied` 跑工具 | noexec 挂载 | 已由 `_runnable()` 自动桥接；若仍报错检查 `/tmp` 是否可写 |
| `lld is a generic driver` | 镜像时改了文件名 | 确认缓存保留原名（第三节） |
| 装了但 `--check` 显示 ✗ | `saveAs` 与 `probe.file` 不一致 | 对照第五节表修正 |
| `UIUtilities/UIDefines.h not found` | 缺 `-F SubFrameworks` | 见第四节 |
| `缺少 UIApplicationMain` | 源码是终端程序 | 加 UIKit 入口，或本意就是命令行则忽略 |
| `llvm-objdump -f` 报 Invalid | 对 ldid 签名文件误报 | 用 `llvm-nm` 验证，**不是真错** |
| `install-all` 跳过 corecompiler | Swift 前端 iSH 跑不了（设计如此） | 按第二节走宿主编译 |

---

## 七、完整验证清单

下载/改动后，按顺序跑：

```sh
cd docs/toolchain

# 1. 工具就绪（corecompiler 允许 ✗，它只在宿主用）
sh engine/tc.sh status

# 2. 端到端跑一个最小 ObjC
python3 engine/build.py /tmp/u.m --name Demo --bundle-id com.test.demo

# 3. 产物校验
unzip -l out/Demo.tipa                 # 应有 Payload/Demo.app/Demo
file Payload/Demo.app/Demo             # Mach-O 64-bit arm64
ldid -e Payload/Demo.app/Demo; echo $? # 签名段有效则 rc=0
```

三步全绿即表示「下载即编译」链路完好。
