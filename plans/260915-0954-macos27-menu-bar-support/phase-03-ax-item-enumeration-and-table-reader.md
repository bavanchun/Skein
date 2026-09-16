---
phase: 3
title: "Accessibility item enumeration and table reader"
status: complete
priority: P1
effort: "3d"
dependencies: [1, 2]
---

# Phase 3: Accessibility item enumeration and table reader

## Goal

On macOS 27, every consumer of `MenuBarItem.getMenuBarItems` receives Accessibility-backed items with stable identities and table-based order, `itemCache` sections are correct, and macOS ≤26 keeps window-based enumeration.

## Context

- Window-based enumeration lives in `Skein/MenuBar/MenuBarItems/MenuBarItem.swift:212-311`; the struct stores `window: WindowInfo` (`:13`).
- **All callers of `getMenuBarItems` (route them all by changing the two getters, not the callers):**
  1. `Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift:336` — item cache
  2. `Skein/Events/EventManager.swift:496` — `isMouseInsideMenuBarItem`
  3. `MenuBarItemManager.swift:1329` — temp-show
  4. `MenuBarItemManager.swift:1426` — `rehideTempShownItems`
  5. `Skein/Utilities/ScreenCapture.swift:13` — permission heuristic
  6. `Skein/MenuBar/MenuBarManager.swift:190` — hide application menus overlap check
  7. `Skein/MenuBar/Appearance/MenuBarOverlayPanel.swift:573` — trailing appearance shape width
  8. `Skein/MenuBar/Spacing/MenuBarItemSpacingManager.swift:157` — apps to relaunch after a spacing change
  9. `Skein/UI/LayoutBar/LayoutBarPaddingView.swift:103` — drop target in a one-item section
- Identity: `MenuBarItemInfo(namespace:title:)`. Skein control items are `namespace: .skein, title: "SItem" | "HItem" | "AHItem"`; `.skein` is `Namespace(Constants.bundleIdentifier)` (`MenuBarItemInfo.swift:207`). Use `Constants.bundleIdentifier` everywhere; never add another copy.
- Table: `status:<bundle-id>::<autosaveName>` or `module:<Name>` → distance from trailing edge; larger distance = further left. Read it with `LayoutTableFile` (phase 1): prefer `readFromDisk()`, fall back to `readViaPreferences()`.
- Accessibility frames of pushed-away items are stale, so order and sections come from the table, not from x-positions.
- Identity rule per bundle: collect that app's `AXExtrasMenuBar` items. If every item's frame is on a screen and no two overlap, sort by x ascending and zip with the bundle's table keys sorted by distance descending. If counts differ, or any frame is off-screen or overlapping, mark every item of that bundle `isGroupedIdentity = true` and keep AX order.
- Skein's own items are identified by table key (`status:<Constants.bundleIdentifier>::SItem|HItem|AHItem|…Spacer<n>`); when the table is unreadable and `CONTROLITEM_WINDOWFRAME=yes`, match Skein's AX items to `ControlItem.windowFrame` values instead. Spacers are never listed in any section.
- Accessibility calls can block on an unresponsive app: set `AXUIElementSetMessagingTimeout(appElement, 0.25)` and never run enumeration on the main actor.

## Files to Create / Modify

| Action | Path | Size | Test impact |
|---|---|---|---|
| Create | `Skein/MenuBar/MacOS27/AccessibilityMenuBarItems.swift` | ~200 | harness compare |
| Modify | `Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift` | +70 | script tests |
| Modify | `Scripts/TestMenuBarLayoutMath.swift` | +40 | — |
| Modify | `Skein/MenuBar/MenuBarItems/MenuBarItem.swift` | backing enum, getters | build |
| Modify | review checklist sites (task 3.4) | small | build + review |
| Modify | `Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift` | snapshot, 27 cache path | log grep |
| Modify | `Skein/UI/LayoutBar/LayoutBarPaddingView.swift` | drop target from `itemCache` | manual |
| Modify | `Skein/MenuBar/MacOS27/DiagnosticsMenu.swift` | "Dump Item Cache" | log grep |

## Tasks

### Task 3.1 — Branch

