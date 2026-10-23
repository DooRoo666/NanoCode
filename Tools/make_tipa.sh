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
APP_NAME="$(basename "$APP" .app)"
MAIN_ENT="$ROOT/Tools/entitlements-app.plist"
[ -f "$MAIN_ENT" ] || { echo "error: missing $MAIN_ENT" >&2; exit 1; }

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
      mkdir -p "$TARGET/Helpers/$(dirname "$link")"
      ln -sfn "$target" "$TARGET/Helpers/$link"
    done < "$HELPERS_SRC/_symlinks.txt"
  fi
  echo "   helpers: $(find "$TARGET/Helpers" -type f | wc -l | tr -d ' ') files, $(find "$TARGET/Helpers" -type l | wc -l | tr -d ' ') links"
else
  echo "   (跳过：没有 vendor/helpers)"
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

echo "== 1/4 nested Mach-O: ad-hoc =="
count=0
while IFS= read -r -d '' f; do
  if is_macho "$f"; then
    case "$f" in
      "$TARGET/$APP_NAME") continue ;;                    # 主程序最后签
      *.appex/*) continue ;;                              # 扩展单独签
      *) "$LDID" -S "$f"; count=$((count+1)) ;;
    esac
  fi
done < <(find "$TARGET" -type f -print0)
echo "   signed $count nested binaries"

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
