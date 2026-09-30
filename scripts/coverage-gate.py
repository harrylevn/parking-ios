#!/usr/bin/env python3
"""Fail if unit-test coverage falls below its floor where the logic lives.

    scripts/coverage-gate.py <unit-tests.xcresult>

Gated by scope, not overall. The overall figure is mostly SwiftUI views, which the UI tests
exercise and this report does not count, so a single overall floor would reward padding tests
rather than testing logic. The floors sit a few points under the level measured when the gate
was introduced (30/09), so it catches a regression without failing on noise.

Floors can be overridden for a trial run: COVERAGE_FLOOR_DOMAIN=95 scripts/coverage-gate.py …
"""
import json
import os
import subprocess
import sys

FLOORS = {  # scope -> minimum line coverage, %
    "Domain": 90,         # measured 93.4
    "Data": 85,           # measured 91.8
    "View models": 80,    # measured 84.8 to 95.5
}


def scope_of(path, function):
    relative = path.split("/Sources/")[-1]
    if relative.startswith("Domain/"):
        return "Domain"
    if relative.startswith("Data/"):
        return "Data"
    # View models live beside their views; count their functions, not the views'.
    if relative.startswith("Features/") and "ViewModel" in function:
        return "View models"
    return None


bundle = sys.argv[1]
report = json.loads(subprocess.run(["xcrun", "xccov", "view", "--report", "--json", bundle],
                                   capture_output=True, text=True, check=True).stdout)
app = next(target for target in report["targets"] if target["name"] == "Parking.app")

covered = {scope: 0 for scope in FLOORS}
lines = {scope: 0 for scope in FLOORS}
for file in app["files"]:
    for function in file["functions"]:
        scope = scope_of(file["path"], function["name"])
        if scope:
            covered[scope] += function["coveredLines"]
            lines[scope] += function["executableLines"]

failed = False
print(f"unit-test coverage: {app['lineCoverage'] * 100:.1f}% overall (reported, not gated)")
for scope, floor in FLOORS.items():
    floor = float(os.environ.get(f"COVERAGE_FLOOR_{scope.upper().replace(' ', '_')}", floor))
    percent = 100 * covered[scope] / max(lines[scope], 1)
    ok = percent >= floor
    failed |= not ok
    print(f"  {scope:12s} {percent:5.1f}%  floor {floor:.0f}%  {'ok' if ok else 'BELOW THE FLOOR'}"
          f"  ({covered[scope]}/{lines[scope]} lines)")
if failed:
    sys.exit("Coverage fell below a floor: add tests for the new logic, or explain the drop.")
