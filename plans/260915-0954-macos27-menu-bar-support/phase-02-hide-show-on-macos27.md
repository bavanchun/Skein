---
phase: 2
title: "Hide and show on macOS 27"
status: pending
priority: P1
effort: "3d"
dependencies: [1]
---

# Phase 2: Hide and show on macOS 27

## Goal

On macOS 27, collapsing the hidden or always-hidden section pushes the items left of its divider out of view. The divider length is found at runtime per screen configuration by reading MenuBarAgent's per-display windows through Accessibility, kept honored as free space changes, and extended with spacer items on wide displays. macOS 14–26 behave exactly as today.

## Why this phase was rewritten

Phase 1 spike S1 (`reports/spike-results.md`) showed the fixed rule `floor(narrowest / 2) - margin` is wrong on macOS 27:

- The main 3008pt display honors about half its width (1496 honored, 1516 dropped).
- A non-main 1800pt notched display dropped every length from 804 to 884; lengths 444–524 were honored but folded into the notch chevron, so they hide nothing. Measured cliff about 616–656.
- A non-main 1080pt display dropped every length from 444 to 524. Measured cliff about 216–316.
- The binding limit is free space beside the frontmost app's menus and the notch, not width. It changes with every app switch.

Maintainer decision (2026-09-15): measure the unit per display at runtime from MenuBarAgent's Accessibility windows. Do not re-open.

## Roles

- **Coordinator (Claude)** creates the branch and worktree, dispatches the implementer, verifies every report against the repository, runs the hardware verification in task 2.12, commits and opens the PR.
- **Implementer (agy)** does tasks 2.1–2.11 inside the worktree it is given. It never commits, pushes, switches branches or restarts MenuBarAgent.

## Context

- Paths are relative to the repository root. Read `reports/spike-results.md` first.
- **MenuBarAgent Accessibility layout (verified on macOS 27.0, three displays):** the `com.apple.MenuBarAgent` application element has one `AXWindow` child per display, whose frame is that display's menu bar. Each window's children are slot elements, one per composited item, with width `length + 16` for an item of `length`. The notch chevron is an `AXButton` child of a window whose `AXDescription` is `Show Hidden Menu Bar Items`. A dropped item has no slot on that window; on the main display AppKit also parks its window at `minY < 0`.
- **Honored** for a divider at length `L` on a display means: that display's window gained one slot of width `L + 16` per collapsed divider, and its chevron count did not increase.
- `Scripts/VerifyMenuBar27.swift` `cliff-probe` already implements this check (it pairs windows by index; task 2.10 keys them by frame).
- Current hiding: `Skein/MenuBar/ControlItem/ControlItem.swift` `Lengths.expanded = 10_000` and the `Publishers.CombineLatest($isVisible, $state)` sink that sets `statusItem.length`. On macOS 27 a 10000pt divider is dropped, which also stops Skein's own icon from being drawn on any display, so the Diagnostics menu is unreachable today.
- `MenuBarSection.hide()` returns early when the section is already hidden. Never re-apply a length by calling `hide()`; re-publishing `controlItem.state` re-runs the sink.
- `ControlItem.init` seeds `StatusItemDefaults[.preferredPosition]` to `0` for `SItem`, `1` for `HItem`, nothing for `AHItem`. Removing a status item or setting `isVisible = false` deletes its preferred position; `ControlItem` caches and restores it. Spacers must do the same.
- Hiding the hidden or visible section sets the always-hidden control item's state to `.hideItems` even when that section is disabled, so collapse work is gated on `isAddedToMenuBar`.
- `MenuBarItemManager.cacheItemsIfNeeded()` logs `Missing control item for hidden section` every few seconds on macOS 27.
- Spike facts that shape this design: `LEGACY_SEED=no` (a seeded preferred position does not create a table key; new items are not reliably placed by seeding), `ZERO_LENGTH_KEEPS_SLOT` is provisional, `LIVE_RESORT=yes`.
- `Skein` logs with `privacy: .public` and the repository is public: log counts, lengths and display widths only, never bundle identifiers.
- CI uses Xcode 26.6 and `norio-nomura/action-swiftlint@3.2.1`, which rejects continuation lines aligned with spaces (for example `if let a,\n   b`). Use the repository's `if\n    cond,\n    cond\n{` form.
- No new macOS 27-only SDK symbols.

