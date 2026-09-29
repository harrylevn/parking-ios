#!/usr/bin/env python3
"""Summarise a Time Profiler trace of the app from scripts/trace.sh.

Prints the app's CPU per second, split at the race (20 s in by default), the main thread's
share, what that main-thread time was spent on, and whether Instruments found any hangs.

    scripts/trace-summary.py .build/trace/board-YYYYMMDD-HHMMSS.trace [race-second]
"""
import collections
import subprocess
import sys
import xml.etree.ElementTree as ET

trace = sys.argv[1]
race_at = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0


def export(schema):
    xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
    out = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath", xpath],
                         capture_output=True, text=True, check=True).stdout
    return ET.fromstring(out)


# xctrace interns repeated values: the first occurrence carries an id, later ones a ref.
ids = {}


def resolve(element):
    ref = element.get("ref")
    if ref:
        return ids[ref]
    if element.get("id"):
        ids[element.get("id")] = element
    for child in element:
        resolve(child)
    return element


def category(frames):
    text = " | ".join(frames)
    if any(k in text for k in ("ccessib", "AXRuntime", "XCTAutomation", "UserTestingSnapshot")):
        return "accessibility queries (from the test driver)"
    if any(k in text for k in ("GridViewModel", "BoardView", "SpaceCell", "DashboardView",
                               "CountdownHero", "HTTPClient", "ServerClock", "OutcomeSheet")):
        return "app code"
    if any(k in text for k in ("AttributeGraph", "SwiftUI", "ViewGraph")):
        return "SwiftUI"
    if any(k in text for k in ("CA::", "QuartzCore")):
        return "Core Animation"
    return "unsymbolicated / other"


per_second = collections.defaultdict(float)
main_total = 0.0
main_by_category = collections.Counter()
windows = {"idle": 0.0, "race": 0.0}
start = None
for row in export("time-profile").iter("row"):
    cells = {cell.tag: resolve(cell) for cell in row}
    thread = cells["thread"].get("fmt", "")
    if "Parking" not in thread:
        continue
    seconds = int(cells["sample-time"].text) / 1e9
    weight = int(cells["weight"].text) / 1e6
    start = seconds if start is None else min(start, seconds)
    per_second[int(seconds)] += weight
    windows["race" if seconds >= race_at else "idle"] += weight
    if "Main Thread" in thread:
        main_total += weight
        backtrace = cells.get("backtrace")
        frames = [f.get("name") or "" for f in backtrace.iter("frame")] if backtrace is not None else []
        main_by_category[category(frames)] += weight

length = max(per_second) + 1 if per_second else 0
idle_seconds = max(race_at - (start or 0), 1)
race_seconds = max(length - race_at, 1)
print(f"trace: {trace}")
print(f"CPU per second (ms): " + " ".join(f"{s}:{v:.0f}" for s, v in sorted(per_second.items())))
print(f"idle, before {race_at:.0f} s: {windows['idle'] / idle_seconds:.1f} ms of CPU per second "
      f"({windows['idle'] / idle_seconds / 10:.1f}% of one core)")
print(f"race, after {race_at:.0f} s:  {windows['race'] / race_seconds:.1f} ms of CPU per second "
      f"({windows['race'] / race_seconds / 10:.1f}% of one core)")
print(f"main thread: {main_total:.0f} ms of {sum(windows.values()):.0f} ms")
for name, value in main_by_category.most_common():
    print(f"  {value:7.0f} ms  {100 * value / max(main_total, 1):5.1f}%  {name}")
for schema in ("potential-hangs", "hang-risks"):
    try:
        rows = len(list(export(schema).iter("row")))
    except subprocess.CalledProcessError:
        rows = "n/a"
    print(f"{schema}: {rows}")
