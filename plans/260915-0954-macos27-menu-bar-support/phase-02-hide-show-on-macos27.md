---
phase: 2
title: "Hide and show on macOS 27"
status: pending
priority: P1
effort: "2.5d"
dependencies: [1]
---

# Phase 2: Hide and show on macOS 27

## Goal

On macOS 27, collapsing the hidden or always-hidden section pushes the items left of its divider out of view using a divider length under the cliff plus inflating spacer items, verified at runtime per screen configuration, with macOS ≤26 unchanged.

## Context

- Paths relative to the repository root. Read `reports/spike-results.md` first and apply the phase 1 decision rules.
- Current hiding: `Skein/MenuBar/ControlItem/ControlItem.swift:25-28` (`Lengths.expanded = 10_000`) and `:148-176` (`CombineLatest($isVisible, $state)` sets `statusItem.length`). The only use of `Lengths.expanded` is at `:161`.
- `MenuBarSection.hide()` returns early when the section is already hidden (`Skein/MenuBar/MenuBarSection.swift:193-197`), so re-applying a length must not go through `hide()`; re-publishing `controlItem.state` re-runs the sink.
- `ControlItem.init` seeds `StatusItemDefaults[.preferredPosition]` to `0` for `SItem`, `1` for `HItem` and nothing for `AHItem` (`ControlItem.swift:90-99`). Removing a status item or setting `statusItem.isVisible = false` deletes its preferred position; `ControlItem` caches and restores it around both (`:128-136`, `:552-562`). Spacers must do the same.
- Hiding the hidden or visible section sets the always-hidden control item's state to `.hideItems` even when that section is disabled (`MenuBarSection.swift:205-224`), so spacer inflation must be gated on `isAddedToMenuBar`.
- `MenuBarItemManager.cacheItemsIfNeeded()` (`MenuBarItemManager.swift:315-346`) logs `Missing control item for hidden section` every 5 s on macOS 27.
- Self-test signal: MenuBarAgent's Accessibility tree gains overflow `AXButton` children when items are pushed away (phase 1 `cliff-probe`).

## Files to Create / Modify

| Action | Path | Size | Test impact |
|---|---|---|---|
| Create | `Skein/MenuBar/MacOS27/CollapseSpacers.swift` | ~140 | runtime |
| Create | `Skein/MenuBar/MacOS27/CollapseSelfTest.swift` | ~110 | log lines |
| Modify | `Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift` | +20 (`spacerSeedPositions`) | script tests |
| Modify | `Scripts/TestMenuBarLayoutMath.swift` | +8 | — |
| Modify | `Skein/MenuBar/ControlItem/ControlItem.swift` | ~+45 | build |
| Modify | `Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift` | +3 | log grep |
| Modify | `Skein/Utilities/Defaults.swift` | +1 | — |

## Tasks

### Task 2.1 — Branch

- Steps: `git switch main && git pull --ff-only && git switch -c feat/macos27-p2-hide-show`.
- Verify: `test -f Skein/MenuBar/MacOS27/MenuBarPlatform.swift && git branch --show-current` prints `feat/macos27-p2-hide-show`.

### Task 2.2 — User override key (read-only for Skein)

- Target files: `Skein/Utilities/Defaults.swift`.
- Steps: add `case collapseUnitOverride = "CollapseUnitOverride"` next to `forceLegacyMenuBar`. Skein only reads this key; nothing in Skein writes it.
- Verify: no verification needed (task 2.5 build covers it).

### Task 2.3 — Spacer seed positions (pure logic)

- Target files: `MenuBarLayoutMath.swift`, `Scripts/TestMenuBarLayoutMath.swift`.
- Steps:
  1. Add `static func spacerSeedPositions(divider: Double, rightNeighbor: Double, count: Int) -> [Double]` returning `(1...count).map { divider - (divider - rightNeighbor) * Double($0) / Double(count + 1) }` (empty for `count <= 0`). All values are strictly between the divider and its right neighbor.
  2. Tests: `spacerSeedPositions(divider: 1, rightNeighbor: 0, count: 3)` == `[0.75, 0.5, 0.25]`; every value for `(2, 1, 6)` is in the open interval (1, 2); `count 0` → `[]`.
- Verify: the phase 1 test command exits 0 and prints `PASS`.

### Task 2.4 — Spacer controller