## Files to Create / Modify

| Action | Path | Purpose |
|---|---|---|
| Modify | `Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift` | Replace `collapseUnit`/`defaultCliffMargin` with the per-display search math |
| Modify | `Scripts/TestMenuBarLayoutMath.swift` | New expectations |
| Modify | `Shared/Utilities/AXHelpers.swift` | Add `description(for:)` if missing |
| Create | `Skein/MenuBar/MacOS27/MenuBarAgentWindows.swift` | Observe MenuBarAgent's per-display windows |
| Create | `Skein/MenuBar/MacOS27/CollapseSpacers.swift` | Spacer status items per divider |
| Create | `Skein/MenuBar/MacOS27/CollapseController.swift` | Find, verify and keep the honored unit |
| Modify | `Skein/MenuBar/ControlItem/ControlItem.swift` | Use the controller's unit on macOS 27; spacers; re-apply hook |
| Modify | `Skein/MenuBar/MenuBarSection.swift` | Trigger resolution after `hide()` |
| Modify | `Skein/Main/AppState.swift` | Trigger resolution after setup; gate the Debug remote trigger |
| Modify | `Skein/MenuBar/MacOS27/DiagnosticsMenu.swift` | Remote trigger off unless a Debug default enables it |
| Modify | `Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift` | Skip window-based caching on macOS 27 |
| Modify | `Skein/Utilities/Defaults.swift` | `collapseUnitOverride`, `diagnosticsRemoteTrigger` keys |
| Modify | `Scripts/VerifyMenuBar27.swift` | Key windows by frame; `strip-capture --rect` |

## Tasks

### Task 2.1 — Defaults keys

- Target: `Skein/Utilities/Defaults.swift`.
- Steps: next to `forceLegacyMenuBar` add `case collapseUnitOverride = "CollapseUnitOverride"` and `case diagnosticsRemoteTrigger = "DiagnosticsRemoteTrigger"`. Skein only reads both; nothing in Skein writes them.
- Verify: covered by task 2.11 builds.

### Task 2.2 — Pure search math

- Target: `Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift` (imports only `Foundation` and `CoreGraphics`), `Scripts/TestMenuBarLayoutMath.swift`.
- Steps:
  1. Remove `defaultCliffMargin` and `collapseUnit(...)`.
  2. Add constants: `slotPadding: CGFloat = 16`, `minimumUnit: CGFloat = 40`, `maximumUnit: CGFloat = 4900`, `searchResolution: CGFloat = 16`, `maximumSpacersPerDivider = 6`.
  3. `static func startUnit(screenWidths: [CGFloat], userOverride: CGFloat? = nil) -> CGFloat`: if there is no positive narrowest width return `200`; otherwise `u = (narrowest / 2).rounded(.down) - slotPadding`; if `userOverride > 0` then `u = min(u, userOverride)`; return `min(max(u, minimumUnit), maximumUnit)`.
  4. `static func nextProbe(honored low: CGFloat, dropped high: CGFloat) -> CGFloat?`: return `nil` when `high - low <= 2 * searchResolution`; otherwise `low + (((high - low) / 2) / searchResolution).rounded(.down) * searchResolution`.
  5. `static func spacerCount(widestWidth: CGFloat, unit: CGFloat) -> Int`: `0` unless both are positive; otherwise `min(max(0, Int((widestWidth / unit).rounded(.up)) - 1), maximumSpacersPerDivider)`.
  6. `static func coversWidest(widestWidth: CGFloat, unit: CGFloat, spacers: Int) -> Bool`: `unit * CGFloat(spacers + 1) >= widestWidth`.
  7. `struct DisplayObservation: Equatable { var matchingSlots: Int; var chevrons: Int }`.
  8. `static func isHonored(before: [String: DisplayObservation], after: [String: DisplayObservation], expectedIncrease: Int) -> Bool`: `false` when `after` is empty or `expectedIncrease < 1`; otherwise true only if for every key in `after`, `after.matchingSlots - (before[key]?.matchingSlots ?? 0) >= expectedIncrease` and `after.chevrons <= (before[key]?.chevrons ?? 0)`.
  9. Replace the test body with exactly these expectations (plus the existing `PASS`/exit logic):
     - `startUnit([1800]) == 884`; `startUnit([1800, 3008, 1080]) == 524`; `startUnit([60]) == 40`; `startUnit([]) == 200`; `startUnit([1800], userOverride: 700) == 700`; `startUnit([1080], userOverride: 5000) == 524`.
     - `nextProbe(honored: 40, dropped: 524) == 280`; `nextProbe(honored: 280, dropped: 524) == 392`; `nextProbe(honored: 40, dropped: 80) == 56`; `nextProbe(honored: 40, dropped: 72) == nil`.
     - `spacerCount(widestWidth: 1800, unit: 884) == 2`; `spacerCount(widestWidth: 3008, unit: 524) == 5`; `spacerCount(widestWidth: 3008, unit: 216) == 6`; `spacerCount(widestWidth: 0, unit: 216) == 0`.
     - `coversWidest(widestWidth: 3008, unit: 524, spacers: 5) == true`; `coversWidest(widestWidth: 3008, unit: 216, spacers: 6) == false`.
     - `isHonored(before: ["A": (0,0), "B": (1,0)], after: ["A": (1,0), "B": (2,0)], expectedIncrease: 1) == true`; same but `after["A"] = (1,1)` → `false`; `after["B"] = (1,0)` → `false`; `after = [:]` → `false`; `before [:]`, `after ["A": (2,0)]`, `expectedIncrease: 2` → `true`.
