#!/bin/sh
# 本地 C 源码 -> iOS .app -> TrollStore .tipa
# 用法: ./build.sh hello.c          产物: out/hello.tipa
#       ./build.sh myapp/           (目录里需有 Info.plist，源码 *.c)
set -e

SDK=${SDK:-/tmp/tpk/iPhoneOS26.5.sdk}
TARGET=${TARGET:-arm64e-apple-ios14.0}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/out"
CC=${CC:-clang}

[ -e "$SDK/SDKSettings.plist" ] || { echo "找不到 SDK: $SDK"; exit 1; }
[ $# -ge 1 ] || { echo "用法: $0 <源文件.c | 目录>"; exit 1; }
SRC=$1

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -d "$SRC" ]; then
  NAME=$(basename "$SRC")
  SRC_DIR=$SRC
else
  NAME=$(basename "$SRC" .c)
  SRC_DIR=$WORK/src
  mkdir -p "$SRC_DIR"
  cp "$SRC" "$SRC_DIR/"
fi

APP="$WORK/Payload/$NAME.app"
mkdir -p "$APP"

# ---- 1. 编译并链接成 Mach-O (iOS arm64e) -------------------------------
# shellcheck disable=SC2046
$CC -target "$TARGET" -fuse-ld=lld -isysroot "$SDK" -O2 \
    -Wl,-platform_version,ios,14.0,26.5 \
    -framework Foundation -framework UIKit \
    $(find "$SRC_DIR" -name '*.c' -o -name '*.m' -o -name '*.cpp') \
    -o "$APP/$NAME"
chmod +x "$APP/$NAME"

# ---- 2. Info.plist -----------------------------------------------------
if [ -f "$SRC_DIR/Info.plist" ]; then
  cp "$SRC_DIR/Info.plist" "$APP/Info.plist"
else
  cat > "$APP/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>local.nanocode.$NAME</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>14.0</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
</dict></plist>
EOF
fi

# ---- 3. 签名 -----------------------------------------------------------
if [ -f "$SRC_DIR/entitlements.plist" ]; then ENT=$SRC_DIR/entitlements.plist; else
  ENT=$WORK/ent.plist
  cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
EOF
fi
ldid -S"$ENT" "$APP/$NAME"

# ---- 4. 打包 .tipa -----------------------------------------------------
rm -f "$OUT/$NAME.tipa"
( cd "$WORK" && zip -qr "$OUT/$NAME.tipa" Payload -x '.*' -x '*/.*' )
echo "OK -> $OUT/$NAME.tipa"
unzip -l "$OUT/$NAME.tipa" | tail -5
