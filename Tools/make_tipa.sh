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

echo "== 1/3 nested Mach-O: ad-hoc =="
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

echo "== 2/3 extensions =="
shopt -s nullglob
for appex in "$TARGET"/PlugIns/*.appex "$TARGET"/AppExtensions/*.appex; do
  exe="$appex/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
  if [ -f "$exe" ]; then
    "$LDID" -S"$MAIN_ENT" "$exe"
    echo "   signed $(basename "$appex")"
  fi
done
shopt -u nullglob

echo "== 3/3 main executable =="
"$LDID" -S"$MAIN_ENT" "$TARGET/$APP_NAME"

echo "== package =="
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
