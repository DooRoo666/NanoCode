"""从 TIPA/IPA 主二进制的代码签名里抽出嵌入的 entitlements 并列出键。

不依赖 ldid/codesign：直接在 Mach-O 里找签名块里的 XML plist。
"""

from __future__ import annotations

import plistlib
import re
import sys
import zipfile
from pathlib import Path

XML_START = re.compile(rb"<\?xml|<plist")


def main_binary(zf: zipfile.ZipFile) -> str:
    cands = [n for n in zf.namelist() if n.startswith("Payload/") and n.count("/") == 2]
    # 主可执行文件通常与 .app 同名
    for name in cands:
        app, exe = name.split("/")[1], name.split("/")[2]
        if app.endswith(".app") and exe == app[:-4]:
            return name
    return cands[0]


def extract_entitlements(data: bytes) -> list[dict[str, object]]:
    """返回每个含 entitlements 的 plist（可能有多个签名块）。"""
    found: list[dict[str, object]] = []
    for match in XML_START.finditer(data):
        start = match.start()
        end = data.find(b"</plist>", start)
        if end < 0:
            continue
        blob = data[start : end + len(b"</plist>")]
        if b"entitlements" not in blob and b"application-identifier" not in blob and b"platform-application" not in blob:
            continue
        try:
            parsed = plistlib.loads(blob)
        except Exception:
            continue
        if isinstance(parsed, dict) and parsed:
            found.append(parsed)
    return found


def report(path: Path) -> set[str]:
    with zipfile.ZipFile(path) as zf:
        exe = main_binary(zf)
        data = zf.read(exe)
    print(f"\n=== {path.name} ===")
    print(f"  binary: {exe} ({len(data) / 1048576:.1f} MB)")
    blobs = extract_entitlements(data)
    if not blobs:
        print("  !! 没有任何 entitlements plist —— 这份包是「无签名/无权限」状态")
        return set()
    keys: set[str] = set()
    for blob in blobs:
        for key, value in blob.items():
            keys.add(key)
            print(f"    {key} = {value!r}")
    print(f"  keys: {len(keys)}")
    return keys


def main() -> int:
    paths = [Path(p) for p in sys.argv[1:]]
    sets = {}
    for p in paths:
        sets[p.name] = report(p)
    if len(sets) == 2:
        (a, ka), (b, kb) = sets.items()
        print(f"\n=== 差异 ===\n  {a} 独有: {sorted(ka - kb)}")
        print(f"  {b} 独有: {sorted(kb - ka)}")
        print(f"  共有: {len(ka & kb)} / {len(ka | kb)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
