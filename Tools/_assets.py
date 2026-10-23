import json
import os
import pathlib

p = pathlib.Path(os.environ["TEMP"]) / "cx.json"
d = json.loads(p.read_text(encoding="utf-8"))
print("tag:", d.get("tag_name"))
for asset in d.get("assets", []):
    name = asset["name"]
    if "musl" in name or "aarch64" in name or "arm64" in name or "linux" in name:
        print(f"  {name:52s} {asset['size'] / 1048576:6.1f} MB")
