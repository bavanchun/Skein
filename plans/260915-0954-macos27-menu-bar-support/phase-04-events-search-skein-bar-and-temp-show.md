---
phase: 4
title: "Events, search, Skein Bar and temp-show"
status: pending
priority: P1
effort: "2d"
dependencies: [3]
---

# Phase 4: Events, search, Skein Bar and temp-show

## Goal

On macOS 27, show-on-click/hover/scroll, the right-click menu, Skein Bar positioning and clicks, search activation and temp-show all work from the Accessibility snapshot, with a reveal mechanism that does not go through `MenuBarSection.show()`.

## Context

- Hit testing: `Skein/Events/EventManager.swift:489-500` (`isMouseInsideMenuBarItem`), `:518-523` (`isMouseInsideEmptyMenuBarSpace` requires `!isMouseInsideMenuBarItem`), `:543-555` (`isMouseInsideSkeinIcon`, evaluated on mouse-down at `:283-286`).
- On macOS 27 the collapsed divider and spacers are 476–836pt wide and cover exactly the empty bar space users click; Skein's own process id must be excluded from hit-test frames except the Skein icon.
- After phase 3 the sync `getMenuBarItems` returns `MenuBarItemManager.accessibilitySnapshot` (refreshed every 5 s by the cache timer). No new timer is added here.
- `MenuBarSection.show()` opens the Skein Bar instead of revealing when "Use Skein Bar" is on, and returns early when the section's control item is not in the menu bar (`Skein/MenuBar/MenuBarSection.swift:131-189`). Temp-show and image capture must therefore set control item states directly.
- Existing temp-show bookkeeping: `TempShownItemContext`, `runTempShownItemTimer(for:)`, `rehideTempShownItems()` (`MenuBarItemManager.swift:71-95`, `:1270-1455`), bounded by `tempShowInterval`.
- Callers of temp-show: `Skein/UI/SkeinBar/SkeinBar.swift:367,380`, `Skein/MenuBar/Search/MenuBarSearchPanel.swift:308`.
- Spikes: `CONTROLITEM_WINDOWFRAME`, `AXPRESS_OFFSCREEN`.

## Files to Create / Modify

| Action | Path | Purpose |
|---|---|---|
| Modify | `Skein/MenuBar/MenuBarSection.swift` | `revealForTemporaryUse()` / `concealAfterTemporaryUse()` |
| Modify | `Skein/Events/EventManager.swift` | 27 branches in `isMouseInsideMenuBarItem`, `isMouseInsideSkeinIcon` |
| Modify | `Skein/UI/SkeinBar/SkeinBar.swift` | icon frame on 27 |
| Modify | `Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift` | `click(item:with:)`, `tempShowItem`, `rehideTempShownItems` 27 branches; refresh after reveal |

## Tasks

### Task 4.1 — Branch

- Steps: `git switch main && git pull --ff-only && git switch -c feat/macos27-p4-events`.
- Verify: `git branch --show-current` prints `feat/macos27-p4-events`.

### Task 4.2 — Direct reveal API

- Target files: `MenuBarSection.swift`.
- Steps:
  1. Add `func revealForTemporaryUse() -> Bool` (returns whether it changed anything). Resolve the target: if `name == .alwaysHidden` and `!controlItem.isAddedToMenuBar`, use the hidden section instead. Set `.showItems` directly on: `.hidden` → hidden and visible control items; `.alwaysHidden` → always-hidden, hidden and visible control items. Do not touch `skeinBarPanel`. Return `false` if all of them were already `.showItems`.
  2. Add `func concealAfterTemporaryUse()` setting `.hideItems` on the same control items, then `appState?.allowShowOnHover()`.
  3. Neither method calls `show()`, `hide()` or `startRehideChecks()`.
- Verify: no verification needed (task 4.7 covers it).

### Task 4.3 — Hit testing on macOS 27

- Target files: `EventManager.swift`.
- Steps:
  1. In `isMouseInsideMenuBarItem`, after the existing guard: `if MenuBarPlatform.usesMenuBarAgent { let items = MenuBarItem.getMenuBarItems(on: screen.displayID, onScreenOnly: true, activeSpaceOnly: true); return items.contains { ($0.ownerPID != getpid() || $0.info == .skeinIcon) && $0.frame.width < 400 && $0.frame.contains(mouseLocation) } }`.
  2. In `isMouseInsideSkeinIcon`, when `MenuBarPlatform.usesMenuBarAgent` and `CONTROLITEM_WINDOWFRAME=no`: find the `.skeinIcon` item in `appState.itemManager.accessibilitySnapshot` (no Accessibility call here) and convert its CoreGraphics frame to AppKit with `let h = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? 0; CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)`. When `yes`, leave the code unchanged.
