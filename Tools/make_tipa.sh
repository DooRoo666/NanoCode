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

# 正向守卫：runtime 模板必须带 disable-library-validation。
# 少了它的表现是 clang-16 报
#   Library not loaded: @rpath/libiosexec.1.dylib / sandbox blocked mmap()
# 极难从现象倒推回权限，所以在构建期直接拦住。
# 与 MT-Agent 逐字对齐：她的主程序和运行时二进制用**同一份** 14 键权限表，
# 里面既没有 disable-library-validation，也没有 com.apple.container-required。
# 实测过：多带 disable-library-validation / container-required 的 1068B 版本签名出
# 来的 python3 能在容器里启动，却mmap 不了自己的 Python.framework（sandbox
# blocked mmap）；换成她那份 1036B 的原版二进制，同一路径同一 framework 立刻能跑。
# 所以这里改成：模板必须与 MT 一致，多一个键都报错。
if grep -q "<key>com.apple.security.cs.disable-library-validation</key>" "$RUNTIME_ENT"; then
  echo "error: runtime 模板多了 disable-library-validation（实测会让运行时 mmap 失败）" >&2
  exit 1
fi
if grep -q "<key>com.apple.container-required</key>" "$RUNTIME_ENT"; then
  echo "error: runtime 模板含无效键 com.apple.container-required" >&2
  exit 1
fi

# 反向守卫：这两条是 macOS Hardened Runtime 的键，iOS 上属非法授权。
# AMFI 会拒绝**整份**签名，表现是 App 一启动就闪退 —— 比功能失效更难查。
for bad in dynamic-codesigning com.apple.security.cs.allow-unsigned-executable-memory; do
  for f in "$MAIN_ENT" "$RUNTIME_ENT"; do
    if grep -q "<key>${bad}</key>" "$f"; then
      echo "error: $(basename "${f}") 含 iOS 非法键 ${bad}（AMFI 会拒签导致闪退）" >&2
      exit 1
    fi
  done
done

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
    # MT 原版把 Helpers/{sh,bash,bash-codex} 指向 bash.real，而 bash.real 一到
    # 管道 / 重定向 / 子 shell / $( ) 就 SIGBUS。nsh 语义覆盖到同样的子集，
    # 且全程 posix_spawn，所以编译成功时就把这几个别名切过来。
    # （nsh 没编出来时保持指向 bash.real，至少单命令还能用。）
    for alias in sh bash bash-codex; do
      rm -f "$TARGET/Helpers/$alias"
      ln -s nsh "$TARGET/Helpers/$alias"
    done
    echo "   Helpers/{sh,bash,bash-codex} → nsh"
  else
    echo "   warning: nsh 编译失败，codex 仍会退回 bash.real（fork 会崩）" >&2
  fi
else
  echo "   (跳过：没有 nsh.c 或 xcrun)"
fi

echo "== 0a2/4 编译 tarx（自带的 .tar.gz 解包器） =="
# iOS 没有 tar；ca-filetool 的 tar 只实现 create 模式，解不了 TheosRuntime。
# tarx 只链 libSystem + libz，没有第三方 dylib，所以不需要关 library validation。
TARX_SRC="$ROOT/Tools/forkless-sh/tarx.c"
if [ -f "$TARX_SRC" ] && command -v xcrun >/dev/null 2>&1; then
  SDKTX="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
  if [ -n "$SDKTX" ] && xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
      -O2 -Wall -isysroot "$SDKTX" -lz -o "$TARGET/Helpers/tarx" "$TARX_SRC"; then
    chmod 0755 "$TARGET/Helpers/tarx"
    echo "   tarx 编译完成：$(du -h "$TARGET/Helpers/tarx" | cut -f1)"
  else
    echo "   warning: tarx 编译失败，TheosRuntime 将无法解包" >&2
  fi
else
  echo "   (跳过：没有 tarx.c 或 xcrun)"
fi

echo "== 0a3/4 编译 machrepoint（依赖重定向） =="
# 把 TheosRuntime 里对 @rpath/libiosexec.1.dylib 的依赖改成系统 libSystem：
# 本机不允许 mmap 第三方 dylib，而 libiosexec 导出的就是 posix_spawn/execve/fopen。
MR_SRC="$ROOT/Tools/forkless-sh/machrepoint.c"
if [ -f "$MR_SRC" ] && command -v xcrun >/dev/null 2>&1; then
  SDKMR="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
  if [ -n "$SDKMR" ] && xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
      -O2 -Wall -isysroot "$SDKMR" -o "$TARGET/Helpers/machrepoint" "$MR_SRC"; then
    chmod 0755 "$TARGET/Helpers/machrepoint"
    echo "   machrepoint 编译完成：$(du -h "$TARGET/Helpers/machrepoint" | cut -f1)"
  else
    echo "   warning: machrepoint 编译失败" >&2
  fi
else
  echo "   (跳过：没有 machrepoint.c 或 xcrun)"
fi

