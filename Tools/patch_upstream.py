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

# 本地自建端点（ollama / LM Studio / vLLM）对普通用户是噪音：它们要求在本机跑服务，
# 而需求是"填 Key → 在线拉模型 → 选模型"。数据在 providers.json 里，改数据比改 Swift 安全。
LOCAL_PROVIDER_IDS = ("ollama", "lm-studio", "vllm", "litellm", "llamacpp")

CUSTOM_NAME = "自定义 API（Key + 地址）"
CUSTOM_NOTE = "填入 API Key 与接口地址（通常以 /v1 结尾）。保存后可在模型页在线获取模型列表再挑选。"
CUSTOM_NOTE_ZH = "填入 API Key 与接口地址（通常以 /v1 结尾）。保存后可在模型页在线拉取模型列表再挑选。"

PROVIDERS_JSON = "NanoMuse/Resources/providers.json"

# ---- Codex 接入点（三处）----------------------------------------------------
TOOL_DEFS_FILE = "Agent/Chat/AIChatViewModel+ToolDefinitions.swift"
TOOL_DEFS_ANCHOR = "        var tools: [AgentToolDefinition] = [\n"
TOOL_DEFS_INSERT = "            NanoMuseCodexTool.definition,\n"

TOOL_DISPATCH_FILE = "Agent/Chat/AIChatViewModel+ConcurrentTools.swift"
TOOL_DISPATCH_ANCHOR = '        case "shell_execute":\n'
TOOL_DISPATCH_INSERT = '''        case "codex_exec":
            let codexPrompt = (toolArgs["prompt"] as? String) ?? ""
            let codexWorkspace = (toolArgs["workspace"] as? String) ?? "/root/work"
            let codexTimeout = TimeInterval((toolArgs["timeout"] as? Int) ?? 900)
            if codexPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                toolOutput = "Error: missing required 'prompt' parameter."
                toolSuccess = false
            } else {
                let outcome = await NanoMuseCodexTool.execute(
                    prompt: codexPrompt,
                    workspace: codexWorkspace,
                    timeout: codexTimeout
                )
                toolOutput = outcome.text
                toolSuccess = outcome.exitCode == 0
            }

'''

SETTINGS_FILE = "NanoMuse/NanoMuseSettings.swift"
SETTINGS_ANCHOR = "            agentCard\n            phoneCard\n"
SETTINGS_INSERT = "            agentCard\n            codexCard\n            phoneCard\n"


def _insert(root: pathlib.Path, rel: str, anchor: str, insert: str, label: str,
            already: str, check_only: bool) -> int:
    """在 anchor 之后插入一段代码；已插入则跳过，找不到锚点就报错。"""
    path = root / rel
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 2
    text = path.read_text(encoding="utf-8")
    if already in text:
        print(f"  {label}: already wired")
        return 0
    if text.count(anchor) != 1:
        print(f"error: {label} anchor found {text.count(anchor)} times (expected 1)", file=sys.stderr)
        return 3
    print(f"  {label}: wired")
    if check_only:
        return 0
    path.write_text(text.replace(anchor, insert, 1), encoding="utf-8")
    return 0


SUBAGENT_DEFS_INSERT = (
    "            NanoMuseSubagentTool.dispatchDefinition,\n"
    "            NanoMuseSubagentTool.resultDefinition,\n"
)

SUBAGENT_DISPATCH_INSERT = '''        case "subagent_dispatch":
            let subPrompt = (toolArgs["prompt"] as? String) ?? ""
            let subWorkspace = (toolArgs["workspace"] as? String) ?? "/root/work"
            let subTimeout = TimeInterval((toolArgs["timeout"] as? Int) ?? 1800)
            if subPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                toolOutput = "Error: missing required 'prompt' parameter."
                toolSuccess = false
            } else {
                toolOutput = await NanoMuseSubagentTool.dispatch(
                    prompt: subPrompt,
                    workspace: subWorkspace,
                    timeout: subTimeout
                )
                toolSuccess = true
            }

        case "subagent_result":
            toolOutput = await NanoMuseSubagentTool.collect()
            toolSuccess = true

'''