- Verify: Debug build prints `** BUILD SUCCEEDED **`.

### Task 4.4 — Skein Bar anchoring

- Target files: `SkeinBar.swift` `updateOrigin(for:)` case `.skeinIcon`.
- Steps: when `MenuBarPlatform.usesMenuBarAgent`, replace the `Bridging.getWindowFrame(for: windowID)` lookup with `section.controlItem.windowFrame` when `CONTROLITEM_WINDOWFRAME=yes`, else the AppKit frame from task 4.3; keep the clamping.
- Verify: no verification needed (task 4.7 covers it).

### Task 4.5 — Click on macOS 27

- Target files: `MenuBarItemManager.swift` `click(item:with:)`.
- Steps: at the top:
  ```swift
  if MenuBarPlatform.usesMenuBarAgent, case .accessibility(let ax) = item.backing {
      let preferred = mouseButton == .right ? "AXShowMenu" : kAXPressAction
      var result = AXUIElementPerformAction(ax.element, preferred as CFString)
      if result != .success, preferred != kAXPressAction {
          result = AXUIElementPerformAction(ax.element, kAXPressAction as CFString)
      }
      guard result == .success else {
          Logger.itemManager.error("click failed \(item.logString) error=\(result.rawValue)")
          throw EventError(code: .couldNotComplete, item: item)
      }
      return
  }
  ```
- Verify: no verification needed (task 4.7 covers it).

### Task 4.6 — Temp-show on macOS 27

- Target files: `MenuBarItemManager.swift` (`tempShowItem`, `rehideTempShownItems`, `TempShownItemContext`).
- Steps:
  1. At the top of `tempShowItem`: `if MenuBarPlatform.usesMenuBarAgent { tempShowItemByRevealing(item, clickWhenFinished: clickWhenFinished, mouseButton: mouseButton); return }`.
  2. `tempShowItemByRevealing`: find the section with `itemCache.section(for: item)`; if `.visible`, `try await click` and return. Otherwise `let changed = section.revealForTemporaryUse()`; log `temp-show revealed \(section.name.logString)`; sleep 350 ms; `await refreshAccessibilitySnapshot()`; re-find the item in `accessibilitySnapshot` by `info`; when `clickWhenFinished`, `try await click(item:with:)` and log errors. If `changed`, append a `TempShownItemContext` whose `returnDestination` is unused on 27 and store the section name; call the existing `runTempShownItemTimer(for: tempShowInterval)`.
  3. Add `var sectionName: MenuBarSection.Name?` to `TempShownItemContext` (nil on ≤26).
  4. In `rehideTempShownItems()`, when `MenuBarPlatform.usesMenuBarAgent`: for each context with a `sectionName`, if a window with `layer == Int(CGWindowLevelForKey(.popUpMenuWindow))` owned by the item's pid is on screen and less than `2 × tempShowInterval` has passed since the context was created, keep it; otherwise call `concealAfterTemporaryUse()` on that section and log `temp-show concealed`. Store the creation date in the context.
- Verify: Debug build prints `** BUILD SUCCEEDED **`.

### Task 4.7 — Live verification

- Steps:
  1. `Scripts/run-dev.sh`. Enable Show on click, Show on hover, Show on scroll.
  2. With the hidden section collapsed, click empty bar space; then move away, hover empty space 1 s, move away; scroll up/down on the bar.
  3. Enable "Use Skein Bar", click the Skein icon, click a hidden item in the Skein Bar; close its menu; wait `tempShowInterval` + 2 s.
  4. Disable "Use Skein Bar"; open "Search Menu Bar Items", type a hidden item's name, press Return; close its menu; wait `tempShowInterval` + 2 s.
  5. `/usr/bin/log show --last 10m --predicate 'subsystem == "com.ariadnev.Skein.dev"' --style compact > .ci-output/p4.log`.
- Success criteria: each step reveals/hides as on macOS 26; clicked hidden items open their menus; sections conceal afterwards.
- Verify: `grep -c "temp-show revealed" .ci-output/p4.log` prints ≥ 2 AND `grep -c "temp-show concealed" .ci-output/p4.log` prints ≥ 2 AND `grep -c "click failed" .ci-output/p4.log` prints `0`. Visual outcomes of step 2 are manual; record pass/fail per step in the PR description.

### Task 4.8 — Lint, release build, commit, PR

- Commit: `feat(menu-bar): route clicks, hover and temp-show through Accessibility on macOS 27`.
- Verify: Release build succeeds AND `gh pr checks --watch --required` exits 0.

## Risks

- `AXShowMenu` is not exposed by every item; the press fallback covers it, and failures now throw and log.
- Coordinate conversion between Accessibility (top-left) and AppKit (bottom-left) is named explicitly in task 4.3.

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