- Target files: `Skein/MenuBar/MacOS27/CollapseSpacers.swift`.
- Steps:
  1. `@MainActor final class CollapseSpacers` with `init(dividerAutosaveName: String, rightNeighborAutosaveName: String)`.
  2. `private var items: [NSStatusItem] = []`. Spacers are only ever added, never removed on screen changes.
  3. `func ensureCount(_ count: Int)`: while `items.count < count`: `let index = items.count`; `let name = "\(dividerAutosaveName)Spacer\(index)"`; when `LEGACY_SEED=yes` and `StatusItemDefaults[.preferredPosition, name] == nil`, compute seeds with `MenuBarLayoutMath.spacerSeedPositions(divider: StatusItemDefaults[.preferredPosition, dividerAutosaveName] ?? 1, rightNeighbor: StatusItemDefaults[.preferredPosition, rightNeighborAutosaveName] ?? 0, count: max(count, 1))` and write `StatusItemDefaults[.preferredPosition, name] = seeds[index]` BEFORE creating the item; create `NSStatusBar.system.statusItem(withLength: restingLength)`; set `autosaveName = name`; `button?.isEnabled = false`; append.
  4. `var restingLength: CGFloat { spikeZeroLengthKeepsSlot ? 0 : 1 }` where `spikeZeroLengthKeepsSlot` is a `static let` constant set from `ZERO_LENGTH_KEEPS_SLOT` in `spike-results.md` at implementation time (write the literal `true` or `false` with a comment naming the spike).
  5. `func apply(activeCount: Int, collapsed: Bool, unit: CGFloat)`: for index, item in `items`: `item.length = (collapsed && index < activeCount) ? unit : restingLength`.
  6. `func removeAll()`: for each item, cache `StatusItemDefaults[.preferredPosition, name]`, `NSStatusBar.system.removeStatusItem(item)`, restore the cached value (same pattern as `ControlItem.deinit`); clear `items`.
  7. When `LEGACY_SEED=no`, after creating any new spacer log `Logger.collapse.notice("spacers created; Cmd-drag them right of the divider once")`.
  8. File end: `private extension Logger { static let collapse = Logger(category: "Collapse") }`.
- Verify: no verification needed (task 2.5 build covers it).

### Task 2.5 — Use the unit in ControlItem

- Target files: `ControlItem.swift` (`init`, `configureCancellables()`, `addToMenuBar()`, `removeFromMenuBar()`).
- Steps:
  1. In `init`, when `MenuBarPlatform.usesMenuBarAgent` and `identifier == .alwaysHidden` and `StatusItemDefaults[.preferredPosition, autosaveName] == nil`, set it to `2` (gated so macOS ≤26 is unchanged).
  2. Add `private let spacers: CollapseSpacers?`, set before `configureStatusItem()` to `nil` unless `MenuBarPlatform.usesMenuBarAgent`; `.hidden` → `CollapseSpacers(dividerAutosaveName: "HItem", rightNeighborAutosaveName: "SItem")`; `.alwaysHidden` → `CollapseSpacers(dividerAutosaveName: "AHItem", rightNeighborAutosaveName: "HItem")`.
  3. Add `private var collapseUnit: CGFloat`:
     ```swift
     let widths = NSScreen.screens.map(\.frame.width)
     return MenuBarLayoutMath.collapseUnit(
         screenWidths: widths,
         userOverride: Defaults.object(forKey: .collapseUnitOverride) as? CGFloat,
         learnedCap: CollapseSelfTest.learnedCap(for: widths)
     )
     ```
     (use the existing `Defaults.object(forKey:)` accessor in `Skein/Utilities/Defaults.swift`).
  4. In the `CombineLatest($isVisible, $state)` sink, replace `case .hideItems: Lengths.expanded` with `case .hideItems: MenuBarPlatform.usesMenuBarAgent ? collapseUnit : Lengths.expanded`.
  5. At the end of that sink add:
     ```swift
     if let spacers {
         let unit = collapseUnit
         let count = isAddedToMenuBar ? MenuBarLayoutMath.spacerCount(screenWidths: NSScreen.screens.map(\.frame.width), unit: unit) : 0
         spacers.ensureCount(count)
         spacers.apply(activeCount: count, collapsed: isVisible && isAddedToMenuBar && state == .hideItems, unit: unit)
     }
     ```
  6. In `configureCancellables()`, when `spacers != nil`, subscribe to `NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)` with `.receive(on: DispatchQueue.main)` and set `state = state`, then call `CollapseSelfTest.scheduleCheck(for: self)` when `state == .hideItems`.
  7. In `removeFromMenuBar()` call `spacers?.apply(activeCount: 0, collapsed: false, unit: 0)` after the existing code; in `addToMenuBar()` set `state = state` after `statusItem.isVisible = true`.
- Success criteria: Debug build succeeds; the ≤26 branch still uses `Lengths.expanded`.
- Verify: Debug build prints `** BUILD SUCCEEDED **` AND `grep -c "MenuBarPlatform.usesMenuBarAgent ? collapseUnit : Lengths.expanded" Skein/MenuBar/ControlItem/ControlItem.swift` prints `1` AND `grep -c "static let expanded: CGFloat = 10_000" Skein/MenuBar/ControlItem/ControlItem.swift` prints `1`.

### Task 2.6 — Runtime self-test per screen configuration

