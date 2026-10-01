# Accessibility audit

Day 7, 29/09. The plan asked for "an accessibility audit with findings, rather than a claim in
a table". This is that audit: how it was run, what it found, what changed, and what it does
not cover.

## Method

Apple's `performAccessibilityAudit` run against the real app, not a checklist ticked by hand.
It checks contrast, Dynamic Type support, clipped text, hit regions, element labels and
traits.

A discovery version of `AccessibilityAuditUITests` visited every screen a user can reach:
sign-in, registration, the board with a space selected, the deposit sheet, and all four
outcome sheets. It did this three times: light mode, dark mode, and the largest accessibility
text size (`AccessibilityXXXL`). It recorded every issue without failing. The findings were
then triaged against screenshots from the same runs, because the audit's summary alone was
not enough. It reported "clipped text" at the default size on screens that looked fine, and
missed some contrast failures that computing the ratios exposed.

Contrast was then measured directly: the WCAG 2.x ratio for every palette colour against
the surface or fill it actually sits on.

**Result:** 53 distinct findings on the first run. After the fixes below: none that fail,
plus nine accepted exceptions, each with a written reason.

## Findings and fixes

| # | Finding | Evidence | Fix |
|---|---|---|---|
| F1 | **Outcome sheets unreadable at large sizes.** Title, message and detail each cut to one line: "Space 7 look…", "It's showing yo…" | Screenshot, largest size | Sheets size to their content (`fitsContentDetent`); above `.large` they open full height and scroll (`scrollsAtLargeText`) |
| F2 | **The ambiguous outcome truncated at the default size.** "…or whether either of…" | Screenshot, default size | Same fix. A fixed 380pt was too short for the longest copy, at any text size |
| F3 | **Header lost information at large sizes.** Plate shown as "TE…", the balance amount gone from its pill, the menu off screen | Screenshot | Plate on its own line at accessibility sizes; the wallet's 34pt height became a minimum |
| F4 | **Banner and stats truncated.** "Reservatio…", "60 free at last…", "TAK…", "TOT…" | Screenshot | At accessibility sizes portrait scrolls as one column (`accessibleLayout`) instead of squeezing every row, and the stats stack as rows |
| F5 | **Content scrolled over the status bar** once F4 made the column scroll | Screenshot | The scroll view is clipped to the safe area |
| F6 | **Every primary button failed contrast in dark mode.** White on the brightened tints: amber 1.67, available green 1.88, blue 2.54, red 2.77 | Measured | Button text is near-black in dark mode (`Palette.onTint`), 7.0 to 11.7:1 |
| F7 | **Light-mode colours below 4.5:1 where they carry text.** Green "Done" button 3.53; a held space's gold number on its fill 2.97; "Taken" count 3.06; balance pill 4.44 | Measured | available `1B9C5B`→`15803D` (5.02), mine `B8860B`→`8C6508` (4.81), reserved `8A94A6`→`6B7588` (4.64; dark `6B7688`→`7C8699`, 4.76), accent `2563EB`→`1D4ED8` (5.75 on its fill) |
| F8 | **Outcome icon read as its symbol name.** "checkmark circle badge questionmark", before the outcome itself | Audit | Decorative, so hidden from VoiceOver; the title says it in words |
| F9 | **Deposit amount ignored Dynamic Type.** Fixed 30pt and 38pt | Audit | `@ScaledMetric`: the same sizes at default, scaling from there |
| F10 | **Deposit presets truncated to "$…"** at large sizes | Screenshot | 2×2 above `.large` instead of four across |

The default-size layout is unchanged by all of this. `BoardGeometryUITests` measures the
6.1-inch board at the same 265.7–725.7pt extent, 44pt targets and 80 cells visible as
before, in English and in Vietnamese.

## A fix that turned out to do nothing

The header's wallet and menu are drawn at 34pt, below the 44pt target. Making them 44pt would
take ten points of height from the board, so a modifier was written to grow only their hit
area. A test tapping just outside the drawn edge passed. It kept passing with the modifier
removed.

Probing showed why. iOS already accepts taps on these buttons up to 10pt outside their drawn
edge (none at 14pt), which makes the effective target at least 54pt. The modifier was
deleted. The test stays, at 5pt outside (what a 44pt target requires), as a guard against a
future overlay or layout change taking that margin away.

## Accepted, with reasons

Each exception in `AccessibilityAuditUITests.accepted` names its audit type, element and
screen. The same kind of issue anywhere else still fails the test.

| Audit type | Where | Why it is not a defect |
|---|---|---|
| Contrast | Disabled "Sign in" and "Create account" | WCAG 1.4.3 exempts inactive controls; the faded state is the signal that the form is incomplete |
| Contrast | Board, largest size, no element | Text scrolled under the confirm bar's translucent material, the standard iOS treatment for content behind a bar |
| Text clipped | Behind the deposit and outcome sheets, no element | The board behind a part-height sheet, cut by the sheet's edge. It is outside the accessibility tree while the sheet is up; the sheet's own text fits |
| Text clipped | Password field | A secure field. Its placeholder fits at every size in the screenshots |
| Dynamic Type | Registration's Cancel | A system toolbar button; iOS limits toolbar text growth itself |
| Dynamic Type | Registration's field notes | The caption2 style, wrapping over four lines at the largest size in the screenshots. Reported as "partial" |
| Element detection | Legend, "$" in the amount field | Visible text VoiceOver skips on purpose: each cell's label already says free, taken or yours, and the field is labelled "Deposit amount in dollars" |

## How it stays true

- `AccessibilityAuditUITests` runs in `make uitest` and CI: three tours plus the hit-area
  guard.
- A mutation check: restoring white button text in dark mode makes `testAuditDark` fail, on
  exactly the sheets whose buttons it affects.
- `BoardGeometryUITests` re-asserts the 6.1-inch guardrail in both locales.

## A VoiceOver pass by a person

The audit checks that labels exist and are readable, not that the order and wording make sense
spoken aloud. On 01/10 I went through the app with VoiceOver on my iPhone, and found nothing
that needed changing.

## What this does not cover

- **A daily VoiceOver user.** The pass above was made by the developer. Someone who relies on
  VoiceOver would judge, for example, whether eighty spaces are quick enough to move through.
- **iPad and landscape.** The tours run in iPhone portrait only.
- **Vietnamese at large sizes.** Longer strings at the largest size were not audited.
- **Real devices.** The audits ran on the simulator; only the VoiceOver pass was on a phone.
