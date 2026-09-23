#!/usr/bin/env python3
"""Copy the named screenshot attachments out of xcresult exports into docs/screenshots.

Usage: collect-screenshots.py DESTINATION SOURCE [SOURCE ...]

`xcresulttool export attachments` writes opaque filenames plus a manifest that maps them to
the names the test gave each capture, with an index and a UUID appended. Only attachments
whose name starts with `NN-something` are taken, so an incidental attachment never lands in
the evidence folder.
"""
import json
import pathlib
import re
import shutil
import sys

destination = pathlib.Path(sys.argv[1])
sources = [pathlib.Path(p) for p in sys.argv[2:]]
destination.mkdir(parents=True, exist_ok=True)

# "07-holding_0_9F3C....png" -> "07-holding"
wanted = re.compile(r"^(\d{2}-[a-z-]+)_")
copied = []

for source in sources:
    manifest = source / "manifest.json"
    if not manifest.exists():
        print(f"  (no manifest in {source})")
        continue
    for test in json.loads(manifest.read_text()):
        for attachment in test.get("attachments", []):
            match = wanted.match(attachment.get("suggestedHumanReadableName") or "")
            if not match:
                continue
            shutil.copyfile(
                source / attachment["exportedFileName"],
                destination / f"{match.group(1)}.png",
            )
            copied.append(f"{match.group(1)}.png")

for name in sorted(copied):
    print(f"  {name}")
print(f"{len(copied)} screenshots written to {destination}")
if not copied:
    sys.exit("no screenshots found — did the suite skip?")