- Target files: `Skein/MenuBar/MacOS27/CollapseSelfTest.swift`, `Skein/MenuBar/MenuBarSection.swift` (`hide()`), `Skein/Main/AppState.swift` (`performSetup()`).
- Steps:
  1. `@MainActor enum CollapseSelfTest` with in-memory state only: `private static var learned: [String: CGFloat] = [:]`, `private static var verdicts: [String: String] = [:]`, and `static func key(_ widths: [CGFloat]) -> String { widths.map { String(Int($0)) }.sorted().joined(separator: "+") }`.
  2. `static func learnedCap(for widths: [CGFloat]) -> CGFloat? { learned[key(widths)] }`.
  3. `static func scheduleCheck(for controlItem: ControlItem)`: skip if `verdicts[key]` is `honored`; count MenuBarAgent overflow `AXButton` children with the collapse forced off (`controlItem.state = .showItems`, wait 300 ms, count `before`), then `controlItem.state = .hideItems`, wait 600 ms, count `after`.
  4. If `after > before`: `verdicts[key] = "honored"`; log `collapse self-test honored screens=\(key) unit=\(Int(unit))`.
  5. Else if no third-party Accessibility item was left of the divider before collapsing: log `collapse self-test inconclusive screens=\(key)` and leave the verdict unset.
  6. Else: log `collapse self-test dropped screens=\(key) unit=\(Int(unit))`; set `learned[key] = unit - 32`; if the new value is ≥ 200 re-run `scheduleCheck` once more for this configuration (re-publishing state recomputes the length); otherwise set `verdicts[key] = "failed"` and log `collapse self-test failed screens=\(key)`.
  7. Call sites: in `MenuBarSection.hide()`, after the state changes and when `MenuBarPlatform.usesMenuBarAgent`, call `CollapseSelfTest.scheduleCheck(for: controlItem)` in a `Task` for `.hidden` and `.alwaysHidden` only; in `AppState.performSetup()`, after `menuBarManager.performSetup()`, when `MenuBarPlatform.usesMenuBarAgent`, schedule the check for the hidden section's control item after 2 s.
- Verify: Debug build prints `** BUILD SUCCEEDED **` AND `grep -c "UserDefaults.standard.set" Skein/MenuBar/MacOS27/CollapseSelfTest.swift` prints `0`.

### Task 2.7 — Quiet the window-based cache on macOS 27

- Target files: `MenuBarItemManager.swift` (`cacheItemsIfNeeded()`).
- Steps: at the top add `guard !MenuBarPlatform.usesMenuBarAgent else { return }` with the comment `// Phase 3 replaces window-based caching on macOS 27.`
- Verify: no verification needed (task 2.9 covers it).

### Task 2.8 — Margin from spike S1

- Steps: if `CLIFF_MARGIN` ≠ 64, update `defaultCliffMargin` and every expected number in the script tests (unit = floor(w/2) − margin).
- Verify: test command exits 0 and prints `PASS`.

### Task 2.9 — Live verification

- Steps:
  1. `Scripts/run-dev.sh` (quit the release Skein first). Enable "Show section dividers" in Advanced settings.
  2. Cmd-drag one third-party icon left of the hidden divider; click the Skein icon twice.
  3. `.ci-output/verify-menubar27 strip-capture .ci-output/p2-hidden.png` while hidden; again to `.ci-output/p2-shown.png` while shown.
  4. Disable, then enable, the always-hidden section in Advanced settings; hide the hidden section; capture `.ci-output/p2-ah-disabled.png` while disabled.
  5. Repeat steps 2–3 with only the LG 3008 display, only the ARZOPA 1080, then all displays connected, unplugging and replugging the LG once while hidden.
  6. `/usr/bin/log show --last 15m --predicate 'subsystem == "com.ariadnev.Skein.dev"' --style compact > .ci-output/p2.log`.
- Success criteria: dragged icon absent in hidden captures and present in shown captures; with always-hidden disabled no extra gap appears; each configuration logs honored.
- Verify: `grep -c "collapse self-test honored" .ci-output/p2.log` prints ≥ 3 AND `grep -c "Missing control item" .ci-output/p2.log` prints `0` AND `grep -c "collapse self-test failed" .ci-output/p2.log` prints `0`. The PNG comparison is manual; record pass/fail per configuration in the PR description (no screenshots committed).

### Task 2.10 — Lint, release build, commit, PR

- Commit: `feat(menu-bar): hide sections on macOS 27 with a capped divider and spacers`.
- Verify: Release build prints `** BUILD SUCCEEDED **` AND `gh pr checks --watch --required` exits 0.

## Test scenario matrix

| Priority | Scenario | Expected |
|---|---|---|
| Critical | Hidden section toggle on 1800 notched | Items left of HItem hidden, restored on show |
| Critical | macOS ≤26 code path | `Lengths.expanded` branch kept (exact ternary grep) |
| High | Screen hot-plug while hidden | Spacers kept, active count recomputed, still hidden |
| High | Always-hidden disabled | Its spacers rest at resting length; nothing pushed |
| High | Dropped divider on a new configuration | Learned cap lowers the unit for that configuration only |
| Medium | User sets `CollapseUnitOverride` above the cliff | Ignored; unit stays at the cliff |

## Risks

- A dropped divider looks like "nothing to hide"; the inconclusive branch avoids false step-downs.
- Fresh spacers land leftmost when `LEGACY_SEED=no`; the logged one-time drag and phase 8 docs cover it. Spacers are never removed on screen changes, so the drag stays valid.

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
