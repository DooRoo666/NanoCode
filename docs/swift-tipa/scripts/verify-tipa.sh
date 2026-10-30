#!/bin/sh
# verify-tipa.sh — 校验 tipa 或其内部可执行文件是否符合 iOS 安装要求
#
# 用法:
#   ./verify-tipa.sh <file>       # file 可以是 .tipa 或 .app 内的可执行文件

set -e

TARGET="$1"
if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
    echo "用法: $0 <foo.tipa | path/to/appexe>" >&2
    exit 1
fi

WORK=""
case "$TARGET" in
    *.tipa)
        WORK=$(mktemp -d /tmp/verify.XXXXXX)
        echo "==> 解包 $TARGET"
        unzip -q "$TARGET" -d "$WORK"
        EXE=$(find "$WORK/Payload" -type f -perm -u+x ! -name '*.plist' | head -1)
        PLIST=$(find "$WORK/Payload" -name 'Info.plist' | head -1)
        if [ -z "$EXE" ]; then
            echo "错误: 包内找不到可执行文件" >&2
            exit 1
        fi
        ;;
    *)
        EXE="$TARGET"
        PLIST=""
        ;;
esac

trap '[ -n "$WORK" ] && rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

echo ""
echo "==> 可执行文件: $(basename "$EXE")  ($(stat -c%s "$EXE" 2>/dev/null || echo '?') bytes)"

# 1. 魔数与 CPU 类型（直接从字节读，避开 objdump 误报）
MAGIC=$(xxd -l 4 -p "$EXE")
CPU=$(xxd -s 4 -l 4 -p "$EXE")
FTYPE=$(xxd -s 12 -l 4 -p "$EXE")

[ "$MAGIC" = "cffaedfe" ] && ok "MH_MAGIC_64 (64 位 Mach-O)" || bad "魔数 $MAGIC 不是 64 位 Mach-O"

case "$CPU" in
    0c000001) ok "CPU arm64e (A12+ 设备原生)" ;;
    0c000000) ok "CPU arm64 (兼容)" ;;
    *)        bad "CPU 类型 $CPU 未知" ;;
esac

[ "$FTYPE" = "02000000" ] && ok "MH_EXECUTE（可执行）" || bad "文件类型 $FTYPE 不是 MH_EXECUTE"

# 2. UI 入口
UI=$(llvm-nm -u "$EXE" 2>/dev/null | grep -c UIApplicationMain || true)
if [ "$UI" -ge 1 ]; then
    ok "UIApplicationMain 符号存在（GUI app）"
else
    bad "无 UIApplicationMain —— 终端程序，安装后会闪退/黑屏"
fi

# 3. 依赖库
DYLIBS=$(llvm-objdump --macho --dylibs-used "$EXE" 2>/dev/null || true)
for lib in UIKit Foundation; do
    echo "$DYLIBS" | grep -q "$lib.framework" && ok "依赖 $lib.framework" || echo "  - 未依赖 $lib.framework"
done
echo "$DYLIBS" | grep -q 'libswiftCore' && ok "依赖 libswiftCore.dylib" || echo "  - 未依赖 libswiftCore"
echo "$DYLIBS" | grep -q 'libswiftFoundation' && ok "依赖 libswiftFoundation.dylib" || echo "  - 未依赖 libswiftFoundation"

# 4. 签名
SIG=$(llvm-objdump --macho --private-headers "$EXE" 2>/dev/null | grep -c LC_CODE_SIGNATURE || true)
[ "$SIG" -ge 1 ] && ok "LC_CODE_SIGNATURE 存在（已签名）" || bad "未签名（缺少 LC_CODE_SIGNATURE）"

if ldid -e "$EXE" >/dev/null 2>&1; then
    ok "ldid 能解析 entitlements"
else
    bad "ldid 无法解析 entitlements"
fi

# 5. Info.plist
if [ -n "$PLIST" ]; then
    echo ""
    echo "==> Info.plist"
    grep -q 'CFBundleExecutable' "$PLIST" && ok "CFBundleExecutable 存在" || bad "缺 CFBundleExecutable"
    grep -q 'CFBundleIdentifier' "$PLIST" && ok "CFBundleIdentifier 存在" || bad "缺 CFBundleIdentifier"
    grep -q 'APPL' "$PLIST" && ok "CFBundlePackageType = APPL" || bad "CFBundlePackageType 不是 APPL"
    BIN_NAME=$(basename "$EXE")
    grep -A1 CFBundleExecutable "$PLIST" | grep -q "$BIN_NAME" \
        && ok "CFBundleExecutable 与实际文件名一致 ($BIN_NAME)" \
        || bad "CFBundleExecutable 与文件名 $BIN_NAME 不一致"
fi

echo ""
echo "──────────────────────────────"
echo "通过 $PASS 项，失败 $FAIL 项"
if [ "$FAIL" -gt 0 ]; then
    echo "结论: 存在问题，安装后可能闪退"
    exit 1
fi

echo "结论: 全部通过"
echo ""
echo "注意：llvm-objdump -f 对 ldid 签名后的文件会报 Invalid（签名段改变布局），"
echo "      属误报。本脚本用字节魔数 + llvm-nm 校验，不受影响。"
