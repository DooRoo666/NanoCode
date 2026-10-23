#!/usr/bin/env python3
"""把覆盖层文件接进 Minis.xcodeproj（不搬整个工程，只在 CI 里打补丁）。

Xcode 工程是显式文件表（278 KB 的 project.pbxproj），新增 Swift 文件必须同时写四处：
PBXBuildFile、PBXFileReference、所在 group 的 children、以及 target 的 Sources 阶段。
本脚本做这四处插入，幂等（已存在就跳过），失败会明确报错而不是产出一个坏工程。

    python Tools/apply_overlay.py --project android/src/ios/Minis.xcodeproj \
        --file android/src/ios/NanoMuse/NanoMuseCodexEngine.swift
    python Tools/apply_overlay.py ... --dry-run
"""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import sys

UUID_ALPHABET = "0123456789ABCDEF"


def uuid_for(text: str, salt: str) -> str:
    digest = hashlib.sha256(f"{salt}:{text}".encode()).digest()
    return "".join(UUID_ALPHABET[b % 16] for b in digest[:24])


def find_target_block(text: str, target: str) -> tuple[str, str]:
    match = re.search(r"([0-9A-F]{24}) /\* " + re.escape(target) + r" \*/ = \{\n\t\tisa = PBXNativeTarget;", text)
    if not match:
        raise SystemExit(f"target {target!r} not found in project.pbxproj")
    target_id = match.group(1)
    start = match.start()
    depth = 0
    for index in range(start, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return target_id, text[start : index + 1]
    raise SystemExit(f"unterminated block for target {target!r}")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True, help="path to X.xcodeproj")
    ap.add_argument("--file", required=True, help="the .swift file to add (path inside the tree)")
    ap.add_argument("--target", default="Minis")
    ap.add_argument("--group-hint", default="NanoMuse", help="group whose children get the file")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    project = pathlib.Path(args.project)
    pbxproj = project / "project.pbxproj"
    if not pbxproj.exists():
        raise SystemExit(f"no project.pbxproj under {project}")

    name = pathlib.Path(args.file).name
    if not name.endswith(".swift"):
        raise SystemExit(f"only .swift files: {name}")

    text = pbxproj.read_text(encoding="utf-8")
    if f"/* {name} */" in text and f"/* {name} in Sources */" in text:
        print(f"already wired: {name}")
        return 0

    # Xcode 16 的同步文件夹（PBXFileSystemSynchronizedRootGroup）会自动收录目录里的文件，
    # 这种情况不需要改工程——直接放进去就行，避免 278 KB pbxproj 的手术风险。
    sync_re = re.compile(
        r"/\* " + re.escape(args.group_hint) + r" \*/ = \{isa = PBXFileSystemSynchronizedRootGroup;",
    )
    if sync_re.search(text):
        print(f"{args.group_hint}/ is a synchronized root group: no pbxproj change needed")
        return 0

    file_id = uuid_for(name, "fileref")
    build_id = uuid_for(name, "buildfile")

    target_id, block = find_target_block(text, args.target)
    phases = re.search(r"buildPhases = \((.*?)\);", block, re.S)
    if not phases:
        raise SystemExit(f"target {args.target} has no buildPhases")
    sources_id = None
    for line in phases.group(1).splitlines():
        if "/* Sources */" in line:
            sources_id = line.strip().split()[0]
            break
    if not sources_id:
        raise SystemExit(f"target {args.target} has no Sources phase")

    # 1. PBXBuildFile
    build_entry = (
        f"\t\t{build_id} /* {name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
    )
    marker = "/* Begin PBXBuildFile section */\n"
    if marker not in text:
        raise SystemExit("PBXBuildFile section not found")
    text = text.replace(marker, marker + build_entry, 1)

    # 2. PBXFileReference
    ref_entry = (
        f"\t\t{file_id} /* {name} */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};\n'
    )
    marker = "/* Begin PBXFileReference section */\n"
    if marker not in text:
        raise SystemExit("PBXFileReference section not found")
    text = text.replace(marker, marker + ref_entry, 1)

    # 3. Sources phase
    phase_re = re.compile(re.escape(sources_id) + r" /\* Sources \*/ = \{\n\t\tisa = PBXSourcesBuildPhase;\n.*?files = \(\n", re.S)
    phase_match = phase_re.search(text)
    if not phase_match:
        raise SystemExit(f"Sources phase {sources_id} block not recognized")
    text = (
        text[: phase_match.end()]
        + f"\t\t\t\t{build_id} /* {name} in Sources */,\n"
        + text[phase_match.end() :]
    )

    # 4. group children
    group_re = re.compile(
        r"([0-9A-F]{24}) /\* " + re.escape(args.group_hint) + r" \*/ = \{\n\t\tisa = PBXGroup;\n.*?children = \(\n",
        re.S,
    )
    group_match = group_re.search(text)
    if not group_match:
        raise SystemExit(f"group {args.group_hint!r} not found")
    text = (
        text[: group_match.end()]
        + f"\t\t\t\t{file_id} /* {name} */,\n"
        + text[group_match.end() :]
    )

    if args.dry_run:
        print(f"dry-run OK: would add {name}")
        print(f"  fileRef={file_id} buildFile={build_id} target={target_id} sources={sources_id}")
        return 0

    pbxproj.write_text(text, encoding="utf-8")
    # 粗略一致性检查：四处插入都在，且括号仍然配平
    for fragment in (build_id, file_id, f"/* {name} in Sources */", f"path = {name};"):
        if fragment not in text:
            raise SystemExit(f"patch incomplete: {fragment!r} missing")
    if text.count("{") != text.count("}"):
        raise SystemExit("brace mismatch after patch (refusing to leave a broken project)")
    print(f"wired {name} into target {args.target} (sources {sources_id})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
