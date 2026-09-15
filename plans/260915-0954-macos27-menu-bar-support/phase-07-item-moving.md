---
phase: 7
title: "Item moving"
status: pending
priority: P1
effort: "2d"
dependencies: [4, 5, 6]
---

# Phase 7: Item moving

## Goal

On macOS 27, dragging items in Menu Bar Layout records moves that stay visible until the user applies or discards them, applying replays those moves on a fresh table with one confirmed MenuBarAgent restart, and the always-hidden divider order can be repaired on explicit confirmation.

## Context

- Drag handling: `Skein/UI/LayoutBar/LayoutBarPaddingView.swift:87-142` (`performDragOperation`, private `move(item:to:)` calls `itemManager.slowMove`).
- Moving today: `MenuBarItemManager.swift:1075` `move(item:to:)` synthesizes Cmd-drag events; `:1144` `slowMove`; `:1475` `enforceControlItemOrder`.
- `itemCache` is rebuilt every 5 s and on every running-applications change (`MenuBarItemManager.swift:176-199`), and the Layout Bar redraws from `$itemCache` (`Skein/UI/LayoutBar/LayoutBarContainer.swift:91-97`). Pending drags must survive those rebuilds.
- Writer: phase 6 `LayoutTableWriter.apply(_ moves:) -> ApplyResult`, which re-reads the table, backs it up, verifies on disk and rolls back on restart failure.
- Decisions: no synthetic Cmd-drag on macOS 27; batch changes; one restart per apply; every restart is confirmed by the user; Full Disk Access required for moving, checked with `LayoutTableFile.access()`.
- Items with `isGroupedIdentity = true` cannot be moved individually on macOS 27.

## Files to Create / Modify

| Action | Path | Purpose |
|---|---|---|
| Create | `Skein/MenuBar/MacOS27/PendingLayout.swift` | recorded moves and display overlay |
| Modify | `Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift` | `move`/`slowMove` 27 branch, overlay in 27 cache path, order repair offer |
| Modify | `Skein/UI/LayoutBar/LayoutBarPaddingView.swift` | alerts for unmovable items |
| Modify | `Skein/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift` | Full Disk Access banner, Apply/Discard bar, close prompt |

## Tasks

### Task 7.1 — Branch

- Steps: `git switch main && git pull --ff-only && git switch -c feat/macos27-p7-moving`.
- Verify: `git branch --show-current` prints `feat/macos27-p7-moving`.

### Task 7.2 — Pending layout

- Target files: `Skein/MenuBar/MacOS27/PendingLayout.swift`.
- Steps:
  1. `@MainActor final class PendingLayout: ObservableObject` owned by `MenuBarItemManager` (`private(set) lazy var pendingLayout = PendingLayout()`), used only by the Menu Bar Layout pane.
  2. `@Published private(set) var moves: [MenuBarLayoutMath.Move] = []`; `var hasChanges: Bool { !moves.isEmpty }`.
  3. `func record(_ move: MenuBarLayoutMath.Move)` appends; `func discard()` clears.
  4. `func overlay(on cache: MenuBarItemManager.ItemCache) -> MenuBarItemManager.ItemCache`: replay `moves` on the cache's item arrays (move the item with the key to the target's side and section) and return the result; items whose key is missing are left in place.
  5. `func apply() async -> LayoutTableWriter.ApplyResult`: `let result = await LayoutTableWriter.apply(moves)`; on `.applied` or `.noChange` call `discard()`; return result.
- Verify: no verification needed (task 7.6 covers it).

### Task 7.3 — move/slowMove and the cache overlay

- Target files: `MenuBarItemManager.swift`.
- Steps:
  1. At the top of `move(item:to:)`: `if MenuBarPlatform.usesMenuBarAgent { try recordMove(item, to: destination); return }`.
  2. `recordMove`: `guard LayoutTableFile.access() == .granted else { throw EventError(code: .couldNotComplete, item: item) }`; require `.accessibility` backing with a `tableKey` and `isGroupedIdentity == false`, else `throw EventError(code: .notMovable, item: item)`; resolve the destination's target item key the same way; `pendingLayout.record(.leftOf(...) / .rightOf(...))`; then `itemCache = pendingLayout.overlay(on: itemCache)`.
  3. In `slowMove`, on macOS 27 call `move` and return without the position loop.
  4. In `cacheItemsFromAccessibility()` (phase 3), before assigning: `if pendingLayout.hasChanges { cache = pendingLayout.overlay(on: cache) }`.
- Verify: no verification needed (task 7.6 covers it).

### Task 7.4 — Always-hidden order repair on confirmation

