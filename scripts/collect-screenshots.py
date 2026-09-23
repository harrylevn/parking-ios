#!/usr/bin/env python3
"""Copy the named screenshot attachments out of an xcresult export into docs/screenshots.

`xcresulttool export attachments` writes opaque filenames plus a manifest that maps them to
the names the test gave each capture. Only attachments whose name looks like `NN-something`
are taken, so an incidental attachment never lands in the evidence folder.
"""
import json
import pathlib
import re
import shutil
import sys

source, destination = (pathlib.Path(p) for p in sys.argv[1:3])
manifest = json.loads((source / "manifest.json").read_text())
destination.mkdir(parents=True, exist_ok=True)

# Exported names carry the capture name plus an index and a UUID:
# "07-holding_0_9F3C....png". Only the leading NN-name part is wanted.
wanted = re.compile(r"^(\d{2}-[a-z-]+)_")
copied = []
for test in manifest:
    for attachment in test.get("attachments", []):
        match = wanted.match(attachment.get("suggestedHumanReadableName") or "")
        if not match:
            continue
        exported = source / attachment["exportedFileName"]
        target = destination / f"{match.group(1)}.png"
        shutil.copyfile(exported, target)
        copied.append(target.name)

for name in sorted(copied):
    print(f"  {name}")
print(f"{len(copied)} screenshots written to {destination}")
if not copied:
    sys.exit("no screenshots found — did the suite skip?")
