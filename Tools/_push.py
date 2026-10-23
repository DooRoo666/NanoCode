import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

TOKEN = os.environ.get("GH_TOKEN") or ""
if not TOKEN:
    sys.exit("GH_TOKEN missing")
REPO = "NanoCode"
API = "https://api.github.com"


def call(method: str, path: str, payload: dict | None = None):
    data = json.dumps(payload).encode() if payload else None
    req = urllib.request.Request(API + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode(errors="replace")
        try:
            return exc.code, json.loads(body)
        except Exception:
            return exc.code, {"raw": body[:400]}


status, me = call("GET", "/user")
if status != 200:
    sys.exit(f"token rejected ({status}): {me.get('message')}")
login = me.get("login")
print("account:", login, "|", me.get("email"))

# 先探权限：fine-grained token 少了 Contents:write 时 git push 只会给一句 403
import base64

probe_status, probe = call("PUT", f"/repos/{login}/{REPO}/contents/_perm_probe.txt",
                           {"message": "permission probe",
                            "content": base64.b64encode(b"probe").decode()})
if probe_status in (200, 201):
    call("DELETE", f"/repos/{login}/{REPO}/contents/_perm_probe.txt",
         {"message": "cleanup", "sha": probe["content"]["sha"]})
    print("contents write: OK")
else:
    print(f"contents write: DENIED ({probe_status}) {probe.get('message')}")
    print("-> token 需要 Permissions → Contents: Read and write")
    sys.exit(2)

status, repo = call("GET", f"/repos/{login}/{REPO}")
if status == 404:
    print(f"repo {login}/{REPO} missing -> creating (private)")
    status, repo = call("POST", "/user/repos", {"name": REPO, "private": True,
                                                "description": "nanoMuse + Codex overlay, TrollStore TIPA"})
    if status not in (200, 201):
        print(f"  create failed ({status}): {repo.get('message')}")
        print("  -> 请在网页上手动建一个空仓库，然后重跑")
        sys.exit(1)
    print("  created:", repo.get("html_url"))
else:
    print("repo exists:", repo.get("html_url"), "| default_branch:", repo.get("default_branch"))

url = f"https://x-access-token:{TOKEN}@github.com/{login}/{REPO}.git"
push = subprocess.run(["git", "push", url, "HEAD:refs/heads/main"], cwd=r"C:\Users\Administrator\Desktop\NanoCode",
                      capture_output=True, text=True)
print("push rc:", push.returncode)
for line in (push.stdout + push.stderr).splitlines()[:6]:
    print("  ", line.replace(TOKEN, "<redacted>"))

if push.returncode == 0:
    status, runs = call("GET", f"/repos/{login}/{REPO}/actions/runs?per_page=3")
    if status == 200:
        items = runs.get("workflow_runs", [])
        if not items:
            print("no workflow run yet (may need a few seconds)")
        for run in items[:3]:
            print(f"run: {run.get('name')} | {run.get('status')}/{run.get('conclusion')} | {run.get('html_url')}")
