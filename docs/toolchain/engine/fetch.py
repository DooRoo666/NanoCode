#!/usr/bin/env python3
"""NanoCode 工具下载器

特性：
  - 多镜像源自动回退（GitHub / jsDelivr / 自定义）
  - 断点续传（.part 文件）
  - SHA256 校验
  - 实时进度显示
  - 失败自动换下一个源

用法：
  python3 fetch.py <tool-name>          # 下载注册表里的工具
  python3 fetch.py --url <URL> <目标>    # 直接下载
"""
import hashlib
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.environ.get("NANOCODE_BASE", os.path.join(ROOT, "tools"))
REG = os.environ.get("NANOCODE_REGISTRY", os.path.join(ROOT, "registry", "tools.json"))

OK = "\033[32m✓\033[0m"
ERR = "\033[31m✗\033[0m"
WARN = "\033[33m!\033[0m"


def human(n):
    for u in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f}{u}"
        n /= 1024
    return f"{n:.1f}TB"


def progress(done, total, t0):
    if total <= 0:
        return
    pct = done * 100.0 / total
    speed = done / max(time.time() - t0, 0.001)
    bar_n = 28
    fill = int(bar_n * pct / 100)
    bar = "█" * fill + "░" * (bar_n - fill)
    sys.stdout.write(
        f"\r   {bar} {pct:5.1f}%  {human(done)}/{human(total)}  {human(speed)}/s   "
    )
    sys.stdout.flush()


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download_one(url, dest, expect_sha=None, timeout=30):
    """单源下载，支持断点续传。返回 (ok, msg)"""
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    part = dest + ".part"

    resume_at = os.path.getsize(part) if os.path.exists(part) else 0
    req = urllib.request.Request(url, headers={"User-Agent": "NanoCode/1.0"})
    if resume_at:
        req.add_header("Range", f"bytes={resume_at}-")

    try:
        resp = urllib.request.urlopen(req, timeout=timeout)
    except urllib.error.HTTPError as e:
        if e.code == 416:  # 已完整下载
            resp = None
        else:
            return False, f"HTTP {e.code}"
    except Exception as e:
        return False, str(e)[:80]

    total = 0
    mode = "ab"
    if resp is not None:
        clen = int(resp.headers.get("Content-Length") or 0)
        if resp.status == 206:
            total = resume_at + clen
        else:
            total = clen
            resume_at = 0
            mode = "wb"

    t0 = time.time()
    done = resume_at
    try:
        with open(part, mode) as f:
            if resp is not None:
                while True:
                    chunk = resp.read(1 << 16)
                    if not chunk:
                        break
                    f.write(chunk)
                    done += len(chunk)
                    progress(done, total, t0)
        sys.stdout.write("\n")
    except Exception as e:
        sys.stdout.write("\n")
        return False, f"传输中断: {str(e)[:60]}（可重试续传）"

    if expect_sha:
        got = sha256_of(part)
        if got.lower() != expect_sha.lower():
            os.remove(part)
            return False, f"SHA256 不匹配（期望 {expect_sha[:12]}… 实际 {got[:12]}…）"

    os.replace(part, dest)
    return True, human(os.path.getsize(dest))


def download(urls, dest, expect_sha=None):
    """多源依次尝试"""
    if isinstance(urls, str):
        urls = [urls]
    for i, u in enumerate(urls, 1):
        src = u.split("/")[2] if "://" in u else u
        print(f"  [{i}/{len(urls)}] {src}")
        ok, msg = download_one(u, dest, expect_sha)
        if ok:
            print(f"   {OK} 完成 {msg}")
            return True
        print(f"   {ERR} {msg}")
    return False


def load_tools():
    with open(REG, encoding="utf-8") as f:
        return json.load(f)["tools"]


def install(name):
    tools = load_tools()
    t = tools.get(name)
    if not t:
        print(f"{ERR} 未知工具：{name}")
        return 2

    print(f"==> 安装 {t['label']}  ({t.get('size', '?')})")
    inst = t.get("install", {})
    urls = inst.get("urls") or ([inst["url"]] if inst.get("url") else [])
    if not urls:
        print(f"{WARN} 该工具没有配置下载地址")
        print(f"   {inst.get('hint', '请手动放入 ' + BASE)}")
        return 2

    save_as = t.get("saveAs") or name
    dest = os.path.join(BASE, save_as)

    if "." in os.path.basename(save_as):
        # 单文件
        if not download(urls, dest, inst.get("sha256")):
            return 1
        if inst.get("executable") or save_as.endswith(("ld64", "ldid")):
            os.chmod(dest, 0o755)
    else:
        # 归档
        archive = os.path.join("/tmp", save_as + ".dl")
        if not download(urls, archive, inst.get("sha256")):
            return 1
        print(f"   解包 → {dest}")
        os.makedirs(dest, exist_ok=True)
        kind = inst.get("archive", "zip")
        if kind == "zip":
            import zipfile
            with zipfile.ZipFile(archive) as z:
                z.extractall(dest)
        elif kind == "zst":
            # .tar.zst → 先 zstd 解压成 tar，再展开
            tmp_tar = archive + ".tar"
            rc = os.system(f"zstd -d -f -q '{archive}' -o '{tmp_tar}'")
            if rc == 0:
                os.system(f"tar -xf '{tmp_tar}' -C '{dest}'")
                os.remove(tmp_tar)
            else:
                print("   ✗ zstd 解压失败")
                return 1
        elif kind == "tar":
            os.system(f"tar -xf '{archive}' -C '{dest}'")
        elif kind == "zst-single":
            # 单个文件的 zst 压缩，产物名 = saveAs
            rc = os.system(f"zstd -d -f -q '{archive}' -o '{dest}'")
            if rc != 0:
                print("   ✗ zstd 解压失败")
                return 1
        else:
            os.system(f"tar -xf '{archive}' -C '{dest}'")
        os.remove(archive)
        strip = inst.get("strip_prefix")
        if strip:
            inner = os.path.join(dest, strip)
            if os.path.isdir(inner):
                for item in os.listdir(inner):
                    shutil.move(os.path.join(inner, item), os.path.join(dest, item))
                shutil.rmtree(inner, ignore_errors=True)

    print(f"{OK} {name} 安装完成")
    return 0


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if args[0] == "--url":
        if len(args) < 3:
            print("用法: fetch.py --url <URL> <目标文件>")
            return 2
        return 0 if download(args[1], args[2]) else 1
    return install(args[0])


if __name__ == "__main__":
    sys.exit(main())
