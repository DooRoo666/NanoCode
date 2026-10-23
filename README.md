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