- Verify: `xcrun swiftc -parse-as-library Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift Scripts/TestMenuBarLayoutMath.swift -o .ci-output/test-layout-math && .ci-output/test-layout-math` exits 0 and prints `PASS`.

### Task 2.3 — Observe MenuBarAgent's windows

- Target: `Skein/MenuBar/MacOS27/MenuBarAgentWindows.swift`, `Shared/Utilities/AXHelpers.swift`.
- Steps:
  1. If `AXHelpers` has no description accessor, add `static func description(for element: UIElement) -> String?` using the same `queue.sync { try? element.attribute(.description) }` pattern.
  2. `@MainActor enum MenuBarAgentWindows` with `static func observe(slotWidth: CGFloat) -> [String: MenuBarLayoutMath.DisplayObservation]`:
     - Find running apps with bundle identifier `com.apple.MenuBarAgent`; for each, `AXHelpers.application(for:)`, children with role `.window`.
     - Key each window by its frame rounded to integers: `"\(Int(minX)),\(Int(minY)),\(Int(width))"`.
     - `matchingSlots` = children whose frame width is within 1pt of `slotWidth`; `chevrons` = children whose description is `Show Hidden Menu Bar Items`.
     - Return `[:]` when MenuBarAgent is not running or Accessibility is not trusted.
  3. Reuse `AXHelpers`; do not add a second raw-AX helper set.
- Verify: covered by task 2.11 builds.

### Task 2.4 — Spacer controller

- Target: `Skein/MenuBar/MacOS27/CollapseSpacers.swift`.
- Steps:
  1. `@MainActor final class CollapseSpacers` with `init(dividerAutosaveName: String)`.
  2. `private var items: [NSStatusItem] = []`. Spacers are only added, never removed on screen changes.
  3. `static let restingLength: CGFloat = 1` with a comment: phase 1 `ZERO_LENGTH_KEEPS_SLOT` is provisional, so spacers rest at 1pt until a keyed spacer is proven to keep its slot at 0.
  4. `func ensureCount(_ count: Int)`: while `items.count < count`, create `NSStatusBar.system.statusItem(withLength: Self.restingLength)`, `autosaveName = "\(dividerAutosaveName)Spacer\(items.count)"`, `button?.isEnabled = false`, append. After creating any spacer, log once per launch `spacers created count=<n>; Cmd-drag them right of the divider once` (phase 1 `LEGACY_SEED=no`, so no position seeding).
  5. `func apply(activeCount: Int, collapsed: Bool, unit: CGFloat)`: each item's length is `unit` when `collapsed && index < activeCount`, else `restingLength`.
  6. `func removeAll()`: cache and restore each spacer's `StatusItemDefaults[.preferredPosition, name]` around `removeStatusItem`, as `ControlItem.deinit` does; clear `items`.
  7. File-private `Logger(category: "Collapse")`.
- Verify: covered by task 2.11 builds.

### Task 2.5 — Collapse controller

