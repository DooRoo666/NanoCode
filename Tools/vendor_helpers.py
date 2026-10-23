"""把原版 MT-Agent 的 Helpers 抽到 vendor/helpers：
   - 真实文件按原相对路径落盘
   - 符号链接记进 _symlinks.txt（link<TAB>target），构建时用 ln -s 还原
"""

from __future__ import annotations

import stat
import zipfile
from pathlib import Path

TIPA = Path(r"C:\Users\Administrator\Desktop\Ai智能体\MT-Agent-v1.0.2-Lite.tipa")
OUT = Path(r"C:\Users\Administrator\Desktop\NanoCode\vendor\helpers")
PREFIX = "Payload/CodexApp.app/Helpers/"


def main() -> int:
    zf = zipfile.ZipFile(TIPA)
    files = 0
    links = 0
    total = 0
    link_lines: list[str] = []

    for info in zf.infolist():
        name = info.filename
        if not name.startswith(PREFIX) or name.endswith("/"):
            continue
        rel = name[len(PREFIX):]
        if not rel:
            continue
        mode = (info.external_attr >> 16) & 0xFFFF
        if stat.S_ISLNK(mode):
            target = zf.read(info).decode(errors="replace").strip()
            link_lines.append(f"{rel}\t{target}")
            links += 1
            continue

        data = zf.read(info)
        dest = OUT / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        files += 1
        total += len(data)

    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "_symlinks.txt").write_text("\n".join(link_lines) + "\n", encoding="utf-8")

    print(f"真实文件 {files} 个，合计 {total / 1048576:.2f} MB；符号链接 {links} 个")
    print("\n最大的 8 个文件：")
    rows = sorted(((p, p.stat().st_size) for p in OUT.rglob("*") if p.is_file()), key=lambda x: -x[1])[:8]
    for path, size in rows:
        print(f"  {size / 1048576:7.2f} MB  {path.relative_to(OUT)}")
    print("\n链接示例：")
    for line in link_lines[:12]:
        print("  ", line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
