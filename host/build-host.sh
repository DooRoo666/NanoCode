#!/bin/sh
# 在 iSH 侧构建宿主 App 可执行文件（arm64e, iOS）
set -e
SDK=/tmp/tpk/iPhoneOS26.5.sdk
ROOT=/var/minis/workspace/NanoCode/host
OUT=$ROOT/NanoCodeHost.app/NanoCodeHost

clang -target arm64e-apple-ios26.5 \
  -isysroot "$SDK" \
  -isystem "$SDK/usr/include" \
  -F "$SDK/System/Library/Frameworks" \
  -fuse-ld=lld \
  -framework CoreFoundation \
  -O2 \
  -o "$OUT" \
  "$ROOT/main.c"

echo "built: $OUT"
ls -l "$OUT"
