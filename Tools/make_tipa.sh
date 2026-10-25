#!/usr/bin/env bash
# 把 xcodebuild 产物打成一个 TrollStore 能装的 .tipa。
#
#   bash Tools/make_tipa.sh <Minis.app 路径> [输出目录]
#
# 三档签名（顺序不能反）：
#   1. 所有嵌套 Mach-O（框架、内嵌可执行）先 ad-hoc 签，否则外层签名会失败；
#   2. 各扩展 .appex 用扩展权限签；
#   3. 主 App 最后用完整权限签（含 platform-application / no-sandbox）。
set -euo pipefail

APP="${1:?usage: make_tipa.sh <App.app> [outdir]}"
OUT="${2:-dist}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LDID="${LDID:-$(command -v ldid || true)}"
[ -n "$LDID" ] || { echo "error: ldid not found (brew install ldid)" >&2; exit 1; }
OTOOL="${OTOOL:-$(command -v otool || true)}"
APP_NAME="$(basename "$APP" .app)"
MAIN_ENT="$ROOT/Tools/entitlements-app.plist"
RUNTIME_ENT="$ROOT/Tools/entitlements-runtime.plist"
[ -f "$MAIN_ENT" ] || { echo "error: missing $MAIN_ENT" >&2; exit 1; }
[ -f "$RUNTIME_ENT" ] || { echo "error: missing $RUNTIME_ENT" >&2; exit 1; }

# extended-virtual-addressing（EVA）只允许出现在 **runtime 模板** 里：
# MT-Agent 原版就带它，clang-16 / ld64 这类工具链需要 48 位地址空间映射大量段，
# 没有它会在加载 dylib 时失败（"sandbox blocked mmap"）。
# 主程序 Minis 仍不带 —— 它自己的进程行为保持原样，避免影响 fork。
# 注意：早先以为 EVA 会让 fork 崩，后来实测 os.fork()/fork+exec 在 TheosRuntime 下都正常，
# 所以 EVA 不是 SIGBUS 的原因，不该一刀切掉。
if grep -q "<key>com.apple.developer.kernel.extended-virtual-addressing</key>" "$MAIN_ENT"; then
  echo "error: 主程序模板里不该有 extended-virtual-addressing（只放在 runtime 模板）" >&2
  exit 1
fi

is_macho() { file -b "$1" 2>/dev/null | grep -q "Mach-O"; }

rm -rf "$OUT/Payload"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/$APP_NAME.app"
TARGET="$OUT/Payload/$APP_NAME.app"

echo "== 0/4 Helpers（MT-Agent 工具链：codex-sign / ca-filetool / bash.real + 链接） =="
HELPERS_SRC="$ROOT/vendor/helpers"
if [ -d "$HELPERS_SRC" ]; then
  mkdir -p "$TARGET/Helpers"
  # 真实文件
  while IFS= read -r -d '' f; do
    rel="${f#$HELPERS_SRC/}"
    [ "$rel" = "_symlinks.txt" ] && continue
    mkdir -p "$TARGET/Helpers/$(dirname "$rel")"
    cp "$f" "$TARGET/Helpers/$rel"
    chmod 0755 "$TARGET/Helpers/$rel"
  done < <(find "$HELPERS_SRC" -type f -print0)
  # 符号链接（zip 里以文本记录，这里还原成真链接）
  if [ -f "$HELPERS_SRC/_symlinks.txt" ]; then
    while IFS=$'\t' read -r link target; do
      [ -z "${link:-}" ] && continue
      # _symlinks.txt 是 Windows 仓库里的 CRLF：必须剥掉行尾的 \r，
      # 否则链接会指向 "ca-filetool\r" 这种不存在的文件，
      # 结果就是 ls / cat / grep / head 全部 command not found。
      link="${link%$'\r'}"
      target="${target%$'\r'}"
      mkdir -p "$TARGET/Helpers/$(dirname "$link")"
      ln -sfn "$target" "$TARGET/Helpers/$link"
    done < "$HELPERS_SRC/_symlinks.txt"
  fi
  echo "   helpers: $(find "$TARGET/Helpers" -type f | wc -l | tr -d ' ') files, $(find "$TARGET/Helpers" -type l | wc -l | tr -d ' ') links"
else
  echo "   (跳过：没有 vendor/helpers)"
fi

echo "== 0a/4 编译 forkless shell（nsh） =="
# bash.real 执行任何外部命令、管道、重定向都要 fork，而 iOS 从 SDK 层禁了 fork，
# 结果就是 codex 的 shell 一调命令就 SIGBUS(10)。
# nsh 用 posix_spawn 实现同样的语义（管道靠 pipe()+两次 spawn），全程不 fork，
# 所以把它作为 codex 的 $SHELL / sh / bash，codex 的命令执行才真的能用。
NSH_SRC="$ROOT/Tools/forkless-sh/nsh.c"
if [ -f "$NSH_SRC" ] && command -v xcrun >/dev/null 2>&1; then
  SDKDIR="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
  NSH_OK=0
  if [ -n "$SDKDIR" ]; then
    # arm64 更稳（arm64e 需要额外 linker 支持），系统两种都能跑
    if xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
        -O2 -Wall -Wextra -Wno-unused-parameter -isysroot "$SDKDIR" \
        -o "$TARGET/Helpers/nsh" "$NSH_SRC" 2>&1; then
      chmod 0755 "$TARGET/Helpers/nsh"
      NSH_OK=1
    fi
  fi
  if [ "$NSH_OK" = "1" ]; then
    echo "   nsh 编译完成：$(du -h "$TARGET/Helpers/nsh" | cut -f1)"
  else
    echo "   warning: nsh 编译失败，codex 仍会退回 bash.real（fork 会崩）" >&2
  fi
