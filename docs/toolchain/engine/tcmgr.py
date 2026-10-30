#!/usr/bin/env python3
"""NanoCode 工具链管理器：注册表驱动，本体零内置"""
import json, os, subprocess, sys

ROOT = os.environ.get("NANOCODE_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.environ.get("NANOCODE_BASE") or os.path.join(ROOT, "tools")
REG  = os.environ.get("NANOCODE_REGISTRY") or os.path.join(ROOT, "registry", "tools.json")

def load():
    with open(REG, encoding="utf-8") as f:
        return json.load(f)

def probe_file(t):
    p = t.get("probe", {}).get("file")
    return os.path.join(BASE, p) if p else None

def ready(t):
    p = probe_file(t)
    return bool(p and os.path.exists(p))

def cmd_list(only_missing=False):
    d = load(); tools = d.get("tools", {})
    print(f"NanoCode 工具链  ({BASE})")
    print("-" * 52)
    miss = 0
    for k, t in tools.items():
        ok = ready(t)
        if only_missing and ok:
            continue
        mark = "\u2713" if ok else "\u2717"
        if not ok: miss += 1
        print(f"  {mark} {k:<14} {t.get('description',''):<26} {t.get('size','?')}")
    print("-" * 52)
    print(f"缺失 {miss} 项" if miss else "全部就绪 \u2713")
    return 0

def cmd_path(name):
    d = load(); t = d.get("tools", {}).get(name)
    if not t: print(f"未知工具: {name}", file=sys.stderr); return 1
    p = probe_file(t) or ""
    print(p); return 0 if os.path.exists(p) else 1

def cmd_install(name):
    d = load(); t = d.get("tools", {}).get(name)
    if not t: print(f"未知工具: {name}", file=sys.stderr); return 1
    if ready(t):
        print(f"  {name} 已就绪，跳过"); return 0
    inst = t.get("install", {})
    if not inst.get("urls") and not inst.get("url"):
        print(f"  {name}: 注册表没有配置下载地址", file=sys.stderr); return 1
    print(f"  → 安装 {name} ({t.get('size','?')})")
    cmd = [sys.executable, os.path.join(ROOT, "engine", "fetch.py"), "--install", name]
    r = subprocess.run(cmd)
    return r.returncode

def main():
    a = sys.argv[1:]
    if not a or a[0] in ("-h", "--help"):
        print(__doc__); print("用法: tc.sh list|status|install <name>|install-all|verify|path <name>")
        return 0
    c = a[0]
    if c == "list":   return cmd_list(False)
    if c == "status": return cmd_list(True)
    if c == "install":
        return cmd_install(a[1]) if len(a) > 1 else (print("需要工具名"), 1)[1]
    if c == "install-all":
        d = load(); rc = 0
        for k, t in d.get("tools", {}).items():
            if t.get("required") and not ready(t):
                rc |= cmd_install(k)
        return rc
    if c == "verify":
        d = load(); bad = 0
        for k, t in d.get("tools", {}).items():
            if not ready(t): continue
            p = probe_file(t)
            if t.get("kind") == "bin":
                os.chmod(p, 0o755)
                r = subprocess.run([p, "--version"], capture_output=True, timeout=20)
                ok = r.returncode == 0 or b"version" in (r.stdout + r.stderr).lower()
                print(f"  {'\u2713' if ok else '\u2717'} {k}")
                bad += 0 if ok else 1
            else:
                print(f"  \u2713 {k} (数据)")
        return 1 if bad else 0
    if c == "path":
        return cmd_path(a[1]) if len(a) > 1 else 1
    print(f"未知命令: {c}", file=sys.stderr); return 1

if __name__ == "__main__":
    sys.exit(main())
