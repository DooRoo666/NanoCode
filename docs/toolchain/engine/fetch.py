#!/usr/bin/env python3
"""NanoCode 工具下载器

特性：
  - 多镜像源自动回退（GitHub / jsDelivr / 自定义）
  - 断点续传（.part 文件）
  - SHA256 校验
  - 实时进度显示
  - 失败自动换下一个源
  - 归档自动解包（zip / tar / zst，含 tar.zst）

用法：
  fetch.py --url <URL> [--url <URL2>...] --dest <目录> --save-as <相对路径>
           [--type file|archive] [--archive zip|tar|zst|zst-single]
           [--sha256 <hash>] [--skip-prefix <前缀>] [--strip-prefix <目录>]
           [--executable]
  fetch.py --url <URL> <目标文件>      # 简写：直接下载到某文件
  fetch.py --install <工具名>          # 从注册表安装（内部使用）
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zipfile

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
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
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
    if not urls:
        return False, "没有可用下载地址"
    for i, u in enumerate(urls, 1):
        src = u.split("/")[2] if "://" in u else u
        print(f"  [{i}/{len(urls)}] {src}")
        ok, msg = download_one(u, dest, expect_sha)
        if ok:
            print(f"   {OK} 完成 {msg}")
            return True
        print(f"   {ERR} {msg}")
    return False


# ---------------------------------------------------------------- 解包


def _is_tar(path):
    try:
        with open(path, "rb") as f:
            return f.read(512)[257:262] == b"ustar"
    except Exception:
        return False


def extract_zip(archive, dest, skip=(), strip=None):
    """逐条目解包，跳过冗余目录；strip 指定时去掉顶层目录前缀"""
    with zipfile.ZipFile(archive) as z:
        members = []
        for info in z.infolist():
            name = info.filename
            if any(name.startswith(p) for p in skip):
                continue
            if strip:
                if name.startswith(strip + "/"):
                    name = name[len(strip) + 1:]
                elif name == strip:
                    continue
                else:
                    # 顶层目录里没有这个文件，跳过（避免结构错乱）
                    continue
            if not name or name.endswith("/"):
                continue
            info.filename = name
            members.append(info)
        if not members:
            raise RuntimeError("解包后没有任何文件（strip_prefix 可能配错）")
        z.extractall(dest, members=members)


def extract_tar(archive, dest):
    with tarfile.open(archive, "r:*") as t:
        t.extractall(dest)


def extract_zst(archive, dest, strip=None):
    """zstd 解压。产物可能是 tar（继续展开），也可能是裸目录树。"""
    tmp = archive + ".out"
    r = subprocess.run(["zstd", "-d", "-f", "-q", archive, "-o", tmp])
    if r.returncode != 0:
        raise RuntimeError("zstd 解压失败")
    try:
        if _is_tar(tmp):
            extract_tar(tmp, dest)
        else:
            # 裸文件/目录树：直接搬进 dest
            if os.path.isdir(tmp):
                shutil.copytree(tmp, dest, dirs_exist_ok=True)
            else:
                os.makedirs(dest, exist_ok=True)
                shutil.copy2(tmp, os.path.join(dest, os.path.basename(archive)))
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def move_strip(dest, strip):
    """解包后把 dest/strip/* 提升到 dest/（当 strip 未在解包阶段处理时）"""
    inner = os.path.join(dest, strip)
    if not os.path.isdir(inner):
        return
    for item in os.listdir(inner):
        shutil.move(os.path.join(inner, item), os.path.join(dest, item))
    shutil.rmtree(inner, ignore_errors=True)


# ---------------------------------------------------------------- 安装


def install_spec(spec):
    """按结构化描述安装一个工具。

    spec = {
      urls: [str], dest: 目录, save_as: 相对路径,
      type: 'file'|'archive', archive: 'zip'|'tar'|'zst'|'zst-single',
      sha256, skip_prefixes: [], strip_prefix, executable: bool
    }
    """
    urls = spec.get("urls") or []
    dest_dir = spec.get("dest") or BASE
    save_as = spec.get("save_as") or ""
    dest = os.path.join(dest_dir, save_as) if save_as else dest_dir
    os.makedirs(dest_dir, exist_ok=True)

    tmpdl = os.path.join("/tmp", os.path.basename(save_as or "tool") + ".dl")
    if not download(urls, tmpdl, spec.get("sha256")):
        return False

    ok = True
    try:
        if spec.get("type", "file") == "file":
            os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
            shutil.move(tmpdl, dest)
        else:
            kind = spec.get("archive", "zip")
            os.makedirs(dest, exist_ok=True)
            skip = tuple(spec.get("skip_prefixes", ["__MACOSX/"]))
            strip = spec.get("strip_prefix")
            if kind == "zip":
                extract_zip(tmpdl, dest, skip=skip, strip=strip)
            elif kind == "tar":
                extract_tar(tmpdl, dest)
            elif kind == "zst":
                extract_zst(tmpdl, dest, strip=strip)
            elif kind == "zst-single":
                r = subprocess.run(["zstd", "-d", "-f", "-q", tmpdl, "-o", dest])
                if r.returncode != 0:
                    raise RuntimeError("zstd 解压失败")
            else:
                extract_tar(tmpdl, dest)
            if strip and os.path.isdir(os.path.join(dest, strip)):
                move_strip(dest, strip)
    except Exception as e:
        print(f"   {ERR} 解包失败：{e}")
        ok = False
    finally:
        if os.path.exists(tmpdl):
            os.remove(tmpdl)

    if ok and spec.get("executable"):
        try:
            os.chmod(dest, 0o755)
        except Exception:
            pass
    return ok


def load_tools():
    with open(REG, encoding="utf-8") as f:
        return json.load(f)["tools"]


def build_urls(reg, inst):
    """解析下载地址：注册表里的绝对 urls 优先，否则相对 sources 拼接"""
    if inst.get("urls"):
        return list(inst["urls"])
    url = inst.get("url")
    if not url:
        return []
    if "://" in url:
        return [url]
    srcs = reg.get("sources", {}).get("default", [])
    return [s.rstrip("/") + "/" + url.lstrip("/") for s in srcs]


def install(name):
    with open(REG, encoding="utf-8") as f:
        reg = json.load(f)
    t = reg["tools"].get(name)
    if not t:
        print(f"{ERR} 未知工具：{name}")
        return 2
    inst = t.get("install", {})
    urls = build_urls(reg, inst)
    if not urls:
        print(f"{WARN} 该工具没有配置下载地址")
        print(f"   {inst.get('hint', '请手动放入 ' + BASE)}")
        return 2

    print(f"==> 安装 {t.get('label', name)}  ({t.get('size', '?')})")
    spec = {
        "urls": urls,
        "dest": BASE,
        "save_as": inst.get("saveAs", "bin/" + name),
        "type": inst.get("type", "file"),
        "archive": inst.get("archive", "zip"),
        "sha256": inst.get("sha256"),
        "skip_prefixes": inst.get("skip_prefixes", ["__MACOSX/"]),
        "strip_prefix": inst.get("strip_prefix"),
        "executable": inst.get("executable", True),
    }
    if not install_spec(spec):
        return 1
    print(f"{OK} {name} 安装完成")
    return 0


# ---------------------------------------------------------------- CLI


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    if args[0] == "--install":
        if len(args) < 2:
            print("用法: fetch.py --install <工具名>")
            return 2
        return install(args[1])

    if args[0] != "--url":
        print("未知参数", file=sys.stderr)
        return 2

    # 解析 --url 可重复（args[0] 本身就是第一个 --url）
    urls, i = [args[1]], 2
    while i < len(args) and args[i] == "--url":
        if i + 1 >= len(args):
            print("--url 缺值", file=sys.stderr)
            return 2
        urls.append(args[i + 1])
        i += 2
    if not urls:
        print("至少需要一个 --url", file=sys.stderr)
        return 2

    opts = {}
    pos = []
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            key = a[2:]
            if key in ("executable", "verbose"):
                opts[key] = True
                i += 1
            else:
                if i + 1 >= len(args):
                    print(f"参数 {a} 缺值", file=sys.stderr)
                    return 2
                opts[key] = args[i + 1]
                i += 2
        else:
            pos.append(a)
            i += 1

    # 简写：fetch.py --url URL <目标文件>
    if pos and not opts.get("dest"):
        dest = pos[0]
        if not download(urls, dest, opts.get("sha256")):
            return 1
        return 0

    dest_dir = opts.get("dest", BASE)
    save_as = opts.get("save-as", "")
    spec = {
        "urls": urls,
        "dest": dest_dir,
        "save_as": save_as,
        "type": opts.get("type", "file"),
        "archive": opts.get("archive", "zip"),
        "sha256": opts.get("sha256"),
        "skip_prefixes": opts.get("skip-prefix", "").split(",") if opts.get("skip-prefix") else ["__MACOSX/"],
        "strip_prefix": opts.get("strip-prefix"),
        "executable": opts.get("executable", True),
    }
    if not install_spec(spec):
        return 1
    print(f"{OK} 完成 → {os.path.join(dest_dir, save_as)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