- Steps: `git switch main && git pull --ff-only && git switch -c feat/macos27-p3-enumeration`.
- Verify: `git branch --show-current` prints `feat/macos27-p3-enumeration`.

### Task 3.2 — Pure logic: keys, zip, sections

- Target files: `MenuBarLayoutMath.swift`, `Scripts/TestMenuBarLayoutMath.swift`.
- Steps:
  1. `struct LayoutTableKey: Hashable { let bundleID: String?; let name: String; let isModule: Bool; let rawKey: String }` with `init?(rawKey:)`: `status:<bundle>::<name>`; `module:<Name>` with a trailing `-<digits>` removed from `name`; anything else → nil (callers keep unknown keys untouched elsewhere).
  2. `static func orderedKeys(_ table: [String: Double]) -> [(key: LayoutTableKey, distance: Double)]` sorted by distance descending.
  3. `static func zip<Element>(items: [Element], keys: [LayoutTableKey], framesTrustworthy: Bool) -> (pairs: [(Element, LayoutTableKey)], grouped: Bool)`: when `framesTrustworthy && items.count == keys.count` pair by index with `grouped = false`; otherwise pair by index up to the shorter count and `grouped = true`.
  4. `enum SectionName { case visible, hidden, alwaysHidden }` and `static func section(forDistance d: Double, hiddenDivider: Double?, alwaysHiddenDivider: Double?) -> SectionName` (`d > alwaysHiddenDivider` → alwaysHidden; `d > hiddenDivider` → hidden; else visible; nil dividers mean "no such section").
  5. Tests: parse `status:com.example.app::Item-0`; `module:BentoBox-0` → module `BentoBox`; `garbage` → nil; ordering; zip 2 vs 3 → grouped; zip 2 vs 2 untrusted → grouped; 545.5 with HItem 429.5 → hidden; 385.5 → visible; 600 with AHItem 580, HItem 429.5 → alwaysHidden.
- Verify: test command exits 0 and prints `PASS`.

### Task 3.3 — Give MenuBarItem an Accessibility backing

- Target files: `MenuBarItem.swift`.
- Steps:
  1. Add `struct AccessibilityBacking: Hashable { let element: AXUIElement; let frame: CGRect; let pid: pid_t; let bundleID: String?; let tableKey: String?; let isGroupedIdentity: Bool }` with `==` comparing `tableKey` when both non-nil, else `pid` and `frame`; `hash` uses `tableKey ?? "\(pid)"`.
  2. Replace `let window: WindowInfo` with `enum Backing: Hashable { case window(WindowInfo), accessibility(AccessibilityBacking) }` and `let backing: Backing`.
  3. Compatibility accessors: `var window: WindowInfo?`, `var windowID: CGWindowID?`, `var frame: CGRect`, `var title: String?` (window title or the table key name), `var isOnScreen: Bool` (window value, or frame intersects any `NSScreen.screens` frame converted to CoreGraphics coordinates), `var ownerPID: pid_t` (window owner or backing pid), `var ownerName: String?` (window owner name or `NSRunningApplication(processIdentifier:)?.localizedName`), `var owningApplication` via `ownerPID`.
  4. Stored `let sourcePID: pid_t?`: for accessibility items set it to the backing pid.
  5. Existing initializers build `.window(...)`; add `init(accessibility: AccessibilityBacking, info: MenuBarItemInfo)`.
  6. `Equatable` and `Hashable` use `backing`.
- Verify: no verification needed (task 3.4 covers it).

### Task 3.4 — Review every window-dependent use

