# NanoCode — 在 nanoMuse 里加入 Codex

在 **nanoMuse 自己的 iOS App**（`Minis.xcodeproj`，533 个 Swift 文件，内嵌 iSH）上加一个 Codex 引擎，
由 GitHub Actions 在 macOS runner 上构建，产出 TrollStore 可装的 `NanoCode.tipa`。

这里只有覆盖层，不复制上游工程：CI 现拉 `nano-muse/nanoMuse`（含 iSH/proot 子模块）再打补丁。
好处是仓库小、上游可换版本、我们改了什么一眼可见。

## 结构

```
NanoCode/
├── overlay/android/src/ios/NanoMuse/
│   └── NanoMuseCodexEngine.swift    # Codex app-server 客户端（posix_spawn + JSON-RPC）
├── Tools/
│   ├── apply_overlay.py             # 把覆盖文件接进工程（同步文件夹自动跳过）
│   ├── make_tipa.sh                 # 三档 ldid 签名 + 打包 tipa
│   └── entitlements-app.plist       # TrollStore 11 条权限
└── .github/workflows/ios-tipa.yml   # 拉上游 → 原生依赖 → xcodebuild → 签名 → artifact
```

## 为什么可以只放一个 .swift

`android/src/ios/NanoMuse/` 在工程里是 **Xcode 16 同步文件夹**（`PBXFileSystemSynchronizedRootGroup`），
目录里的文件自动进 target，不需要改 278 KB 的 `project.pbxproj`。
`apply_overlay.py` 会识别这一点并在非同步工程里回退到显式打补丁（幂等 + 失败即退出）。

## 构建

首次跑 `Actions → iOS · TIPA (TrollStore) → Run workflow`（或直接 push 到 main）。

- runner：`macos-26`，超时 180 分钟
- 首次要编 iSH 内核 / FFmpeg / LAME / Alpine rootfs / rclone，**约 1–2 小时**；之后命中缓存约 15 分钟
- 产物：artifact **`NanoCode-tipa`** → 下载 → TrollStore 安装

也可以手动指定上游版本：Run workflow 时填 `upstream_ref`（tag / branch / commit）。

## 签名（TrollStore）

`Tools/make_tipa.sh` 按三档顺序签，顺序反了会失败：

1. 所有嵌套 Mach-O（框架、内嵌可执行）先 ad-hoc `ldid -S`；
2. 各 `.appex`（ShareExtension / FileProvider / AgentWidget）用 `entitlements-app.plist` 签；
3. 主 App 最后签 —— 包含 `platform-application`、`no-sandbox`、`no-container` 等 11 条。

## Codex 引擎的现状（诚实说明）

`NanoMuseCodexEngine.swift` 实现了与桌面端 Python 客户端一致的协议：
`initialize → thread/start → turn/start`、通知流、以及 server→client 审批请求（**默认拒绝**）。

它**还没接到 App 的 UI/Agent 循环上**——下一步要在 `NanoMuseAgentPage` 附近注册一个工具，
把 `runTurn` 接进对话流。这一步需要能看到 App 运行效果（真机或模拟器），不是盲写能保证的。

还有一个必须知道的约束：**iSH 是 x86 模拟，跑不了 arm64 的 codex 二进制**。
所以 TrollStore 版可以原生 spawn（就是本引擎的做法，权限足够）；
App Store/TestFlight 版只能走远端配对执行。

## nsh（forkless shell）能做什么

iOS 的 SDK 把 `fork()` 标为 unavailable，而 bash 的管道 / 重定向 / 子 shell /
命令替换 / 后台作业**全部**依赖 fork，所以 `bash.real` 一遇到这些语法就 SIGBUS(10)。
`Tools/forkless-sh/nsh.c` 用 `posix_spawn` 重实现了同样的语义：