else
  echo "   (跳过：没有 nsh.c 或 xcrun)"
fi

echo "== 0b/4 编译 fork 对照实验（arm64 vs arm64e） =="
# 同一份代码编两个架构：用来分辨「fork 被内核拒绝」还是「arm64e 的 PAC 让它崩」。
FORKTEST_SRC="$ROOT/Tools/forkless-sh/forktest.c"
if [ -f "$FORKTEST_SRC" ] && command -v xcrun >/dev/null 2>&1; then
  SDKDIR2="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
  if [ -n "$SDKDIR2" ]; then
    for arch in arm64 arm64e; do
      OUT="$TARGET/Helpers/forktest-$arch"
      if xcrun --sdk iphoneos clang -arch "$arch" -miphoneos-version-min=15.0 \
          -O1 -isysroot "$SDKDIR2" -o "$OUT" "$FORKTEST_SRC" 2>&1; then
        chmod 0755 "$OUT"
        echo "   forktest-$arch 编译完成"
      else
        echo "   warning: forktest-$arch 编译失败" >&2
      fi
    done
  fi
else
  echo "   (跳过：没有 forktest.c 或 xcrun)"
fi

echo "== 0b/4 随包资源（Mermaid / cacert / models.json / 兜底提示词 / Notices） =="
BUNDLE_SRC="$ROOT/vendor/bundle"
if [ -d "$BUNDLE_SRC" ]; then
  while IFS= read -r -d '' f; do
    rel="${f#$BUNDLE_SRC/}"
    mkdir -p "$TARGET/$(dirname "$rel")"
    cp "$f" "$TARGET/$rel"
  done < <(find "$BUNDLE_SRC" -type f -print0)
  echo "   bundled resources: $(find "$BUNDLE_SRC" -type f | wc -l | tr -d ' ')"
else
  echo "   (跳过：没有 vendor/bundle)"
fi

# 用 runtime 模板覆盖随包的 entitlements.plist：
# 这个文件既是我们给 codex / TheosRuntime 签名的模板，也是签名页展示的权限清单。
# 它包含 extended-virtual-addressing（对齐 MT-Agent 原版，clang/ld 需要）。
cp "$RUNTIME_ENT" "$TARGET/entitlements.plist"
echo "   entitlements.plist ← Tools/entitlements-runtime.plist（含 disable-library-validation + EVA）"

echo "== 1/4 nested Mach-O: Helpers 保留原签名，其余 ad-hoc =="
# Helpers 里的 bash.real / codex-sign / ca-filetool 是 MT-Agent 发布时已经签好的
# （ldid + 完整巨魔权限，含 extended-virtual-addressing）。
# 我们重签会改写 CodeDirectory / requirements / 特殊槽位，虽然形态看起来一样，
# 但会让「fork 出来的子进程」在 CS 校验上失败 → Bus error 10。
# 既然原版单独安装能跑，就原样保留它们的签名，不再动。
# 只有确实没签名的（例如我们自己编的）才补签。
count=0
helperCount=0
keepCount=0
has_signature() {
  [ -n "$OTOOL" ] || return 1
  "$OTOOL" -l "$1" 2>/dev/null | grep -q LC_CODE_SIGNATURE
}
while IFS= read -r -d '' f; do
  if is_macho "$f"; then
    case "$f" in
      "$TARGET/$APP_NAME") continue ;;                    # 主程序最后签
      *.appex/*) continue ;;                              # 扩展单独签
      */Helpers/*)
        if has_signature "$f"; then
          keepCount=$((keepCount+1))
        else
          "$LDID" -S"$MAIN_ENT" "$f"; helperCount=$((helperCount+1))
        fi
        ;;
      *) "$LDID" -S "$f"; count=$((count+1)) ;;
    esac
  fi
done < <(find "$TARGET" -type f -print0)
echo "   signed $count nested binaries, $helperCount helpers re-signed with entitlements, $keepCount helpers kept original signature"

echo "== 2/4 extensions =="
shopt -s nullglob
for appex in "$TARGET"/PlugIns/*.appex "$TARGET"/AppExtensions/*.appex; do
  exe="$appex/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
  if [ -f "$exe" ]; then
    "$LDID" -S"$MAIN_ENT" "$exe"
    echo "   signed $(basename "$appex")"
  fi
done
shopt -u nullglob

echo "== 3/4 main executable =="
"$LDID" -S"$MAIN_ENT" "$TARGET/$APP_NAME"

echo "== 4/4 package =="
cd "$OUT"
rm -f NanoCode.tipa
zip -qry -y NanoCode.tipa Payload
ls -lh NanoCode.tipa

if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import zipfile, sys
z = zipfile.ZipFile("NanoCode.tipa")
names = z.namelist()
links = sum(1 for i in z.infolist() if (i.external_attr >> 16) & 0o170000 == 0o120000)
print(f"   {len(names)} entries, {links} symlinks")
missing = [n for n in names if "__MACOSX" in n]
if missing:
    print("error: resource forks inside the archive", file=sys.stderr); sys.exit(1)
PY
fi
