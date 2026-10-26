#!/usr/bin/env python3
"""把原版 MT-Agent 具备、而我们缺的 Info.plist 能力补到上游 Info.plist 上。

补两项（都可逐项校验，重复运行安全）：
  1. LSApplicationQueriesSchemes += filza      —— 原版用它探测 Filza（文件管理器）
  2. CFBundleDocumentTypes += public.data/content —— 原版能「用 MT Agent 打开任意文件」，
     上游只声明了 JSON 与 backup 两种

    python3 Tools/patch_info_plist.py --plist upstream/android/src/ios/Info.plist
"""

from __future__ import annotations

import argparse
import plistlib
import sys
from pathlib import Path

QUERY_SCHEMES = ["filza"]

# 独立身份：不改这三项，装出来就是 nanoMuse 本身（bundle id 相同 → 直接覆盖宿主 App）。
# 改成自己的 id / 名字后，两套 App 可以并存，互不覆盖、互不清数据。
BUNDLE_ID = "io.github.nanomuse.nanocodex"
DISPLAY_NAME = "NanoCodex"
BUNDLE_NAME = "NanoCodex"

DOC_TYPE = {
    "CFBundleTypeName": "nanoMuse Document",
    "CFBundleTypeRole": "Editor",
    "LSHandlerRank": "Alternate",
    "LSItemContentTypes": ["public.data", "public.content"],
}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--plist", required=True)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)

    path = Path(args.plist)
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    data = plistlib.loads(path.read_bytes())
    changed: list[str] = []

    schemes = data.get("LSApplicationQueriesSchemes") or []
    if not isinstance(schemes, list):
        schemes = []
    added = [s for s in QUERY_SCHEMES if s not in schemes]
    if added:
        data["LSApplicationQueriesSchemes"] = schemes + added
        changed.append(f"+LSApplicationQueriesSchemes {added}")

    if data.get("CFBundleIdentifier") != BUNDLE_ID:
        changed.append(f"CFBundleIdentifier {data.get('CFBundleIdentifier')} → {BUNDLE_ID}")
        data["CFBundleIdentifier"] = BUNDLE_ID
    if data.get("CFBundleDisplayName") != DISPLAY_NAME:
        changed.append(f"CFBundleDisplayName → {DISPLAY_NAME}")
        data["CFBundleDisplayName"] = DISPLAY_NAME
    if data.get("CFBundleName") != BUNDLE_NAME:
        changed.append(f"CFBundleName → {BUNDLE_NAME}")
        data["CFBundleName"] = BUNDLE_NAME

    # 顺手统一子标识：后台任务 id / 文档类型 / URL scheme 都带旧前缀，
    # 两个 App 并存时会撞 BGTaskScheduler 标识。
    def _rebrand(obj):
        if isinstance(obj, str):
            return obj.replace("io.github.nanomuse.app", BUNDLE_ID)
        if isinstance(obj, list):
            return [_rebrand(x) for x in obj]
        if isinstance(obj, dict):
            return {k: _rebrand(v) for k, v in obj.items()}
        return obj

    rebranded = _rebrand(data)
    if rebranded != data:
        changed.append("子标识（后台任务/文档类型/scheme）统一到新前缀")
        data = rebranded

    doc_types = data.get("CFBundleDocumentTypes") or []
    if not isinstance(doc_types, list):
        doc_types = []
    has_generic = any(
        isinstance(item, dict) and "public.data" in (item.get("LSItemContentTypes") or [])
        for item in doc_types
    )
    if not has_generic:
        data["CFBundleDocumentTypes"] = doc_types + [DOC_TYPE]
        changed.append("+CFBundleDocumentTypes public.data/public.content")

    if not changed:
        print("info.plist: already patched")
        return 0

    print("info.plist:", "; ".join(changed))
    if args.check:
        return 0

    path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False))

    verify = plistlib.loads(path.read_bytes())
    assert verify.get("CFBundleIdentifier") == BUNDLE_ID, "bundle id not applied"
    assert verify.get("CFBundleDisplayName") == DISPLAY_NAME, "display name not applied"
    assert "filza" in (verify.get("LSApplicationQueriesSchemes") or []), "scheme missing after write"
    assert any(
        "public.data" in (item.get("LSItemContentTypes") or [])
        for item in verify.get("CFBundleDocumentTypes") or []
    ), "document type missing after write"
    print("info.plist: verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