- Target: `Skein/MenuBar/MacOS27/CollapseController.swift`.
- Design: one `@MainActor final class CollapseController` instance (`static let shared`), in-memory only, never writes defaults.
- Steps:
  1. State: `private var honoredUnit: [String: CGFloat]`, keyed by `configurationKey(widths)` = sorted integer widths joined with `+`; `private(set) var currentUnit: CGFloat`; `private var isResolving = false`; `private var pendingResolve = false`.
  2. `func unit(for widths: [CGFloat]) -> CGFloat`: `honoredUnit[key] ?? currentUnit` when already resolving for this key, otherwise `honoredUnit[key] ?? MenuBarLayoutMath.startUnit(screenWidths: widths, userOverride: Defaults.object(forKey: .collapseUnitOverride) as? CGFloat)`.
  3. `func resolve(_ dividers: [ControlItem])` (async): run only for dividers that are added to the menu bar, visible and in `.hideItems`; return when none. If `isResolving`, set `pendingResolve = true` and return; when the running resolution finishes, run once more if pending.
  4. Probe step `probe(_ length: CGFloat, dividers:) async -> Bool`: `before = MenuBarAgentWindows.observe(slotWidth: length + 16)`; set `currentUnit = length`; call `reapplyCollapseLength()` on every divider; wait `settleDelay` (350 ms constant, named); `after = observe(...)`; return `isHonored(before:after:expectedIncrease: dividers.count)`.
     Note: `before` is taken while the dividers still have their previous length, so a pre-existing item of the same width cannot fake an increase.
  5. Search: `low: CGFloat? = nil`, `high: CGFloat? = nil`, start at `unit(for:)`. Loop at most 8 probes: honored → `low = length`, stop if `high == nil`; dropped → `high = length`. Next length is `nextProbe(honored: low ?? minimumUnit, dropped: high!)`; when it is `nil`, stop. If no length was honored, probe `minimumUnit` once. Finish by applying `low` (or `minimumUnit`) and storing it in `honoredUnit[key]` only when it was honored.
  6. Logs (category `Collapse`, `.notice`): `collapse self-test honored screens=<key> unit=<u> probes=<n>`; `collapse self-test failed screens=<key>` when even `minimumUnit` is dropped; `collapse incomplete widest=<w> unit=<u> spacers=<s>` when `coversWidest` is false.
  7. `func verifyCurrent(_ dividers:)` (async): one `probe(currentUnit)`; if dropped, remove `honoredUnit[key]` and run the search with `high = currentUnit` as the first bound. Never grow the unit here, so app switches cannot cause shrink-grow flicker.
  8. Observers installed once from `AppState.performSetup()` when `MenuBarPlatform.usesMenuBarAgent`:
     - `NSWorkspace.shared.notificationCenter` `didActivateApplicationNotification` → debounce 400 ms → `verifyCurrent` on the collapsed dividers.
     - `NSApplication.didChangeScreenParametersNotification` → debounce 400 ms → full `resolve` (the configuration key changes, so a cached unit for the new configuration is used or searched).
  9. Never call `MenuBarSection.hide()` or `show()` from the controller.
- Verify: covered by task 2.11 builds and greps.

### Task 2.6 — ControlItem integration

- Target: `Skein/MenuBar/ControlItem/ControlItem.swift`.
- Steps:
  1. In `init`, when `MenuBarPlatform.usesMenuBarAgent && identifier == .alwaysHidden` and `StatusItemDefaults[.preferredPosition, autosaveName] == nil`, set it to `2`.
  2. `private let spacers: CollapseSpacers?`, created before `configureStatusItem()` only when `MenuBarPlatform.usesMenuBarAgent` and the identifier is `.hidden` (`"HItem"`) or `.alwaysHidden` (`"AHItem"`).
  3. In the sink, replace `case .hideItems: Lengths.expanded` with `case .hideItems: MenuBarPlatform.usesMenuBarAgent ? CollapseController.shared.unit(for: NSScreen.screens.map(\.frame.width)) : Lengths.expanded`. `Lengths.expanded` stays for macOS 14–26.
  4. At the end of the sink, when `spacers != nil`: `let widths = NSScreen.screens.map(\.frame.width)`, `let unit = CollapseController.shared.unit(for: widths)`, `let count = isAddedToMenuBar ? MenuBarLayoutMath.spacerCount(widestWidth: widths.max() ?? 0, unit: unit) : 0`, `spacers.ensureCount(count)`, `spacers.apply(activeCount: count, collapsed: isVisible && isAddedToMenuBar && state == .hideItems, unit: unit)`.
  5. `func reapplyCollapseLength()` that does `state = state` (re-runs the sink without going through `hide()`).
  6. In `removeFromMenuBar()` call `spacers?.apply(activeCount: 0, collapsed: false, unit: 0)` after the existing code; in `addToMenuBar()` call `reapplyCollapseLength()` after `statusItem.isVisible = true`.
