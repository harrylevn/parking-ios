#!/usr/bin/env python3
"""Fail if the String Catalog has drifted from the code.

Run after `make build`, which leaves one .stringsdata per source file: the strings the
compiler found localisable. Syncs them into a scratch copy of the catalog and fails if
that changed anything (a string added in code but not in the catalog, or one the code no
longer uses), or if any key that should be translated has no Vietnamese.

`--write` syncs the real catalog instead; that is `make strings`.
"""
import glob, json, os, shutil, subprocess, sys, tempfile

CATALOG = "Sources/Resources/Localizable.xcstrings"
LOCALES = ["vi"]
STRINGSDATA = (".build/DerivedData/Build/Intermediates.noindex/Parking.build/"
               "Debug-iphonesimulator/Parking.build/Objects-normal/*/*.stringsdata")

def sync(catalog):
    data = glob.glob(STRINGSDATA)
    if not data:
        sys.exit("no .stringsdata found: run `make build` first")
    subprocess.run(["xcrun", "xcstringstool", "sync", catalog, "--stringsdata", *data], check=True)

def keys(path):
    return json.load(open(path))["strings"]

if "--write" in sys.argv:
    sync(CATALOG)
    print(f"synced {CATALOG}")
    sys.exit(0)

with tempfile.TemporaryDirectory() as tmp:
    scratch = os.path.join(tmp, "Localizable.xcstrings")
    shutil.copy(CATALOG, scratch)
    sync(scratch)
    before, after = keys(CATALOG), keys(scratch)

problems = []
for key in sorted(set(after) - set(before)):
    problems.append(f"in code, not in the catalog: {key!r}")
for key, entry in sorted(after.items()):
    if entry.get("extractionState") == "stale":
        problems.append(f"in the catalog, no longer in code: {key!r}")
for key, entry in sorted(before.items()):
    if entry.get("shouldTranslate") is False:
        continue
    for locale in LOCALES:
        if locale not in entry.get("localizations", {}):
            problems.append(f"no {locale} translation: {key!r}")

if problems:
    print("String Catalog is out of date (run `make strings`, then translate):")
    print("\n".join("  " + p for p in problems))
    sys.exit(1)
print(f"String Catalog in sync: {len(before)} keys, all translated into {', '.join(LOCALES)}")
