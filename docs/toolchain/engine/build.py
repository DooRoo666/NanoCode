#!/usr/bin/env python3
"""NanoCode 构建流水线：Swift 源码 → 可运行 .tipa

设计原则
--------
* 本体不内置任何工具，全部按需从 GitHub Release 下载
* 每步失败都给出「人话」解释，而不是让用户对着 ld64 的报错猜
* UI 入口符号（UIApplicationMain）在链接后强制校验 —— 这是黑屏的头号杀手

用法
----
  python3 build.py <source.swift> [--name App] [--bundle-id com.you.app]
  python3 build.py --check          # 只检查工具链是否就绪
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REGISTRY = os.environ.get("NANOCODE_REGISTRY", os.path.join(ROOT, "registry", "tools.json"))
BASE = os.environ.get("NANOCODE_BASE", os.path.join(ROOT, "tools"))

C_OK, C_NO, C_WARN, C_DIM, C_END = "\033[32m", "\033[31m", "\033[33m", "\033[90m", "\033[0m"


def say(msg, kind="info"):
    tag = {"info": " ", "ok": C_OK + "✓", "err": C_NO + "✗",
           "warn": C_WARN + "!", "step": C_DIM + ">"}.get(kind, " ")
    print(f"{tag}{C_END} {msg}")


def load_registry():
    with open(REGISTRY, encoding="utf-8") as f:
        return json.load(f)["tools"]


def tool_path(tools, name):
    """返回工具可执行文件的绝对路径，未安装则返回 None"""
    t = tools.get(name)
    if not t:
        return None
    probe = t.get("probe", {})
    p = os.path.join(BASE, probe.get("file", ""))
    return p if os.path.exists(p) else None


def tool_ready(tools, name):
    t = tools.get(name)
    if not t:
        return False
    p = tool_path(tools, name)
    return bool(p)


def missing_tools(tools):
    return [k for k, v in tools.items()
            if not os.path.exists(os.path.join(BASE, v.get("probe", {}).get("file", "")))]


def find_sdk_root(tools):
    """SDK 根 = 探活文件向上查找，直到找到 SDKSettings.json 所在目录"""
    t = tools.get("sdk", {})
    probe = os.path.join(BASE, t.get("probe", {}).get("file", ""))
    if not os.path.exists(probe):
        return None
    # 探活文件本身可能就叫 SDKSettings.json，否则往上找
    d = os.path.dirname(probe)
    while d and d != BASE:
        if os.path.exists(os.path.join(d, "SDKSettings.json")) or \
           os.path.exists(os.path.join(d, "SDKSettings.plist")):
            return d
        d = os.path.dirname(d)
    return os.path.dirname(probe)


def run(cmd, capture=True):
    r = subprocess.run(cmd, capture_output=capture, text=True)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def nm_has_symbol(binary, symbol):
    """检查未定义符号表里是否含 symbol（判断 UIApplicationMain 是否真的被引用）"""
    for nm in ("llvm-nm", "nm"):
        try:
            rc, out = run([nm, "-u", binary])
        except FileNotFoundError:
            continue
        if rc == 0:
            return any(symbol in line for line in out.splitlines())
    # 没有 nm 时退化为二进制搜索
    with open(binary, "rb") as f:
        return symbol.encode() in f.read()


def build(src, name, bundle_id, outdir):
    tools = load_registry()
    # 阶段化校验：本流程是 .o → tipa，只需要链接器 + 签名器 + SDK
    # corecompiler / swiftrt 属于「源码 → .o」阶段，由设备端完成，此处不要求
    LINK_STAGE = ("ld64", "ldid", "sdk")
    miss = [k for k in LINK_STAGE if not tool_ready(tools, k)]
    if miss:
        say("链接阶段工具缺失：" + ", ".join(miss), "err")
        say("先运行：sh tc.sh install  或  python3 build.py --check", "warn")
        return 2

    sdk = find_sdk_root(tools)
    ld = tool_path(tools, "ld64")
    ldid = tool_path(tools, "ldid")
    if not all([sdk, ld, ldid]):
        say("关键工具路径解析失败", "err")
        return 2

    work = os.path.join(outdir, ".build-" + name)
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)

    # ---------- 1. 编译 / 直通 ----------
    ext = os.path.splitext(src)[1].lower()
    if ext in (".o", ".obj"):
        # 已经是目标文件（设备端 CoreCompiler 产物），直接进入链接
        say(f"[1/5] 目标文件直通 {os.path.basename(src)}", "step")
        obj = src
        say(f"      {os.path.getsize(obj)} 字节", "ok")
    elif ext == ".swift":
        # 先静态检查：拦截会导致闪退/黑屏的代码（NO_UI_ENTRY 等）
        lint = os.path.join(ROOT, "engine", "lint.swift")
        if os.path.exists(lint):
            rc, out = run([sys.executable, lint, src])
            if out.strip():
                print(out.rstrip())
            if rc != 0:
                say("源码检查未通过，已阻止编译", "err")
                say("补齐 UIApplicationMain 后重试", "info")
                return 4
        say(f"[1/5] 编译 {os.path.basename(src)}", "step")
        obj = os.path.join(work, "main.o")
        cc = tool_path(tools, "corecompiler")
        if cc and os.path.exists(cc):
            rc, out = run([cc, "-target", "arm64-apple-ios26.5", "-sdk", sdk,
                           "-emit-object", "-o", obj, src])
        else:
            rc, out = run(["clang", "-target", "arm64-apple-ios26.5", "-isysroot", sdk,
                           "-c", "-o", obj, src])
        if rc != 0 or not os.path.exists(obj):
            say("编译失败：", "err")
            print(out[-2500:])
            return 3
        say(f"      产物 {os.path.getsize(obj)} 字节", "ok")
    else:
        say(f"不支持的输入类型：{ext}（支持 .o / .swift）", "err")
        return 2

    # ---------- 2. 链接 ----------
    say("[2/5] 链接", "step")
    exe = os.path.join(work, name)
    swift_lib = os.path.join(sdk, "usr", "lib", "swift")
    cmd = [ld, "-arch", "arm64", "-platform_version", "ios", "17.0", "26.5",
           "-syslibroot", sdk, "-o", exe, obj,
           "-L" + swift_lib, "-L" + os.path.join(sdk, "usr", "lib"),
           "-lswiftCore", "-lswiftFoundation",
           "-framework", "UIKit", "-framework", "Foundation"]
    rc, out = run(cmd)
    if rc != 0 or not os.path.exists(exe):
        say("链接失败：", "err")
        print(out[-2500:])
        return 4
    # 过滤「版本号偏高」这类无害警告
    for line in out.splitlines():
        if "warning" in line.lower() and "newer than target" not in line:
            say(line.strip(), "warn")

    # ---------- 3. UI 入口校验（黑屏防线）----------
    say("[3/5] 校验 UI 入口", "step")
    if not nm_has_symbol(exe, "UIApplicationMain"):
        say("缺少 UIApplicationMain —— 这会让 app 黑屏/闪退", "err")
        say("原因：源码里没有 UIApplicationMain，或链接漏了 -framework UIKit", "warn")
        return 5
    say("      UIApplicationMain ✓", "ok")

    # ---------- 4. 组装 + 签名 ----------
    say("[4/5] 组装 app 包并签名", "step")
    app = os.path.join(work, name + ".app")
    os.makedirs(app, exist_ok=True)
    shutil.copy2(exe, os.path.join(app, name))
    os.chmod(os.path.join(app, name), 0o755)

    ent = os.path.join(ROOT, "registry", "ent.plist")
    info = {
        "CFBundleExecutable": name,
        "CFBundleIdentifier": bundle_id,
        "CFBundleName": name,
        "CFBundleDisplayName": name,
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "1.0",
        "MinimumOSVersion": "17.0",
        "UIDeviceFamily": [1],
    }
    # 手工拼 plist，避免依赖 plistlib 的格式差异
    items = "\n".join(
        f"  <key>{k}</key>\n  <array><integer>{v[0]}</integer></array>"
        if isinstance(v, list) else
        f"  <key>{k}</key>\n  <string>{v}</string>"
        for k, v in info.items())
    with open(os.path.join(app, "Info.plist"), "w", encoding="utf-8") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?>\n'
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
                '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                '<plist version="1.0">\n<dict>\n' + items + '\n</dict>\n</plist>\n')

    sign_cmd = [ldid, "-S" + ent, os.path.join(app, name)] if os.path.exists(ent) \
        else [ldid, "-S", os.path.join(app, name)]
    rc, out = run(sign_cmd)
    if rc != 0:
        say("签名失败：" + out[-600:], "err")
        return 6
    say("      签名 ✓", "ok")

    # ---------- 5. 打包 ----------
    say("[5/5] 打包", "step")
    tipa = os.path.join(outdir, name + ".tipa")
    if os.path.exists(tipa):
        os.remove(tipa)
    with zipfile.ZipFile(tipa, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(app):
            for fn in files:
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, work)
                z.write(full, os.path.join("Payload", rel))
    say(f"      {os.path.getsize(tipa)/1024:.1f} KB", "ok")
    shutil.rmtree(work, ignore_errors=True)

    print()
    say(f"完成：{tipa}", "ok")
    say("用 TrollStore 打开该文件即可安装", "info")
    return 0


def check():
    tools = load_registry()
    total = len(tools)
    okc = 0
    print(f"NanoCode 工具链  {C_DIM}({BASE}){C_END}")
    print("-" * 46)
    for k, v in tools.items():
        p = os.path.join(BASE, v.get("probe", {}).get("file", ""))
        ok = os.path.exists(p)
        okc += ok
        mark = C_OK + "✓" + C_END if ok else C_NO + "✗" + C_END
        print(f"  {mark} {k:<14} {v.get('description',''):<20} {v.get('size','?')}")
    print("-" * 46)
    if okc == total:
        say(f"{okc}/{total} 就绪，可以构建", "ok")
        return 0
    say(f"{okc}/{total} 就绪，缺 {total-okc} 项", "warn")
    say("运行 sh tc.sh install 下载缺失工具", "info")
    return 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Swift → tipa 构建流水线")
    ap.add_argument("source", nargs="?", help="Swift 源文件")
    ap.add_argument("--name", default="App", help="app 名（默认 App）")
    ap.add_argument("--bundle-id", default=None, help="bundle id")
    ap.add_argument("--out", default=None, help="输出目录")
    ap.add_argument("--check", action="store_true", help="只检查工具链")
    a = ap.parse_args()

    if a.check or not a.source:
        sys.exit(check())

    bid = a.bundle_id or ("com.nanocode." + a.name.lower().replace(" ", ""))
    outdir = a.out or os.path.join(ROOT, "out")
    os.makedirs(outdir, exist_ok=True)
    sys.exit(build(a.source, a.name, bid, outdir))