echo "== 0b/4 编译 fork 对照实验（arm64 vs arm64e） =="
# 同一份代码编两个架构：用来分辨「fork 被内核拒绝」还是「arm64e 的 PAC 让它崩」。
FORKTEST_SRC="$ROOT/Tools/forkless-sh/forktest.c"
if [ -f "$FORKTEST_SRC" ] && command -v xcrun >/dev/null 2>&1; then
  SDKDIR2="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
  if [ -n "$SDKDIR2" ]; then
    # 注意：变量名不要用 OUT —— 那是后面打包步骤的输出目录，会被覆盖
    for ft_arch in arm64 arm64e; do
      FT_OUT="$TARGET/Helpers/forktest-$ft_arch"
      if xcrun --sdk iphoneos clang -arch "$ft_arch" -miphoneos-version-min=15.0 \
          -O1 -isysroot "$SDKDIR2" -o "$FT_OUT" "$FORKTEST_SRC" 2>&1; then
        chmod 0755 "$FT_OUT"
        echo "   forktest-$ft_arch 编译完成"
      else
        echo "   warning: forktest-$ft_arch 编译失败" >&2
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
echo "   entitlements.plist ← Tools/entitlements-runtime.plist（与 MT-Agent 逐字同构的 14 键表）"

echo "== 0c/4 运行时：不再随包，改为运行时下载（对齐 MT-Agent 的"自身小"） =="
# 原来这里把 /usr/local/bin 的上百个工具（rt-bin 18MB）和它们依赖的 dylib
# （rt-lib 33MB）以及 Python（py 11MB）全部塞进 Helpers/rt、Helpers/py，
# 于是 tipa 一路涨到 115MB。
#
# MT Agent 只有 3.8MB：它把这些东西**运行时下载**、解压到自己的 .app 里
# （实测 TheosRuntime/PythonRuntime 属主 mobile:501，就是从外部写进去的）。
# 所以这里什么都不打进去，只保留一个空的运行时目录作为安装点。
# 真正的下载/校验/解压逻辑在 NanoMuseRuntimeInstaller.swift。
cp "$ROOT/Tools/entitlements-dylib.plist" "$TARGET/entitlements-dylib.plist"
echo "   entitlements-dylib.plist ← 空字典（dylib/framework 不带权限签名）"
mkdir -p "$TARGET/Runtimes"
if [ -f "$ROOT/Runtimes/python.zip" ]; then
  # 预置运行时：与 MT-Agent 的 .app/PythonRuntime 完全相同的字节（她那份已在本机
  # 验证能跑 ssl/sqlite3）。不能靠 App 自己下载再签 —— 实测容器内 mmap 被拒
  # （sandbox blocked mmap），只有 App 包内可执行，而包内属主 33:33、App 是 501 写不进。
  mkdir -p "$TARGET/Runtimes/python"
  ( cd "$TARGET/Runtimes/python" && unzip -oq "$ROOT/Runtimes/python.zip" )
  printf 'bundled\n' > "$TARGET/Runtimes/python/.installed"
  chmod -R 0755 "$TARGET/Runtimes/python" 2>/dev/null || true
  echo "   Runtimes/python/ ← 预置（$(du -sh "$TARGET/Runtimes/python" 2>/dev/null | cut -f1)），保持原签名"
else
  chmod 0777 "$TARGET/Runtimes"
  echo "   Runtimes/ 留空，由 App 首启动下载"
fi

# 兼容旧版本：如果 Helpers/rt、Helpers/py 还在（历史产物），清掉避免 virtpath 混乱
rm -rf "$TARGET/Helpers/rt" "$TARGET/Helpers/py" 2>/dev/null || true
echo "   Helpers/rt、Helpers/py 已移除（改由 Runtimes/ 承载）"

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
      */Runtimes/*)
        # 预置运行时（Python 等）是 Device 侧用 codex-sign 签好的，形态与 MT-Agent
        # 的 PythonRuntime 完全一致（dylib 3 blob、launcher 5 blob）。用 ldid 重签会把
        # 它改坏，所以原样保留。
        keepCount=$((keepCount+1))
        continue ;;                            
      */Helpers/bash.real|*/Helpers/codex-sign|*/Helpers/ca-filetool)
        # 这三个是 MT-Agent 发布时用 ldid + 完整巨魔权限签好的。
        # 我们重签会改写 CodeDirectory / requirements / 特殊槽位，虽然形态看起来一样，
        # 但会让「fork 出来的子进程」在 CS 校验上失败 → Bus error 10。
        if has_signature "$f"; then
          keepCount=$((keepCount+1))
        else
          "$LDID" -S"$MAIN_ENT" "$f"; helperCount=$((helperCount+1))
        fi
        ;;
      */Helpers/*)
        # 我们自己编的（nsh / forktest-arm64 / forktest-arm64e）：
        # 链接器会自动给一个 ad-hoc 签名，它**没有任何 entitlement**。
        # 早先这里复用了「有签名就保留」的判定，于是 nsh 一直裸奔——
        # 它起的子进程没有 no-sandbox / disable-library-validation，
        # 加载 TheosRuntime 的 dylib 照样被拦。
        "$LDID" -S"$MAIN_ENT" "$f"; helperCount=$((helperCount+1))
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