- Verify: task 2.11 grep checks.

### Task 2.7 — Triggers

- Targets: `Skein/MenuBar/MenuBarSection.swift` (`hide()`), `Skein/Main/AppState.swift` (`performSetup()`).
- Steps:
  1. At the end of `hide()`, when `MenuBarPlatform.usesMenuBarAgent`, start `Task { await CollapseController.shared.resolve(<collapsed hidden and always-hidden control items>) }`.
  2. In `performSetup()`, when `MenuBarPlatform.usesMenuBarAgent`, install the controller observers once and, after 2 seconds, resolve the collapsed dividers.
- Verify: covered by task 2.11 builds.

### Task 2.8 — Retire the Debug remote trigger by default

- Target: `Skein/MenuBar/MacOS27/DiagnosticsMenu.swift`.
- Steps: at the top of `installRemoteTrigger()` return unless `Defaults.bool(forKey: .diagnosticsRemoteTrigger)`. Add a doc comment line: enable with `defaults write com.ariadnev.Skein.dev DiagnosticsRemoteTrigger -bool true` and relaunch.
- Reason: Skein Dev holds Full Disk Access and becomes the daily driver after this phase; any local process could otherwise drive table writes and MenuBarAgent restarts.
- Verify: `grep -c "diagnosticsRemoteTrigger" Skein/MenuBar/MacOS27/DiagnosticsMenu.swift` prints `1`.

### Task 2.9 — Quiet the window-based cache on macOS 27

- Target: `Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift` (`cacheItemsIfNeeded()`).
- Steps: first line `guard !MenuBarPlatform.usesMenuBarAgent else { return }` with the comment `// Phase 3 replaces window-based caching on macOS 27.` (reword the comment to describe behavior, without a phase number: `// Window-based caching cannot see items on macOS 27; Accessibility enumeration replaces it.`).
- Verify: covered by task 2.12 log grep.

### Task 2.10 — Harness updates

- Target: `Scripts/VerifyMenuBar27.swift`.
- Steps:
  1. `cliff-probe`: pair before/after observations by window frame key (same key format as task 2.3), not by index.
  2. `strip-capture <png> [--rect x,y,w,h]`: capture the given global rectangle (top-left global coordinates) instead of the main display strip when `--rect` is present.
- Verify: `xcrun swiftc -parse-as-library Scripts/VerifyMenuBar27.swift -o .ci-output/verify-menubar27` exits 0 with no warnings.

### Task 2.11 — Implementer verification, self-review and report

- Steps (all must pass; logs under `.ci-output/`):
  1. Math test from task 2.2 prints `PASS`.
  2. Debug: `xcodebuild build -project Skein.xcodeproj -scheme 'Skein Dev' -configuration Debug -derivedDataPath .ci-output/p2-dev CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`, zero ` error:` lines.
  3. Release: `xcodebuild build -project Skein.xcodeproj -scheme Skein -configuration Release -derivedDataPath .ci-output/p2-release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` → same.
  4. `swiftlint lint --strict --quiet` on every touched Swift file under `Skein/` and `Shared/` exits 0.
  5. `grep -c "MenuBarPlatform.usesMenuBarAgent ? CollapseController.shared.unit" Skein/MenuBar/ControlItem/ControlItem.swift` prints `1`; `grep -c "static let expanded: CGFloat = 10_000" Skein/MenuBar/ControlItem/ControlItem.swift` prints `1`.
  6. `grep -cE "UserDefaults|Defaults\.set|StatusItemDefaults\[.*\] =" Skein/MenuBar/MacOS27/CollapseController.swift` prints `0`.
  7. `grep -rn "hide()\|show()" Skein/MenuBar/MacOS27/CollapseController.swift` prints nothing.
  8. Self-review with the AgentKit code-review skill on `git diff`: macOS ≤26 paths unchanged, no re-entrant resolution, observers installed once, no length ever above `maximumUnit` on macOS 27, spacer preferred positions preserved on removal, logs free of bundle identifiers. Fix findings, then re-run steps 1–7.
  9. Write the report requested by the coordinator's prompt.