| 语法 | 实现方式 | 状态 |
|---|---|---|
| 单命令 / 通配符 / `cd` / `export` | `posix_spawnp` + `glob()` + `chdir` | ✅ |
| 管道 `a \| b \| c` | `pipe()` + 每段一次 spawn | ✅ |
| 重定向 `> >> < 2> 2>&1` | `posix_spawn_file_actions_adddup2` | ✅ |
| 序列 / 条件 `;` `&&` `\|\|` | 顶层切分后顺序 spawn | ✅ |
| 变量 `$VAR` `${VAR}` `$?` `$$` | 自身变量表 + `getenv` | ✅ |
| 赋值 `VAR=value`（含前置） | 内存变量表，随 spawn 传给子进程 | ✅ |
| 命令替换 `$( ... )` | `pipe()` + spawn 自身 `-c`，读回 stdout | ✅ |
| 参数 `-c` / `-lc` / `-ec` / `-i` | 按字符解析标志位 | ✅ |
| `test` / `[`（`-e -f -d -x -r -w -s -z -n` / `=` `!=` / `-eq -ne -lt -gt -le -ge`） | 内建 | ✅ |
| 行首 `!` 取反 | 顶层切分后对结果取反 | ✅ |
| `for` / `while` / `until` / `if` / `case` / `function` | 整段委托给同目录 `bash.real -c`（控制流只用内建，不 fork） | ✅ |
| `( )` 子 shell / `&` 后台 | —— | ❌ 仍不支持 |

> 构建时如果 nsh 编译成功，`Helpers/{sh,bash,bash-codex}` 会自动改指向 nsh
> （MT 原版指向 bash.real，一遇管道就 SIGBUS）；编译失败则保持原链接。

> **注意**：nsh 必须用 `entitlements-app.plist` 重签才会带上
> `no-sandbox` / `disable-library-validation`；`make_tipa.sh` 里对
> `Helpers/nsh` 有专门分支，别把它和 MT 原版三件（bash.real / codex-sign /
> ca-filetool）混在"有签名就保留"的逻辑里。

## TheosRuntime 的两个前提

1. **必须重签**：`clang-16` / `ld64` / `ldid` / `dpkg-deb` 依赖 Procursus 的
   `libiosexec` / `liblzma` 等第三方 dylib，不重签就会被 library validation 拦成
   `Library not loaded … sandbox blocked mmap()`。入口在设置页
   「准备 TheosRuntime（定位 + 重签 dylib 权限）」。
2. **必须进 PATH**：`NanoMuseCodex` 启动 codex 时会把 runtime 的 `usr/bin` 与
   `usr/lib` 接到 `PATH` / `DYLD_*`，否则 codex 里敲 `clang` 永远 127。

### 运行时只属于自己（不再借用别的 App）

`NanoMuseTheosRuntime` 只认**自己容器内**的三处：

```
Bundle.app/TheosRuntime              # 若将来直接打进 tipa
Documents/TheosRuntime               # Files App 可直接投放
<Library>/TheosRuntime               # 运行时安装器的正式位置
```

不再扫描 `Application Support/CodexApp/...` 或 `/var/jb` —— 那是别的 App / 系统越狱目录，
写入等于改别人的文件，对方升级或清理就会失效。

设置页「准备 TheosRuntime（安装 → 重签 → 自检）」是**一键全流程**：

1. 读 `runtime-manifest.json` 里 `runtimes.theos.archive_parts`（5 个分片，约 224 MB），
   直连失败自动走 `gh-proxy.org` / `ghproxy.net`，逐片写入并拼接；
2. 用随包的 `ca-filetool`（argv[0] 分派成 `tar`）解包到 `<Library>/TheosRuntime`；
3. 增量重签（`.nanomuse-resign.json`）；
4. `smokeTest` 逐个跑 `clang-16 / make / ldid / dpkg-deb --version`，直接给 OK / FAIL。

### 重签是增量 + 自动的

- 首次启动 codex（或 entitlements 变更后）会在**后台**把 runtime 里 373 个 Mach-O
  重签一遍；结果写进 `<runtime>/.nanomuse-resign.json`（记录 entitlements 指纹 +
  每个文件的 size/mtime）。之后启动只做一次 stat 比对，不重签。
- **原地重签，不复制**：不搬 MT-Agent 的运行时，也不改它的目录布局，
  只覆盖签名本身；文件内容（代码段/资源）保持原样。
- 设置页「准备 TheosRuntime」按钮会额外跑一次 `smokeTest`：
  依次执行 `clang-16 --version` / `make --version` / `ldid -h` / `dpkg-deb --version`，
  直接给出 OK / FAIL，不用再去猜是哪一层被拦。
