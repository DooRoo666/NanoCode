"""原版 MT-Agent 全量清单：79 条目、Info.plist 全键、字符串里的功能面。"""

from __future__ import annotations

import plistlib
import re
import zipfile
from pathlib import Path

TIPA = Path(r"C:\Users\Administrator\Desktop\Ai智能体\MT-Agent-v1.0.2-Lite.tipa")

# 想确认"有没有这个功能"的字符串线索
FEATURE_PROBES = [
    "Add provider", "Provider", "Sign in", "Sign In", "Sign out", "Account",
    "Terminal", "Shell", "Files", "Skills", "Subagent", "Agent", "MCP", "MCP server",
    "Settings", "Appearance", "Voice", "Microphone", "Camera", "Photo", "Image",
    "Model", "models", "Reasoning", "Thinking", "Approval", "Approve", "Deny",
    "Diff", "Patch", "Git", "Commit", "Branch", "Worktree", "Sandbox",
    "Mermaid", "mermaid", "Chart", "Markdown", "Table",
    "Share", "Widget", "Shortcut", "Notification", "Background",
    "WebSocket", "SSE", "Stream", "Upload", "Download",
    "Theos", "theos", "ldid", "codesign", "Entitlement", "entitlements",
    "Python", "Node", "npm", "pip", "Rust", "cargo", "Go build",
    "Token", "Usage", "Cost", "Context", "Compact",
]


def main() -> int:
    zf = zipfile.ZipFile(TIPA)
    names = zf.namelist()

    print("=== 全部 79 条目 ===")
    for n in sorted(names):
        info = zf.getinfo(n)
        kind = "DIR " if n.endswith("/") else f"{info.file_size:>9,}"
        print(f"  {kind}  {n}")

    print("\n=== Info.plist 全键 ===")
    for pn in [n for n in names if n.endswith(".app/Info.plist")]:
        info = plistlib.loads(zf.read(pn))
        for key in sorted(info):
            value = info[key]
            text = str(value)
            if len(text) > 220:
                text = text[:220] + "…"
            print(f"  {key} = {text}")

    # 主二进制字符串里的功能面
    main_bin = "Payload/CodexApp.app/CodexApp"
    if main_bin in names:
        data = zf.read(main_bin)
        print(f"\n=== 功能字符串探针 @ 主二进制（{len(data)/1048576:.1f} MB）===")
        for probe in FEATURE_PROBES:
            hits = data.count(probe.encode())
            if hits:
                print(f"  {probe:22s} {hits}")

    # 资源文件内容抽样
    for suffix, label in [
        ("Mermaid/", "Mermaid 目录"),
        ("codex-fallback-prompt.md", "fallback prompt"),
        ("cacert.pem", "CA 证书"),
        ("models.json", "模型表"),
        ("entitlements.plist", "内嵌权限"),
    ]:
        matches = [n for n in names if suffix in n]
        if not matches:
            continue
        print(f"\n=== {label}（{len(matches)} 项）===")
        for n in matches[:6]:
            info = zf.getinfo(n)
            if not n.endswith("/"):
                print(f"  {info.file_size:>9,} B  {n}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