### Task 2.12 — Hardware verification (coordinator)

- Steps:
  1. Install with `Scripts/run-dev.sh` (quit release Skein first). Confirm the Skein icon is drawn and the Diagnostics menu opens by right click.
  2. Enable "Show section dividers"; Cmd-drag one third-party icon left of the hidden divider and, if logged, the new spacers right of the divider.
  3. For each configuration — all three displays; only the 3008pt; only the 1800pt notched; only the 1080pt — hide, then `.ci-output/verify-menubar27 strip-capture .ci-output/p2-<config>-<display>-hidden.png --rect <display bar rect>` for each attached display, show, capture again.
  4. While hidden, switch the frontmost app between a menu-heavy app and Finder three times; capture again.
  5. Disable, then enable, the always-hidden section; hide the hidden section and capture while disabled.
  6. Unplug and replug the 3008pt display once while hidden.
  7. `/usr/bin/log show --last 30m --predicate 'subsystem == "com.ariadnev.Skein.dev" AND category == "Collapse"' --style compact > .ci-output/p2.log`, plus `MenuBarItemManager` lines into `.ci-output/p2-cache.log`.
- Success: the dragged icon is absent in every hidden capture on every display and present in every shown capture; no extra gap with always-hidden disabled; hiding survives app switches and hot-plug.
- Verify: `grep -c "collapse self-test honored" .ci-output/p2.log` ≥ 4 AND `grep -c "collapse self-test failed" .ci-output/p2.log` = 0 AND `grep -c "Missing control item" .ci-output/p2-cache.log` = 0. Record `collapse incomplete` lines and per-configuration pass/fail in the PR description (no screenshots committed).

### Task 2.13 — Lint, release build, commit, PR (coordinator)

- Commit: `feat(menu-bar): hide sections on macOS 27 with a measured per-display divider`.
- Verify: `gh pr checks --watch --required` exits 0.

## Test scenario matrix

| Priority | Scenario | Expected |
|---|---|---|
| Critical | Hidden section toggle, all three displays | Honored unit found; items hidden on every display |
| Critical | macOS ≤26 code path | `Lengths.expanded` branch kept (exact grep) |
| Critical | Skein icon after launch on macOS 27 | Drawn; Diagnostics menu reachable |
| High | Frontmost app switch while hidden | `verifyCurrent` keeps or lowers the unit; never grows |
| High | Notched display, length inside the notch | Chevron increase counts as dropped |
| High | Screen hot-plug while hidden | New configuration resolved; spacers kept |
| High | Always-hidden disabled | Its spacers rest; nothing pushed |
| Medium | `CollapseUnitOverride` above the start unit | Ignored |
| Medium | 3008pt widest with a 216pt unit | Six spacers, `collapse incomplete` logged |

## Risks

- The unit is a property of the moment: free space changes with the frontmost app and item count. Mitigation: re-verify on app activation, shrink only.
- A dropped divider is silent; the search depends on Accessibility. With Accessibility untrusted `observe` returns `[:]`, every probe reads as dropped and the unit falls to `minimumUnit`; log it, do not loop.
- Spacers land leftmost (`LEGACY_SEED=no`) until Cmd-dragged once; every spacer also consumes free space. Six per divider is the cap; hiding on the widest display may be incomplete and is logged.
- The binary search briefly changes the divider length (at most 8 probes × 350 ms). Acceptable; visible only while resolving.
- Resting length 1 may leave a small gap per spacer; switch to 0 only after a keyed spacer is proven to keep its slot.

## Failure Protocol

- Implementer: if any verification step fails and a cause-proven fix within the allowed files does not make it pass, stop, report `BLOCKED` with the exact command, its output and what was tried. Do not weaken checks.
- Coordinator: diagnose and fix routine failures directly. Escalate to `kongming` only for a problem that stays unsolved after real attempts; the phase-end review is the normal `kongming` checkpoint.
