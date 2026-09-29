#!/usr/bin/env python3
"""Copy named screenshots out of an .xcresult bundle as PNGs.

    scripts/export-screenshots.py <bundle.xcresult> <out-dir> <prefix> [name-prefix]

Every attachment whose name starts with name-prefix (default: all) is written to
<out-dir>/<prefix>-<attachment name>.png. Used by scripts/concurrent.sh to keep each device's
result for slides.
"""
import json
import shutil
import subprocess
import sys
import tempfile

bundle, out, prefix = sys.argv[1:4]
wanted = sys.argv[4] if len(sys.argv) > 4 else ""

with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle,
                    "--output-path", tmp], capture_output=True, check=True)
    for test in json.load(open(f"{tmp}/manifest.json")):
        for item in test.get("attachments", []):
            name = (item.get("suggestedHumanReadableName") or "").split("_")[0]
            if name.startswith(wanted) and item["exportedFileName"].endswith(".png"):
                target = f"{out}/{prefix}-{name}.png"
                shutil.copy(f"{tmp}/{item['exportedFileName']}", target)
                print(target)
