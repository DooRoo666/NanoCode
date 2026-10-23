#!/usr/bin/env python3
"""对上游 nanoMuse 的 iOS 树打最小补丁（只改必要的几行，失败即报错）。

补丁一：首启向导把「用你自己的 API Key」提为主按钮，Cloud 登录降为次要。
        上游默认主按钮是 "Sign in · free"，Cloud 一挂（"nanoMuse Cloud 没有响应"）
        用户就卡在第一步——而自定义端点本来完全可用（AddProviderView + ModelsDevAPI）。

为什么要补丁而不是覆盖文件：这两个按钮块在 `NanoMuseFirstRun.swift` 内部，
没有扩展点；但改动是纯字符串交换，可逐字校验，比整文件替换安全。

    python3 Tools/patch_upstream.py --root upstream/android/src/ios
    python3 Tools/patch_upstream.py --root ... --check
"""

from __future__ import annotations

import argparse
import pathlib
import sys

FILE = "NanoMuse/NanoMuseFirstRun.swift"

WELCOME_OLD = '''            primaryLabel: AppLocalized("Sign in · free"),
            onPrimary: { showSignIn = true },
            secondaryLabel: AppLocalized("Use your own API key instead"),
            onSecondary: { NanoMuseFirstRun.markSourceChosen(); sourceChosen = true; showOwnKey = true },'''

WELCOME_NEW = '''            primaryLabel: AppLocalized("Use your own API key"),
            onPrimary: { NanoMuseFirstRun.markSourceChosen(); sourceChosen = true; showOwnKey = true },
            secondaryLabel: AppLocalized("Sign in to nanoMuse Cloud"),
            onSecondary: { showSignIn = true },'''

SOURCE_OLD = '''            primaryLabel: AppLocalized("Use the nanoMuse Cloud model"),
            onPrimary: { NanoMuseFirstRun.markSourceChosen(); sourceChosen = true },
            secondaryLabel: AppLocalized("I have my own API key"),
            onSecondary: { NanoMuseFirstRun.markSourceChosen(); sourceChosen = true; showOwnKey = true },'''

SOURCE_NEW = '''            primaryLabel: AppLocalized("I have my own API key"),
            onPrimary: { NanoMuseFirstRun.markSourceChosen(); sourceChosen = true; showOwnKey = true },
            secondaryLabel: AppLocalized("Use the nanoMuse Cloud model"),
            onSecondary: { NanoMuseFirstRun.markSourceChosen(); sourceChosen = true },'''

PATCHES = [("welcome page", WELCOME_OLD, WELCOME_NEW), ("source page", SOURCE_OLD, SOURCE_NEW)]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True, help="android/src/ios in the upstream checkout")
    ap.add_argument("--check", action="store_true", help="report without writing")
    args = ap.parse_args(argv)

    path = pathlib.Path(args.root) / FILE
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    text = path.read_text(encoding="utf-8")
    original = text
    for label, old, new in PATCHES:
        hits = text.count(old)
        if hits == 0 and new in text:
            print(f"  {label}: already patched")
            continue
        if hits != 1:
            print(f"error: {label} anchor found {hits} times (expected 1) — upstream changed shape", file=sys.stderr)
            return 3
        text = text.replace(old, new, 1)
        print(f"  {label}: patched (own key promoted to primary)")

    if args.check:
        print("check: would apply cleanly" if text != original else "check: nothing to do")
        return 0

    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