- Target files: `MenuBarItemManager.swift`, `MenuBarLayoutSettingsPane.swift`.
- Steps:
  1. Replace the phase 3 once-per-launch log with a published flag `@Published private(set) var alwaysHiddenOrderNeedsRepair = false`, set when AHItem's distance < HItem's.
  2. In Menu Bar Layout on macOS 27, when the flag is true and `!pendingLayout.hasChanges`, show a banner "The always-hidden divider is to the right of the hidden divider." with a "Fix…" button. The button shows an `NSAlert` "Move the always-hidden divider? The menu bar reloads once." On confirm, call `LayoutTableWriter.apply([.leftOf(key: ahKey, target: hKey)])` directly (not through `pendingLayout`) and show the result when not `.applied`.
  3. Nothing triggers this repair automatically.
- Verify: `grep -c "enforceControlItemOrder" Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift` is unchanged from `main` (the ≤26 path stays) — `git diff main -- Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift | grep -c "^-.*enforceControlItemOrder"` prints `0`.

### Task 7.5 — Pane UI

- Target files: `MenuBarLayoutSettingsPane.swift`, `LayoutBarPaddingView.swift`.
- Steps:
  1. On macOS 27 read `LayoutTableFile.access()` in `.onAppear` and every time the window becomes key. When `.denied`, show the banner "Rearranging menu bar items on macOS 27 needs Full Disk Access" with a button opening the settings URL, and disable the layout bars. When `.missing`, show "Rearrange an item once with Command-drag, then reopen this pane."
  2. When `pendingLayout.hasChanges`, show a bottom bar: "The menu bar reloads once to apply your changes" with "Apply" and "Discard". "Apply" shows the result in an alert when it is not `.applied`; `.refused(reason)` shows the reason and keeps the pending moves.
  3. When the pane disappears (window close or pane switch) with `hasChanges`, show an `NSAlert` "Apply your menu bar changes?" with "Apply", "Discard" and "Keep Editing" (reopens the pane). Never apply silently.
  4. In `LayoutBarPaddingView.move`, on `EventError` with code `.notMovable` show "This item can't be moved on its own on macOS 27" instead of the generic alert; keep the existing alert for other errors.
- Verify: Debug build prints `** BUILD SUCCEEDED **`.

### Task 7.6 — Live verification

- Steps:
  1. `Scripts/run-dev.sh`; Full Disk Access and Screen Recording granted. Diagnostics → "Dump Layout Table".
  2. In Menu Bar Layout drag two visible items into Hidden and one hidden item into Visible; wait 12 s; confirm the drags are still shown.
  3. Press Apply; after the bar reloads, Diagnostics → "Dump Item Cache" and "Dump Layout Table".
  4. Quit and relaunch Skein Dev; "Dump Layout Table".
  5. Drag one item, close the Settings window, choose "Discard".
  6. Remove Full Disk Access, relaunch, open the pane.
  7. `/usr/bin/log show --last 15m --predicate 'subsystem == "com.ariadnev.Skein.dev"' --style compact > .ci-output/p7.log`.
- Success criteria: drags persist on screen across the 12 s wait; one restart per Apply; the moved items changed sections; the table after relaunch equals the table after Apply; Discard leaves the table unchanged; without Full Disk Access the banner shows and bars are disabled.
- Verify: `grep -c "MenuBarAgent restarted" .ci-output/p7.log` prints `1` (or `0` with `LIVE_RESORT=yes`) AND `grep -c "restart timed out" .ci-output/p7.log` prints `0` AND `cmp <dump after Apply> <dump after relaunch>` exits 0 AND `cmp <dump after relaunch> <dump after Discard>` exits 0 (take a dump after step 5). Banner, disabled bars and the 12 s persistence are manual checks recorded in the PR description.

### Task 7.7 — Lint, release build, commit, PR

- Commit: `feat(menu-bar): rearrange menu bar items through the layout table on macOS 27`.
- Verify: Release build succeeds AND `gh pr checks --watch --required` exits 0.

## Test scenario matrix

| Priority | Scenario | Expected |
|---|---|---|
| Critical | Drag visible → hidden, Apply | Hidden after one confirmed restart |
| Critical | Close pane with pending changes | Prompt; nothing applied silently |
| High | Cache rebuild during pending drags | Overlay keeps drags visible |
| High | Grouped-identity item dragged | "can't be moved on its own" alert |
| High | Full Disk Access missing | Banner, bars disabled |
| High | Apply refused (menu open) | Reason shown; moves kept; no write |
| Medium | Always-hidden order wrong | Banner with confirmed fix; never automatic |

## Risks

- Moves recorded against keys that disappear (an app quits) make `applyMoves` return nil; the result is `.noChange` and the user sees it.

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
