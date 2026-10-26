#!/usr/bin/env python3
"""把工程里的身份改成独立的 NanoCodex。

踩过的坑（这一版构建验证出来的）：
只改 Info.plist 完全没用——主 target 同时设置了
    PRODUCT_BUNDLE_IDENTIFIER = io.github.nanomuse.app
    INFOPLIST_KEY_CFBundleDisplayName = nanoMuse
Xcode 构建时会用这两个构建设置覆盖 Info.plist 里的同名字段，
所以产物里仍然是 nanoMuse 身份。
"""
from __future__ import annotations

import argparse
import pathlib
import sys

OLD_ID = "io.github.nanomuse.app"
NEW_ID = "io.github.nanomuse.nanocodex"
OLD_NAME = "INFOPLIST_KEY_CFBundleDisplayName = nanoMuse;"
NEW_NAME = "INFOPLIST_KEY_CFBundleDisplayName = NanoCodex;"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pbxproj", required=True, help="path to project.pbxproj")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)

    path = pathlib.Path(args.pbxproj)
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    text = path.read_text(encoding="utf-8")
    id_hits = text.count(OLD_ID)
    name_hits = text.count(OLD_NAME)
    print(f"  bundle id 待替换: {id_hits} 处（主 App + 扩展）")
    print(f"  显示名待替换: {name_hits} 处")

    if id_hits == 0 and NEW_ID not in text:
        print("error: 找不到 PRODUCT_BUNDLE_IDENTIFIER，拒绝静默通过", file=sys.stderr)
        return 3
    if name_hits == 0 and NEW_NAME not in text:
        print("error: 找不到 INFOPLIST_KEY_CFBundleDisplayName，拒绝静默通过", file=sys.stderr)
        return 4
    if args.check:
        return 0

    path.write_text(text.replace(OLD_ID, NEW_ID).replace(OLD_NAME, NEW_NAME), encoding="utf-8")

    verify = path.read_text(encoding="utf-8")
    assert OLD_ID not in verify, "bundle id 没替换干净"
    assert OLD_NAME not in verify, "显示名没替换干净"
    assert NEW_ID in verify and NEW_NAME in verify
    print("  ok: 工程身份已改为 NanoCodex")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
