"""检查原版 Helpers 的真实类型与用法线索。"""

from __future__ import annotations

import zipfile
from pathlib import Path

TIPA = Path(r"C:\Users\Administrator\Desktop\Ai智能体\MT-Agent-v1.0.2-Lite.tipa")
WANT = [
    "Helpers/codex-sign",
    "Helpers/ca-filetool",
    "Helpers/theos-helper",
    "Helpers/bash-codex",
    "Helpers/TheosCompat/cp",
    "Helpers/TheosCoreCompat/mkdir",
]


def kind(data: bytes) -> str:
    if data[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        return "Mach-O (arm64/x86_64)"
    if data[:2] == b"#!":
        return "脚本: " + data[:60].split(b"\n")[0].decode(errors="replace")
    return f"其它 (magic={data[:4]!r})"


def main() -> int:
    zf = zipfile.ZipFile(TIPA)
    names = zf.namelist()
    for suffix in WANT:
        match = next((n for n in names if n.endswith(suffix)), None)
        if not match:
            print(f"{suffix:34s} 未找到")
            continue
        data = zf.read(match)
        print(f"{suffix:34s} {len(data):>9,} B  {kind(data)}")

    # codex-sign 的用法线索
    sign = next((n for n in names if n.endswith("Helpers/codex-sign")), None)
    if sign:
        blob = zf.read(sign)
        print("\n=== codex-sign 里的用法字符串 ===")
        import re
        for pattern in (rb"usage[^\x00]{0,120}", rb"--[a-z][a-z0-9-]{2,24}", rb"entitlements?[^\x00]{0,60}"):
            hits = sorted({m.group(0).decode(errors="replace") for m in re.finditer(pattern, blob, re.I)})[:12]
            for h in hits:
                print(f"  {h[:110]}")

    # theos-helper 若是脚本则打印全文前 60 行
    helper = next((n for n in names if n.endswith("Helpers/theos-helper")), None)
    if helper:
        blob = zf.read(helper)
        print(f"\n=== theos-helper ({len(blob)} B) 前 40 行 ===")
        for line in blob.decode(errors="replace").splitlines()[:40]:
            print("  " + line[:160])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
