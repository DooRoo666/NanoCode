"""原版 MT-Agent 深度清单：Helpers 工具链、内嵌权限、模型表、主二进制能力标记。"""

from __future__ import annotations

import plistlib
import re
import zipfile
from pathlib import Path

TIPA = Path(r"C:\Users\Administrator\Desktop\Ai智能体\MT-Agent-v1.0.2-Lite.tipa")

MARKERS = [
    b"codex", b"app-server", b"openai", b"anthropic", b"OPENAI_API_KEY",
    b"python", b"node", b"theos", b"clang", b"ldid", b"ptrace", b"posix_spawn",
    b"execve", b"dlopen", b"mcp", b"websocket", b"chat/completions", b"terminal",
    b"iSH", b"alpine", b"NSFileProvider", b"UserNotifications", b"approval",
    b"gpt-5", b"sandbox", b"subprocess", b"socket", b"ssh", b"git",
]


def is_macho(head: bytes) -> bool:
    return head in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe")


def main() -> int:
    zf = zipfile.ZipFile(TIPA)
    names = zf.namelist()

    print("=== Helpers（内嵌工具链）===")
    helpers = sorted(n.split("Helpers/")[-1] for n in names if "Helpers/" in n and n.split("Helpers/")[-1])
    for item in helpers:
        print("  ", item)
    print(f"  共 {len(helpers)} 项")

    print("\n=== PlugIns ===")
    for n in names:
        if "/PlugIns/" in n and n.count("/") == 4:
            print("  ", n)

    print("\n=== 内嵌 entitlements.plist（原版自带）===")
    ent = [n for n in names if n.endswith(".app/entitlements.plist")]
    for e in ent:
        try:
            data = plistlib.loads(zf.read(e))
            for key, value in data.items():
                print(f"   {key} = {value!r}")
        except Exception as exc:
            print("   解析失败:", exc)

    print("\n=== codex-version.txt ===")
    for n in names:
        if n.endswith("codex-version.txt"):
            print("  ", zf.read(n).decode(errors="replace").strip()[:200])

    print("\n=== models.json（模型表，前 400 字符）===")
    for n in names:
        if n.endswith("models.json"):
            print("  ", zf.read(n).decode(errors="replace")[:400].replace("\n", " "))

    # 主二进制 = 最大的 Mach-O
    machos = []
    for info in zf.infolist():
        if info.filename.endswith("/"):
            continue
        if is_macho(zf.read(info.filename)[:4]):
            machos.append((info.filename, info.file_size))
    machos.sort(key=lambda x: -x[1])
    print("\n=== 全部 Mach-O（按体积）===")
    for name, size in machos:
        print(f"  {size / 1048576:7.2f} MB  {name}")

    if machos:
        main_name = machos[0][0]
        data = zf.read(main_name)
        print(f"\n=== 能力标记 @ {main_name} ({len(data) / 1048576:.1f} MB) ===")
        for marker in MARKERS:
            count = data.count(marker)
            if count:
                print(f"    {marker.decode():22s} {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