- Goal: no site silently changes meaning when `windowID` becomes optional.
- Steps:
  1. `grep -rn "\.windowID\|\.window\b\|getMenuBarItems(" Skein --include='*.swift' > .ci-output/p3-review.txt`.
  2. Build; fix compile errors with `guard let windowID = item.windowID else { <return the value the function already returns for a missing item> }`.
  3. Open every line in `.ci-output/p3-review.txt` and apply these required changes even if they compile:
     - `Skein/UI/SkeinBar/SkeinBar.swift:335` `ForEach(items, id: \.windowID)` → `ForEach(items, id: \.info)`.
     - `MenuBarItemManager.swift:587` `getCurrentFrame` → return `item.frame` for accessibility items.
     - `MenuBarItemManager.swift:1302` `MenuBarItem(windowID: item.windowID)` → skip this lookup for accessibility items (phase 4 replaces temp-show on 27).
     - `MenuBarItemManager.swift:1650` event builder → only reachable for window items; add `guard let windowID = item.windowID else { return nil }`.
     - `MenuBarItem.swift:121` `isCurrentlyInMenuBar` → accessibility items return `isOnScreen`.
     - `MenuBarItemImageCache.swift:121` → keep; phase 5 bypasses this path on 27.
  4. Append to the PR description a table: every line from `.ci-output/p3-review.txt` with "changed" or "unchanged: <reason>".
- Verify: Debug build prints `** BUILD SUCCEEDED **` AND Release build prints `** BUILD SUCCEEDED **` AND `grep -c "id: \\\\.windowID" Skein/UI/SkeinBar/SkeinBar.swift` prints `0`.

### Task 3.5 — Accessibility enumeration

- Target files: `Skein/MenuBar/MacOS27/AccessibilityMenuBarItems.swift`.
- Steps:
  1. `enum AccessibilityMenuBarItems { nonisolated static func current() -> [MenuBarItem] }`.
  2. Table: `LayoutTableFile.readFromDisk() ?? LayoutTableFile.readViaPreferences()`; if nil, log once per launch `layout table unreadable` (category `LayoutTable`).
  3. Third-party and Skein items: for each running app except `com.apple.MenuBarAgent`, set the 0.25 s messaging timeout, read `AXExtrasMenuBar` children with role `AXMenuBarItem`, position and size; group by bundle id; apply the identity rule from Context with `MenuBarLayoutMath.zip`; info = `MenuBarItemInfo(namespace: .init(bundleID), title: key.name)`, or `AXIdentifier ?? AXTitle ?? ""` when unpaired.
  4. Apple items: walk `com.apple.MenuBarAgent` children to depth 4; for each `AXMenuBarItem` with `AXIdentifier` `com.apple.menuextra.<suffix>`, find the `module:` table key whose lowercased name equals `suffix` (special case `controlcenter` ↔ `BentoBox`); info namespace `.controlCenter`, title = the module name (`Clock`, `BentoBox`, …); unmatched identifiers use the suffix as title.
  5. Order: items with a table key by distance descending; items without one keep AX x order and are inserted before the first keyed item whose AX x is greater.
  6. Table unreadable: order by AX x; Skein's own items identified by matching frames to `ControlItem.windowFrame` when `CONTROLITEM_WINDOWFRAME=yes`, else titled by AX index and logged `skein items unidentifiable without layout table`.
- Verify: no verification needed (task 3.6 covers it).

### Task 3.6 — Route both getters and build the cache on macOS 27

- Target files: `MenuBarItem.swift` (both `getMenuBarItems`), `MenuBarItemManager.swift`.
- Steps:
  1. In `MenuBarItemManager` add `private(set) var accessibilitySnapshot: [MenuBarItem] = []` and `func refreshAccessibilitySnapshot() async { let items = await Task.detached { AccessibilityMenuBarItems.current() }.value; accessibilitySnapshot = items }`.
  2. Sync getter: `if MenuBarPlatform.usesMenuBarAgent { return MenuBarItemManager.sharedSnapshotProvider?() ?? [] }` filtered by `display` (frame intersects `CGDisplayBounds(display)`) and `onScreenOnly` (`isOnScreen`). Provide the snapshot via a `static var sharedSnapshotProvider: (@MainActor () -> [MenuBarItem])?` set in `MenuBarItemManager.performSetup()`; if the getter is not on the main actor, return `[]` and log `sync getMenuBarItems off main on macOS 27`.
  3. Async getter: `if MenuBarPlatform.usesMenuBarAgent { let items = await Task.detached { AccessibilityMenuBarItems.current() }.value; return items filtered as above }`.
  4. Remove the phase 2 guard in `cacheItemsIfNeeded()`. At its top: `if MenuBarPlatform.usesMenuBarAgent { await cacheItemsFromAccessibility(); return }`.
  5. `cacheItemsFromAccessibility()`: `await refreshAccessibilitySnapshot()`; find `HItem`/`AHItem` distances from their table keys; build a new `ItemCache` by `MenuBarLayoutMath.section(forDistance:…)`, excluding Skein control items and any title containing `Spacer`; assign `itemCache` only when it differs; log `ax cache visible=<n> hidden=<n> alwaysHidden=<n>` at debug level.
  6. On macOS 27 skip `enforceControlItemOrder`; if AHItem's distance < HItem's, log once `always-hidden divider right of hidden divider` (phase 7 offers the repair).
  7. In `LayoutBarPaddingView.performDragOperation`, replace the `getMenuBarItems` lookup for the one-item case with `appState.itemManager.itemCache.allItems.first { $0.info == .hiddenControlItem }` (or `.alwaysHiddenControlItem`); on macOS ≤26 the cache contains the same items, so behavior is unchanged.
  8. Diagnostics: add "Dump Item Cache" logging `diag cache visible=<n> hidden=<n> alwaysHidden=<n> grouped=<n>` and, from the table, `diag table hiddenKeys=<number of status keys with distance > HItem>`.
