# capp — 本地 C 源码 → iOS .tipa

## 用法
```sh
cd /var/minis/workspace/NanoCode/capp
sh build.sh hello.c            # -> out/hello.tipa
sh build.sh myapp/             # 目录模式；目录内可放 Info.plist / entitlements.plist
```
- SDK 默认 `/tmp/tpk/iPhoneOS26.5.sdk`（可 `SDK=` 覆盖）
- 目标默认 `arm64e-apple-ios14.0`（该 SDK 的 .tbd 只有 arm64e-ios，编 arm64 会失败）
- 产物结构：`Payload/<name>.app/{<name>, Info.plist}`，主程序已用 `ldid -S` 签名
- 验证：`unzip -l out/x.tipa`、Mach-O magic `feedfacf` + cputype `0x0100000c`

## 已验证
- clang 19 + ld64.lld + iPhoneOS26.5.sdk 交叉链接可产出 arm64e Mach-O
- hello.tipa 结构正确、含 LC_CODE_SIGNATURE
- 未验证：真机启动（需要实际安装）

## 限制
- 只支持 C / Objective-C / C++；**不支持 Swift**（该 SDK 的 Swift 与 Foundation 只带 arm64e
  `.swiftinterface`，而且编译器 driver 需要 fork，本机 fork 不可用）
