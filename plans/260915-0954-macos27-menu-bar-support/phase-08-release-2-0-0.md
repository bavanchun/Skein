---
phase: 8
title: "Release 2.0.0"
status: pending
priority: P1
effort: "1d"
dependencies: [1, 2, 3, 4, 5, 6, 7]
---

# Phase 8: Release 2.0.0

## Goal

Run the full macOS 27 QA matrix, document permissions and recovery, bump to 2.0.0, and hand the maintainer a merged build ready to tag.

## Context

- Release mechanics: `docs/release-guide.md` (bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `Skein.xcodeproj/project.pbxproj`, currently `1.4.0` / `1140` in the two Skein app configurations). Tags are cut only by the maintainer after explicit approval (Step 6).
- `CHANGELOG.md` uses `## [x.y.z] - YYYY-MM-DD` with Added / Changed / Fixed and compare links at the bottom.
- The repository is public. QA evidence (screenshots, dumps, logs) stays in `.ci-output/`; the committed QA report contains only pass/fail and counts, no bundle identifiers.

## Tasks

### Task 8.1 — Branch

- Steps: `git switch main && git pull --ff-only && git switch -c release/2.0.0`.
- Verify: `git branch --show-current` prints `release/2.0.0`.

### Task 8.2 — QA matrix

- Steps: install with `Scripts/run-dev.sh`, run every row on macOS 27, and write `plans/260915-0954-macos27-menu-bar-support/reports/qa-2.0.0.md` as a table `| # | Scenario | Result |` with `pass` or `fail` and no identifiers. Keep evidence under `.ci-output/qa/`.

| # | Scenario | Displays |
|---|---|---|
| 1 | Hidden section click toggle | 1800 notched alone |
| 2 | Hidden section click toggle | LG 3008 alone |
| 3 | Hidden section click toggle | ARZOPA 1080 portrait alone |
| 4 | Hidden + always-hidden, all displays | all |
| 5 | Always-hidden disabled: no extra gap, nothing pushed | main |
| 6 | Hot-plug LG while hidden: still hidden, self-test honored | all |
| 7 | Hotkey, hover, scroll, empty-space click toggles | main |
| 8 | Items pushed past the notch reachable in `«` and clickable | 1800 |
| 9 | Menu Bar Layout: visible and hidden images, always-hidden placeholders | main |
| 10 | Search finds and opens a hidden item; section conceals afterwards | main |
| 11 | Skein Bar mode: click a hidden item opens its menu; conceals afterwards | main |
| 12 | Drag 3 items, Apply once, relaunch persists | main |
| 13 | Close pane with pending changes: prompt, Discard leaves table unchanged | main |
| 14 | Drop into a one-item section | main |
| 15 | Apply refused while a menu is open; moves kept | main |
| 16 | Restore newest backup from Advanced settings | main |
| 17 | Screen Recording revoked: hide/show works, message shown, no prompt | main |
| 18 | Full Disk Access revoked: banner, bars disabled, onboarding unchanged | main |
| 19 | Hide application menus still hides overlapping app menus | main |
| 20 | Menu bar appearance split shape covers the items | main |
| 21 | Item spacing change relaunches affected apps | main |
| 22 | No capture indicator left in the menu bar | main |

- Verify: `grep -c "| pass |" plans/260915-0954-macos27-menu-bar-support/reports/qa-2.0.0.md` prints `22` AND `grep -cE "com\.|pl\.|ru\.|org\." plans/260915-0954-macos27-menu-bar-support/reports/qa-2.0.0.md` prints `0`.

### Task 8.3 — Documentation

- Target files: `README.md`, `FREQUENT_ISSUES.md`, `CHANGELOG.md`.
- Steps:
  1. README: add a "macOS 27" subsection: Accessibility required; Screen Recording required for Menu Bar Layout, search and Skein Bar images; Full Disk Access required to rearrange items; applying a new layout reloads the menu bar once after confirmation; layout backups live in Advanced settings.
  2. FREQUENT_ISSUES:
     - "Items do not hide on macOS 27": enable section dividers, check the item is left of the divider, and `CollapseUnitOverride` (only lowers the length).
     - "Menu bar layout looks wrong after rearranging": Advanced → Menu Bar Layout Backups → Restore. Last resort, in a Terminal with Full Disk Access: `defaults delete "$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar" TrailingItemPreferredPositions && killall MenuBarAgent`.
     - "Spacers appeared left of the divider" (only when spike `LEGACY_SEED=no`): one-time Cmd-drag.
  3. CHANGELOG: `## [2.0.0] - <today>` — Added (macOS 27 support, layout backups, macOS 27 Full Disk Access banner), Changed (Screen Recording required for images on macOS 27; applying a layout on macOS 27 reloads the menu bar after confirmation), Fixed (hidden sections do not hide on macOS 27; empty Menu Bar Layout on macOS 27). Add `[2.0.0]: https://github.com/bavanchun/Skein/compare/v1.4.0...v2.0.0` and update `[Unreleased]`.
- Verify: `grep -c "## \[2.0.0\]" CHANGELOG.md` prints `1` AND `grep -c "macOS 27" README.md` prints ≥ 1 AND `grep -c "TrailingItemPreferredPositions" FREQUENT_ISSUES.md` prints `1`.

### Task 8.4 — Version bump

- Target files: `Skein.xcodeproj/project.pbxproj` (the two Skein app configurations only).
- Steps: set `MARKETING_VERSION = 2.0.0;` and `CURRENT_PROJECT_VERSION = 2000;` on the two lines currently `1.4.0` / `1140`; leave `MenuBarItemService` at `1.0` / `1`.
- Verify: `grep -c "MARKETING_VERSION = 2.0.0;" Skein.xcodeproj/project.pbxproj` prints `2` AND `grep -c "CURRENT_PROJECT_VERSION = 2000;" Skein.xcodeproj/project.pbxproj` prints `2`.

### Task 8.5 — Final gates and PR

- Steps: Release build; commit `release: 2.0.0 — macOS 27 menu bar support`; push; PR; wait for CI.
- Verify: Release build prints `** BUILD SUCCEEDED **` AND `gh pr checks --watch --required` exits 0.

### Task 8.6 — Hand off to the maintainer

- Steps: after merge, stop. Comment on the PR with the QA report path and "Ready for tag v2.0.0 per docs/release-guide.md Step 6". Do not tag, archive or publish the appcast.
- Verify: `gh pr view --json state -q .state` prints `MERGED`.

## Rollback

- A regression found after merge and before tagging: revert the offending phase PR on a branch with `git revert` and PR it; do not tag until QA passes again.

## Failure Protocol
If any Verify step does not meet its stated pass condition, STOP this phase.
Do not improvise a fix, retry blindly, or reason around the failure.
Spawn the `kongming` subagent for next-step counsel and pass:
- the phase and task id,
- what you attempted (the steps you ran),
- the exact command and its full output,
- the pass condition it failed to meet.
Apply kongming's guidance, then re-run the Verify step.
If `kongming` cannot be spawned in this environment, STOP and report the same
failure evidence to the user. Never continue by self-reasoning.