- Verify:
  1. `Scripts/run-dev.sh`; with at least two icons left of the divider, run "Dump Item Cache".
  2. `/usr/bin/log show --last 3m --predicate 'subsystem == "com.ariadnev.Skein.dev"' --style compact > .ci-output/p3.log`.
  3. Pass when: `grep -c "diag cache" .ci-output/p3.log` ≥ 1 AND the `hidden=` number on the `diag cache` line equals the `hiddenKeys=` number minus Skein spacer keys (both numbers from the same log; compare them in a one-line shell `awk`), AND `grep -c "Missing control item" .ci-output/p3.log` prints `0`.

### Task 3.7 — Consumers that now inherit Accessibility items

- Steps (each is a manual check on macOS 27 with results in the PR description):
  1. Advanced → "Hide application menus when showing menu bar items": open a wide app menu, show hidden section; menus hide when overlapping.
  2. Menu Bar Appearance with a split shape: the trailing shape covers the items.
  3. Menu Bar Layout: each section lists as many slots as `diag cache` reports (images arrive in phase 5).
- Verify: `grep -c "sync getMenuBarItems off main" .ci-output/p3.log` prints `0` after performing steps 1–3 and re-exporting the log.

### Task 3.8 — Lint, release build, commit, PR

- Commit: `feat(menu-bar): enumerate menu bar items through Accessibility on macOS 27`.
- Verify: Release build succeeds AND `gh pr checks --watch --required` exits 0.

## Task 3.6 / 3.7 result

Verified on hardware (three displays, Skein Dev build):

- `ax cache visible=19 hidden=3 alwaysHidden=0`
- `diag cache visible=19 hidden=3 alwaysHidden=0 grouped=2`
- `diag table hiddenKeys=12`
- `grep -c "Missing control item"` printed `0`
- `grep -c "sync getMenuBarItems off main"` printed `0` after the three task 3.7 checks

The `hiddenKeys=12` / `hidden=3` gap is fully accounted for: 7 of the 12 keys are
Skein's own spacer keys and are excluded by the `Spacer` title rule, leaving 5
third-party keys. One belongs to an application that is not running. Of the
remaining 4, three currently publish a menu bar item and one runs without
publishing one, so the cache reports 3. A table key is a stored preference, not
evidence that its owner shows an item today; the cache deliberately lists only
items that exist right now.

## Test scenario matrix

| Priority | Scenario | Expected |
|---|---|---|
| Critical | Items left of HItem in the table | Hidden section, even while pushed away |
| Critical | macOS ≤26 | `.window` backing only; getters unchanged |
| High | App with one visible and one pushed-away item | Marked grouped, not swapped |
| High | Unresponsive app | Timeout; other items listed |
| High | Drop into a one-item section | Target found from `itemCache` |
| Medium | Table unreadable | Log line; AX-order fallback |

## Risks

- The `MenuBarItem` refactor touches many sites; the committed review table is the guard.
- The sync getter depends on the main-actor snapshot; off-main callers get `[]` with a log line rather than blocking.

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
