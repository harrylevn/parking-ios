# Performance evidence

The plan's day-9 item: an Instruments trace of the app under the grid poll and during a race,
kept as evidence for the Q&A.

## Method

`make trace` (`scripts/trace.sh`). It resets the backend and funds 150 synthetic rivals. A live
UI test signs the app in and leaves it on the board. Instruments' Time Profiler attaches to the
app for 40 seconds: 20 seconds idle under the 5-second poll, then all 150 rivals reserve at once,
50 at a time. `scripts/trace-summary.py` turns the trace into the numbers below, so they can be
re-derived rather than taken on trust.

Recorded 29/09 on the iOS 26.3 simulator (iPhone 17 Pro) on the development Mac. Of the 150
rivals, exactly 80 got a space and 70 lost: no overbooking.

## Results

| Measure | Value |
|---|---|
| App CPU, idle on the board | 11.5 ms per second, about 1% of one core: a 1–11 ms blip at each poll, nothing between |
| App CPU, from the race onwards | 4.8 ms per second on average |
| The race itself | 188 ms, then 64 ms, in the second one poll saw all 80 spaces go taken at once |
| Longest continuous main-thread run | **25 ms**, as those 80 cells changed: one dropped frame at 60 Hz, at most |
| Hangs and hang risks (Instruments) | none |
| Whole trace | 318 ms of CPU in 40 s, 192 ms of it on the main thread |

What this supports in review:

- **The poll costs almost nothing.** The publish-only-on-change diffing (`GridViewModel.refresh`,
  ADR-004) means an unchanged board does no work: a poll that returns the same 80 cells is a
  network round trip and a comparison.
- **The busiest moment is also brief.** Every cell changing in one poll is the worst case the
  board can meet, and it costs one frame.

## Caveats

- **Simulator, not a device.** CPU figures from a Mac-hosted simulator are not an iPhone's;
  the shape (idle near zero, one short burst) is the evidence, not the milliseconds.
- **150 rivals, not 1,000.** The client sees the board, not the load. What changes the client's
  work is how many cells change per poll, and 80 in one poll is already the maximum.
- **Mostly unsymbolicated.** About 70% of main-thread samples have no symbol, which is common
  for simulator system frameworks. What is named is Core Animation (14%), app code (5%) and
  SwiftUI (3%).

## The first trace measured the test, not the app

The first recording showed a steady 75 ms of CPU a second, idle. Almost none of it was the
app's code. The named frames were accessibility snapshots: the UI test driver was in
`waitForExistence`, which polls the app's accessibility tree continuously, and the app answers
each poll on its main thread. The driver now sleeps instead of waiting on an element, and the
idle figure fell from 75 ms a second to 11. A trace is only evidence of what was actually
running, and a UI test that queries the app is running too.
