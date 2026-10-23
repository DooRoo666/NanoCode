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
        return 0 if rc == 0 else rc

    if text != original:
        path.write_text(text, encoding="utf-8")
        print(f"wrote {path}")

    rc = patch_providers_json(pathlib.Path(args.root), check_only=False)
    if rc != 0:
        return rc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
