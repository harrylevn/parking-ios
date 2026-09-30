# Final checkpoint

Everything for the final presentation, kept apart from the week-1 checkpoint
([`../slides.md`](../slides.md), [`../presentation.md`](../presentation.md)), which stay as the
record of what was said then.

| File | What it is | Use it |
|---|---|---|
| [`slides.md`](slides.md) | The deck, same format as week 1 | On screen |
| [`speaker-notes.md`](speaker-notes.md) | What to say on each slide, and the time budget | Beside you |
| [`demo-script.md`](demo-script.md) | The 20 live minutes: pre-flight, every command, a fallback for each step | Terminal 3 |
| [`qa-prep.md`](qa-prep.md) | Likely questions on the trade-offs and scale, with short answers | Before the day |
| [`images/`](images/) | Screenshots the slides use, and the fallbacks | If a live step fails |

The structure the brief asks for: **10** minutes architecture, **20** live on the simulator (the
interface and its state matrix, then the races), **10** security, CI and the AI workflow, **20**
questions.

## Commands the demo uses

| Command | Shows |
|---|---|
| `scripts/demo.sh app` · `countdown` · `account` · `fill` · `freeze` / `thaw` · `unknown` · `reset` | One interface state each, on the simulator |
| `make rehearse` | Gate proved on, then won, lost and killed races, checked against the database |
| `make concurrent` | Two users confirming the same space at the same instant, API and two simulators |
| `make pinning-demo` | The right pin connects; a wrong pin is refused before anything is sent |
| `make device-config` then Run in Xcode | The app on the real iPhone |

## Images

| File | Shows |
|---|---|
| `concurrent-won.png`, `concurrent-lost.png` | The two simulators after tapping 1 ms apart; the loser in Vietnamese and dark mode |
| `race-won.png`, `race-lost.png`, `race-killed.png` | The three rehearsals |
| `pinning-refused.png` | A wrong pin, refused |
| `board-vietnamese.png` | The board in the second locale |
| `outcome-largest-text-before.png`, `outcome-largest-text.png` | The accessibility fix: an outcome sheet at the largest text size, before and after |
