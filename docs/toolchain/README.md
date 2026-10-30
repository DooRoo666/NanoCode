# NanoCode 工具链（本体轻量 + 按需下载）

本体只带引擎（约 40KB Python），所有重型工具从你的 GitHub 下载。

## 设计原则

| 要求 | 实现 |
|---|---|
| 本体不大 | 引擎是纯 Python 脚本，无二进制。`CoreCompiler`(186MB) / SDK(192MB) / SwiftRT(142MB) 一律不打包 |
| 从自己 GitHub 下载 | `registry/tools.json` 里全是 URL，改一行就换仓库 |
| 工具列表可换 | 注册表驱动，引擎代码不认具体工具名 |
| 后期改自己的 | `sources` 支持多镜像源、自动回退 |

## 目录

```
nanocode-toolchain/
├── engine/
│   ├── build.py      构建流水线（.o/.swift → .tipa）
│   ├── lint.swift    源码静态检查（拦黑屏/闪退）
│   ├── fetch.py      多源下载器（续传+校验+进度）
│   └── tc.sh         工具管理器（list/status/install/path）
├── registry/
│   ├── tools.json    ★ 工具清单，你改这里
│   └── ent.plist     签名授权
└── tools/            下载到这里（git 忽略）
```

## 快速使用

```sh
# 1. 看状态
sh engine/tc.sh status

# 2. 装缺失工具
sh engine/tc.sh install

# 3. 构建
python3 engine/build.py app.o --name MyApp --bundle-id com.you.myapp
```

## 换成你自己的工具列表

只改 `registry/tools.json` 三处：

```json
{
  "sources": {
    "default": ["https://github.com/你的账号/你的仓库/releases/download/v1"],
    "mirror":  ["https://ghproxy.net/https://github.com/..."]
  },
  "tools": {
    "你的工具名": {
      "label": "显示名",
      "size": "~10MB",
      "description": "一句话说明",
      "required": true,
      "install": { "type": "file", "url": "tool.bin", "saveAs": "bin/tool" },
      "probe": { "file": "bin/tool" }
    }
  }
}
```

- `install.type`: `file`（单文件）或 `archive`（自动解压 .zip/.zst/.tar.gz）
- `probe.file`: 判定「已安装」的标志文件（相对 `tools/`）
- `required`: 缺失时是否阻止构建

## 为什么必须下载而不是内置

| 工具 | 体积 | 能否内置 |
|---|---|---|
| CoreCompiler.framework | 186 MB | ✗ 超 App Store 限制，TrollStore 也嫌大 |
| iPhoneOS26.5.sdk | 192 MB | ✗ |
| Shared/swift | 142 MB | ✗ |
| ld64.lld | 67 KB | ✓ 但没必要，一起下载 |
| ldid | 268 KB | ✓ |

**引擎本体 < 50KB**，这就是你要的「本体不大」。

## 关键约束（踩过的坑）

1. **源码必须含 `UIApplicationMain`** —— 否则编出终端程序，装上一闪就退
2. **链接必须带 `-framework UIKit -lswiftFoundation`** —— 否则 UI 入口符号缺失
3. **构建前自动跑 lint** —— 第 1 条已在 `build.py` 里强制检查，不合格直接拒绝
4. `llvm-objdump -f` 对 ldid 签名后的文件报 Invalid 属**误报**，用 `llvm-nm` 验证

## 与 iSH 的关系

引擎可在 iSH（Linux）和 iOS app 进程内两处运行：
- iSH：完整可用，已验证（本机 `ld64.lld` + `ldid`）
- app 进程内：需 Darwin 版 `ld64.lld`，从上面 `sources` 下载即可替换
