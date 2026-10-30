#!/bin/sh
# build-tipa.sh — 把 Swift 目标文件链接、签名、打包成可安装 tipa
#
# 用法:
#   ./build-tipa.sh <input.o> <AppName> <bundleId> [输出目录]
#
# 示例:
#   ./build-tipa.sh /var/minis/workspace/_ui.o UIDemo com.nanocode.uidemo
#
# 前提: 目标文件已由设备内 CoreCompiler 编译产出（见 README 第①步）
# 输出: <输出目录>/<AppName>.tipa （默认 /var/minis/attachments）

set -e

IN_O="$1"
APP_NAME="$2"
BUNDLE_ID="$3"
OUT_DIR="${4:-/var/minis/attachments}"

if [ -z "$IN_O" ] || [ -z "$APP_NAME" ] || [ -z "$BUNDLE_ID" ]; then
    echo "用法: $0 <input.o> <AppName> <bundleId> [输出目录]" >&2
    exit 1
fi

if [ ! -f "$IN_O" ]; then
    echo "错误: 找不到目标文件 $IN_O" >&2
    exit 1
fi

SDK="${SDK:-/tmp/tpk/iPhoneOS26.5.sdk}"
ENT="${ENT:-/var/minis/workspace/NanoCode/host/ent.plist}"

if [ ! -d "$SDK" ]; then
    echo "错误: SDK 不存在 $SDK" >&2
    exit 1
fi
if [ ! -f "$ENT" ]; then
    echo "错误: entitlements 不存在 $ENT" >&2
    exit 1
fi

WORK="$(mktemp -d /tmp/tipa.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

HEADER_BIN="$(dirname "$0")/header-o"   # 可选：带 UIApplicationMain 的占位目标

echo "==> [1/5] 链接 $APP_NAME"
ld64.lld -arch arm64 -platform_version ios 17.0 26.5 \
    -syslibroot "$SDK" \
    -o "$WORK/${APP_NAME}_exe" "$IN_O" \
    -L"$SDK/usr/lib/swift" -L"$SDK/usr/lib" \
    -lswiftCore -lswiftFoundation \
    -framework UIKit -framework Foundation 2>&1 | \
    grep -v 'newer than target minimum' || true

if [ ! -f "$WORK/${APP_NAME}_exe" ]; then
    echo "错误: 链接失败" >&2
    exit 1
fi

echo "==> [2/5] 校验 UI 入口"
UI_COUNT=$(llvm-nm -u "$WORK/${APP_NAME}_exe" 2>/dev/null | grep -c UIApplicationMain || true)
if [ "$UI_COUNT" -eq 0 ]; then
    echo "警告: 二进制里没有 UIApplicationMain —— 这是一个终端程序，安装后会闪退/黑屏。" >&2
    echo "      Swift 源码必须调用 UIApplicationMain(...) 才能成为 GUI app。" >&2
else
    echo "    UIApplicationMain 符号: $UI_COUNT ✓"
fi

echo "==> [3/5] 组装 app 包"
APP_DIR="$WORK/$APP_NAME.app"
mkdir -p "$APP_DIR"
cp "$WORK/${APP_NAME}_exe" "$APP_DIR/$APP_NAME"
chmod +x "$APP_DIR/$APP_NAME"

cat > "$APP_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>MinimumOSVersion</key><string>15.0</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIDeviceFamily</key><array><integer>1</integer></array>
</dict>
</plist>
PLIST

echo "==> [4/5] 签名"
ldid -S"$ENT" "$APP_DIR/$APP_NAME"

PK_DIR="$WORK/pk"
mkdir -p "$PK_DIR"
cp -a "$APP_DIR" "$PK_DIR/"

echo "==> [5/5] 打包"
mkdir -p "$OUT_DIR"
OUT_TIPA="$OUT_DIR/$APP_NAME.tipa"
rm -f "$OUT_TIPA"
python3 - "$PK_DIR" "$OUT_TIPA" <<'PY'
import sys, os, zipfile
pk, out = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED)
for r, d, fs in os.walk(pk):
    for f in fs:
        p = os.path.join(r, f)
        z.write(p, 'Payload/' + os.path.relpath(p, pk))
z.close()
print("    %.1f KB" % (os.path.getsize(out) / 1024))
PY

echo ""
echo "✓ 完成: $OUT_TIPA"
echo "  在 TrollStore 中打开该文件安装。"
