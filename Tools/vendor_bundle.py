"""把原版随包的资源抽到 vendor/bundle，构建时原样放进 App 根目录。"""

from __future__ import annotations

import zipfile
from pathlib import Path

TIPA = Path(r"C:\Users\Administrator\Desktop\Ai智能体\MT-Agent-v1.0.2-Lite.tipa")
OUT = Path(r"C:\Users\Administrator\Desktop\NanoCode\vendor\bundle")
PREFIX = "Payload/CodexApp.app/"

WANTED_PREFIXES = ("Mermaid/", "ThirdPartyNotices/")
WANTED_FILES = (
    "cacert.pem",
    "models.json",
    "codex-fallback-prompt.md",
    "codex-version.txt",
    "CA_NOTICE.txt",
    "entitlements.plist",
)


def main() -> int:
    zf = zipfile.ZipFile(TIPA)
    written = 0
    total = 0
    for info in zf.infolist():
        name = info.filename
        if not name.startswith(PREFIX) or name.endswith("/"):
            continue
        rel = name[len(PREFIX):]
        keep = rel in WANTED_FILES or rel.startswith(WANTED_PREFIXES)
        if not keep:
            continue
        dest = OUT / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        data = zf.read(info)
        dest.write_bytes(data)
        written += 1
        total += len(data)

    print(f"抽取 {written} 个资源，合计 {total / 1048576:.2f} MB → {OUT}")
    for p in sorted(OUT.rglob("*")):
        if p.is_file():
            print(f"  {p.stat().st_size:>9,} B  {p.relative_to(OUT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
