import json
import os
import time
import urllib.error
import urllib.request

TOKEN = os.environ["GH_TOKEN"]
REPO = "DooRoo666/NanoCode"
RUN_ID = os.environ.get("RUN_ID", "")


def api(path: str):
    req = urllib.request.Request("https://api.github.com" + path)
    req.add_header("Authorization", "Bearer " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    try:
        with urllib.request.urlopen(req, timeout=40) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read() or b"{}")
        except Exception:
            return {}


run_id = RUN_ID
if not run_id:
    runs = api(f"/repos/{REPO}/actions/runs?per_page=5").get("workflow_runs", [])
    picked = next((r for r in runs if not r["name"].startswith("smoke")), None)
    if not picked:
        raise SystemExit("no run found")
    run_id = str(picked["id"])

print(f"watching run {run_id}", flush=True)
last = ""
for attempt in range(100):  # ~3.5 hours at 130s
    run = api(f"/repos/{REPO}/actions/runs/{run_id}")
    jobs = api(f"/repos/{REPO}/actions/runs/{run_id}/jobs").get("jobs", [])
    lines = [f"{run.get('status')}/{run.get('conclusion')}"]
    for job in jobs:
        done = [s for s in job.get("steps", []) if s.get("conclusion") == "success"]
        running = [s for s in job.get("steps", []) if s.get("status") == "in_progress"]
        failed = [s for s in job.get("steps", []) if s.get("conclusion") == "failure"]
        lines.append(
            f"  {job['status']}/{job.get('conclusion')} ok={len(done)}"
            + (f" running={running[-1]['name']}" if running else "")
            + (f" FAILED={failed[-1]['name']}" if failed else "")
        )
    snapshot = "\n".join(lines)
    if snapshot != last:
        print(time.strftime("%H:%M:%S"), "|", snapshot.replace("\n", "\n"), flush=True)
        last = snapshot
    if run.get("status") == "completed":
        print("FINAL:", run.get("conclusion"), run.get("html_url"), flush=True)
        artifacts = api(f"/repos/{REPO}/actions/runs/{run_id}/artifacts").get("artifacts", [])
        for art in artifacts:
            print(f"  artifact: {art['name']} {art['size_in_bytes']/1048576:.1f} MB", flush=True)
        break
    time.sleep(130)
