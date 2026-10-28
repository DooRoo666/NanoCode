#!/usr/bin/env python3
"""校验 tipa 包内可写运行时根（Runtimes/）的权限与属主。

用法: python3 Tools/check_tipa_perms.py <file.tipa>

关注点：
  * 目录条目必须存在（zip 只对有内容的目录写条目，所以我们塞了 .keep）
  * mode 必须是 0777 —— TrollStore 以 root 解包，仅靠属主不够用
  * uid/gid 必须是 501 —— 来自 Info-ZIP 的 0x7875 扩展字段
"""
import struct
import sys
import zipfile

ROOT = "Payload/Minis.app/Runtimes/"
WANT = [ROOT, ROOT + "toolchains/", ROOT + "frameworks/", ROOT + "sdks/"]


def unix_owner(info):
    uid = gid = None
    extra, j = info.extra, 0
    while j + 4 <= len(extra):
        hid, hln = struct.unpack("<HH", extra[j:j + 4])
        body = extra[j + 4:j + 4 + hln]
        if hid == 0x7875 and len(body) >= 3:
            uid = int.from_bytes(body[2:2 + body[1]], "little")
            gid = int.from_bytes(body[3 + body[1]:], "little")
        j += 4 + hln
    return uid, gid


def main(path):
    z = zipfile.ZipFile(path)
    info = {i.filename: i for i in z.infolist()}
    bad = []
    for name in WANT:
        item = info.get(name)
        if item is None:
            bad.append(f"{name} 缺失（目录没有内容时 zip 不写条目，需要 .keep）")
            continue
        mode = (item.external_attr >> 16) & 0o7777
        uid, gid = unix_owner(item)
        flag = "OK" if mode == 0o777 and uid in (None, 501) else "FAIL"
        print(f"{flag:4} {name[len('Payload/Minis.app/'):]:28} "
              f"mode={mode:04o} uid={uid} gid={gid}")
        if mode != 0o777:
            bad.append(f"{name} 模式 {mode:04o} != 0777")
        if uid not in (None, 501):
            bad.append(f"{name} 属主 {uid} != 501")
    if bad:
        print("\n可写运行时根校验失败:", file=sys.stderr)
        for b in bad:
            print("  - " + b, file=sys.stderr)
        return 1
    print("\nRuntimes/ 可写校验通过（0777 / 501:501）")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