def _insert_once(root: pathlib.Path, rel: str, anchor: str, marker: str, insert: str,
                 label: str, check_only: bool) -> int:
    """在 anchor 之后插入 insert；marker 已存在则视为已接线。"""
    path = root / rel
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 2
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"  {label}: already wired")
        return 0
    count = text.count(anchor)
    if count != 1:
        print(f"error: {label} anchor found {count} times (expected 1)", file=sys.stderr)
        return 3
    print(f"  {label}: wired")
    if check_only:
        return 0
    path.write_text(text.replace(anchor, anchor + insert, 1), encoding="utf-8")
    return 0


def patch_codex(root: pathlib.Path, check_only: bool) -> int:
    steps = [
        (TOOL_DEFS_FILE, TOOL_DEFS_ANCHOR, "NanoMuseCodexTool.definition",
         TOOL_DEFS_INSERT, "tool definition (codex_exec)"),
        (TOOL_DEFS_FILE, TOOL_DEFS_ANCHOR, "NanoMuseSubagentTool.dispatchDefinition",
         SUBAGENT_DEFS_INSERT, "tool definitions (subagent)"),
        (TOOL_DISPATCH_FILE, TOOL_DISPATCH_ANCHOR, 'case "codex_exec":',
         TOOL_DISPATCH_INSERT, "tool dispatch (codex_exec)"),
        (TOOL_DISPATCH_FILE, TOOL_DISPATCH_ANCHOR, 'case "subagent_dispatch":',
         SUBAGENT_DISPATCH_INSERT, "tool dispatch (subagent)"),
        (SETTINGS_FILE, SETTINGS_ANCHOR, "codexCard",
         SETTINGS_INSERT, "settings card (Codex)"),
    ]
    for rel, anchor, marker, insert, label in steps:
        rc = _insert_once(root, rel, anchor, marker, insert, label, check_only)
        if rc:
            return rc
    return 0


def patch_providers_json(root: pathlib.Path, check_only: bool) -> int:
    """去掉本地端点，把「自定义 API」提到第一位，并写清用法。"""
    import json

    path = root / PROVIDERS_JSON
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    data = json.loads(path.read_text(encoding="utf-8"))
    providers = data.get("providers")
    if not isinstance(providers, list):
        print("error: providers.json has no providers list", file=sys.stderr)
        return 3

    kept = [item for item in providers if item.get("id") not in LOCAL_PROVIDER_IDS]
    removed = len(providers) - len(kept)

    custom = next((item for item in kept if item.get("id") == "custom"), None)
    if custom is None:
        print("error: custom provider missing", file=sys.stderr)
        return 3

    custom["name"] = CUSTOM_NAME
    custom["name_zh"] = CUSTOM_NAME
    custom["note"] = CUSTOM_NOTE
    custom["note_zh"] = CUSTOM_NOTE_ZH
    custom["capabilities"] = custom.get("capabilities") or ["chat"]
    custom["user_capabilities"] = True

    reordered = [custom] + [item for item in kept if item.get("id") != "custom"]
    data["providers"] = reordered

    print(f"  providers.json: removed {removed} local endpoints, custom moved to first")
    if check_only:
        return 0

    path.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    # 回读校验：本地端点确实没了、custom 确实第一个
    verify = json.loads(path.read_text(encoding="utf-8"))
    ids = [item.get("id") for item in verify["providers"]]
    if any(bad in ids for bad in LOCAL_PROVIDER_IDS):
        print("error: local providers survived the rewrite", file=sys.stderr)
        return 4
    if ids[0] != "custom":
        print(f"error: custom is not first ({ids[0]})", file=sys.stderr)
        return 4
    print(f"  providers.json: {len(ids)} providers, first = custom")
    return 0


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
        rc = patch_providers_json(pathlib.Path(args.root), check_only=True)
        if rc:
            return rc
        return patch_codex(pathlib.Path(args.root), check_only=True)

    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"wrote {path}")

    rc = patch_providers_json(pathlib.Path(args.root), check_only=False)
    if rc:
        return rc
    return patch_codex(pathlib.Path(args.root), check_only=False)


if __name__ == "__main__":
    raise SystemExit(main())
