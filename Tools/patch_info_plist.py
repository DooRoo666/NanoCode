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
    assert "filza" in (verify.get("LSApplicationQueriesSchemes") or []), "scheme missing after write"
    assert any(
        "public.data" in (item.get("LSItemContentTypes") or [])
        for item in verify.get("CFBundleDocumentTypes") or []
    ), "document type missing after write"
    print("info.plist: verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
