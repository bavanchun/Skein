---
phase: 1
title: "Foundation and verification spikes"
status: partial
priority: P1
effort: "2.5d"
dependencies: []
---

# Phase 1: Foundation and verification spikes

## Goal

Add the macOS 27 runtime gate, the pure-logic file with its script test runner, a Debug-only in-app diagnostics menu, and a script harness for Accessibility and screen capture, then run the spikes whose answers later phases branch on and record them in `reports/spike-results.md`.

## Context

- All paths are relative to the repository root `/Users/vchun/Codes/My-projects/02-Ariadnev-Eco/05-ariadnev-skein/Skein`.
- Read first: `../reports/brainstorm-260915-1406-macos27-menu-bar-support.md` and `../reports/researcher-260915-1650-apple-official-macos27-menu-bar.md`.
- Facts already verified on macOS 27.0 (26A428):
  - A binary built with the macOS 26.5 SDK sees `ProcessInfo.operatingSystemVersion` = 27.0.0 and `#available(macOS 27, *)` is true.
  - Status items are not windows; `CGSGetProcessMenuBarWindowList` returns only the Window Server "Menubar" window.
  - Each app's `AXExtrasMenuBar` children are `AXMenuBarItem` / `AXMenuExtra` with `AXPress`, `AXPosition`, `AXSize`, sometimes `AXIdentifier`. Apple items live under the `com.apple.MenuBarAgent` app as `AXGroup` > `AXMenuBarItem` with identifiers like `com.apple.menuextra.clock`.
  - Layout table: `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`, key `TrailingItemPreferredPositions`, entries `status:<bundle-id>::<autosaveName>` or `module:<Name>` → distance from the trailing edge (Double).
  - `SCScreenshotManager.captureImage(in:)` captures the menu bar strip with icons. `CGWindowListCreateImage` is obsoleted in the SDK.
  - An item is honored at 880pt and dropped at 890pt on an 1800pt display; external report: 1480 honored, 1500 dropped on 3008pt.
- Apple, macOS 27 Release Notes (System Integrity Protection): access to other developer teams' app data and app group containers is denied by default with no prompt. Known issue: a process without a bundle ID cannot be granted such access. A denied CFPreferences domain reads as "not found", not as an error, and an in-process read-back after `CFPreferencesSetAppValue` can return the cached value even if nothing reached disk. Therefore every layout-table spike and every later table check runs inside the bundled Skein Dev app, and "written" means the file bytes, parsed with `PropertyListSerialization`, contain the change.
- Apple, macOS 27 Release Notes (Deprecations): apps can no longer read the TCC database. Never use it to check permissions.
- The Xcode project uses file-system synchronized groups (`PBXFileSystemSynchronizedRootGroup`), so new `.swift` files under `Skein/` join the target without editing `project.pbxproj`.
- `Skein` logs with `privacy: .public` (`Shared/Utilities/Logging.swift:21-37`) and the repository is public. Raw dumps, screenshots and bundle identifiers stay in `.ci-output/` (gitignored); committed reports contain counts and pass/fail only.
- CI lints with `norio-nomura/action-swiftlint@3.2.1`; a local `swiftlint` run is advisory, CI is authoritative.

## Files to Create / Modify

| Action | Path | Purpose |
|---|---|---|
| Create | `Skein/MenuBar/MacOS27/MenuBarPlatform.swift` | Runtime gate |
| Create | `Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift` | AppKit-free pure logic (grows in phases 2, 3, 6) |
| Create | `Skein/MenuBar/MacOS27/LayoutTableFile.swift` | Read the table from file bytes; errno-based access check |
| Create | `Skein/MenuBar/MacOS27/DiagnosticsMenu.swift` | `#if DEBUG` menu: table dump and spikes |
| Create | `Scripts/TestMenuBarLayoutMath.swift` | Script unit tests for the pure logic |
| Create | `Scripts/VerifyMenuBar27.swift` | Accessibility dump, strip capture, cliff probe |
| Create | `plans/260915-0954-macos27-menu-bar-support/reports/spike-results.md` | Spike answers (values only) |
| Modify | `Skein/Utilities/Defaults.swift` | `forceLegacyMenuBar` key |
| Modify | `Skein/MenuBar/ControlItem/ControlItem.swift` | Attach the diagnostics submenu in `createMenu(with:)` under `#if DEBUG` |

## Tasks

### Task 1.1 — Create the branch and confirm the toolchain

- Goal: a clean branch and the tools every Verify step needs.
- Steps:
  1. `git switch main && git pull --ff-only && git switch -c feat/macos27-p1-foundation`.
  2. `brew list swiftlint >/dev/null 2>&1 || brew install swiftlint`.
  3. `grep -c PBXFileSystemSynchronizedRootGroup Skein.xcodeproj/project.pbxproj`.
  4. `grep -n "^\.ci-output" .gitignore`.
- Success criteria: branch exists; swiftlint runs; synchronized groups present; `.ci-output/` ignored.
- Verify: `git branch --show-current` prints `feat/macos27-p1-foundation` AND `swiftlint version` exits 0 AND step 3 prints ≥ 1 AND step 4 prints one line.

### Task 1.2 — Add the runtime gate

- Target files: `Skein/Utilities/Defaults.swift` (enum `Defaults.Key`), `Skein/MenuBar/MacOS27/MenuBarPlatform.swift`.
- Steps:
  1. In `Defaults.Key`, next to `showContextMenuOnRightClick`, add `case forceLegacyMenuBar = "ForceLegacyMenuBar"`.
  2. Create `MenuBarPlatform.swift` with the standard file header and:
     ```swift
     import Foundation

     /// Decides which menu bar implementation Skein uses at runtime.
     ///
     /// macOS 27 composites every status item into MenuBarAgent's single window,
     /// so window-based enumeration and length-based hiding no longer work there.
     enum MenuBarPlatform {
         /// A Boolean value that indicates whether the menu bar is hosted by MenuBarAgent.
         ///
         /// The `ForceLegacyMenuBar` default exists for diagnosis and needs a relaunch.
         static let usesMenuBarAgent: Bool = {
             guard #available(macOS 27, *) else {
                 return false
             }
             return !Defaults.bool(forKey: .forceLegacyMenuBar)
         }()
     }
     ```
- Verify: `xcodebuild build -project Skein.xcodeproj -scheme 'Skein Dev' -configuration Debug -derivedDataPath .ci-output/macos27-dev CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3` prints `** BUILD SUCCEEDED **`.

### Task 1.3 — Pure logic file and script test runner

- Target files: `Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift`, `Scripts/TestMenuBarLayoutMath.swift`.
- Steps:
  1. Create `MenuBarLayoutMath.swift` importing only `Foundation` and `CoreGraphics`:
     ```swift
     /// Pure geometry for macOS 27's status item cliff. No AppKit.
     enum MenuBarLayoutMath {
         /// Margin kept below half the narrowest screen width.
         static let defaultCliffMargin: CGFloat = 64

         /// The largest length a single status item may take on every attached screen.
         ///
         /// `userOverride` is the user's pinned value; `learnedCap` is the self-test's
         /// in-memory cap for the current screen configuration. Both only lower the result.
         static func collapseUnit(screenWidths: [CGFloat], margin: CGFloat = defaultCliffMargin, userOverride: CGFloat? = nil, learnedCap: CGFloat? = nil) -> CGFloat {
             guard let narrowest = screenWidths.min(), narrowest > 0 else {
                 return 200
             }
             var unit = (narrowest / 2).rounded(.down) - margin
             if let userOverride, userOverride > 0 {
                 unit = min(unit, userOverride)
             }
             if let learnedCap {
                 unit = min(unit, learnedCap)
             }
             return min(max(unit, 200), 4900)
         }

         /// Spacer items needed next to one divider so the total span covers the widest screen.
         static func spacerCount(screenWidths: [CGFloat], unit: CGFloat) -> Int {
             guard let widest = screenWidths.max(), unit > 0 else {
                 return 0
             }
             return max(0, Int((widest / unit).rounded(.up)) - 1)
         }
     }
     ```
  2. Create `Scripts/TestMenuBarLayoutMath.swift`:
     ```swift
     // xcrun swiftc -parse-as-library Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift Scripts/TestMenuBarLayoutMath.swift -o .ci-output/test-layout-math && .ci-output/test-layout-math
     import CoreGraphics
     import Foundation

     @main
     struct TestMenuBarLayoutMath {
         static var failures = 0

         static func expect(_ condition: Bool, _ message: String) {
             if !condition {
                 failures += 1
                 print("FAIL: \(message)")
             }
         }

         static func main() {
             expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1800]) == 836, "1800 → 836")
             expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1800, 3008, 1080]) == 476, "narrowest 1080 → 476")
             expect(MenuBarLayoutMath.collapseUnit(screenWidths: [300]) == 200, "clamped to 200")
             expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1800], userOverride: 700) == 700, "override lowers")
             expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1080], userOverride: 1412) == 476, "override never raises above the cliff")
             expect(MenuBarLayoutMath.collapseUnit(screenWidths: [1800], learnedCap: 804) == 804, "learned cap lowers")
             expect(MenuBarLayoutMath.spacerCount(screenWidths: [1800], unit: 836) == 2, "1800/836 → 2")
             expect(MenuBarLayoutMath.spacerCount(screenWidths: [1800, 3008, 1080], unit: 476) == 6, "3008/476 → 6")
             expect(MenuBarLayoutMath.spacerCount(screenWidths: [], unit: 476) == 0, "no screens → 0")
             if failures == 0 {
                 print("PASS")
             } else {
                 exit(1)
             }
         }
     }
     ```
- Verify: `mkdir -p .ci-output && xcrun swiftc -parse-as-library Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift Scripts/TestMenuBarLayoutMath.swift -o .ci-output/test-layout-math && .ci-output/test-layout-math` exits 0 and prints `PASS`.

### Task 1.4 — Layout table file access (shared by diagnostics and later phases)

- Target files: `Skein/MenuBar/MacOS27/LayoutTableFile.swift`.
- Steps:
  1. `enum LayoutTableFile` with `static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")` and `static var preferencesDomain: CFString { (url.path as NSString).deletingPathExtension as CFString }`.
  2. `enum Access { case granted, denied, missing, failed(Int32) }` and `static func access() -> Access`: `let fd = open(url.path, O_RDONLY)`; if `fd >= 0` → `close(fd)` and `.granted`; else switch `errno`: `EACCES`, `EPERM` → `.denied`; `ENOENT` → `.missing`; default → `.failed(errno)`.
  3. `static func readFromDisk() -> [String: Double]?`: `Data(contentsOf: url)`; `PropertyListSerialization.propertyList(from:options:format:)` as `[String: Any]`; take `"TrailingItemPreferredPositions"` as `[String: NSNumber]` mapped to Double; nil on any failure.
  4. `static func readViaPreferences() -> [String: Double]?`: `CFPreferencesAppSynchronize(preferencesDomain)`; `CFPreferencesCopyAppValue("TrailingItemPreferredPositions" as CFString, preferencesDomain) as? [String: NSNumber]` mapped to Double.
- Verify: no verification needed (task 1.6 build covers it).

### Task 1.5 — Debug diagnostics menu

- Goal: a permanent, Debug-only way to observe and exercise the table from inside a bundled app.
- Target files: `Skein/MenuBar/MacOS27/DiagnosticsMenu.swift`, `ControlItem.swift` (`createMenu(with:)`).
- Steps:
  1. Wrap the whole file in `#if DEBUG`. `@MainActor enum DiagnosticsMenu { static func make() -> NSMenuItem }` returning a "macOS 27 Diagnostics" item with a submenu. Each action logs with `Logger(category: "Diagnostics")` using `.notice`.
  2. Action "Dump Layout Table": log `diag access=<access> disk=<count|nil> prefs=<count|nil>`; write the disk dictionary as JSON to `FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]/<bundle id>/diagnostics/table-<unix time>.json` (create directories) and log `diag table dump <path>`. Never log keys.
  3. Action "Spike: Table Access": log `spike access=<access> prefsRead=<bool> diskRead=<bool>`.
  4. Action "Spike: Sentinel Write": abort with `spike sentinel aborted: unreadable` unless `readFromDisk()` is non-nil. Let `key = "status:\(Constants.bundleIdentifier)::SkeinSpikeSentinel"`. Read the prefs dictionary, add `key = 9999.5`, `CFPreferencesSetAppValue`, `let synced = CFPreferencesAppSynchronize(domain)`; wait 1 s; `let persisted = readFromDisk()?[key] == 9999.5`; then remove the key the same way (read, remove, set, synchronize) and log `spike sentinel synced=<bool> persisted=<bool> cleaned=<readFromDisk()?[key] == nil>`.
  5. Action "Spike: Swap Two Items": requires `persisted` path working; pick the two third-party `status:` keys with the largest distances, log `spike swap keys=2`, swap their values via the same write path, verify on disk, wait 3 s, log `spike swap applied-without-restart=<bool from an Accessibility x-order check of those two bundles>`; then run `/usr/bin/killall MenuBarAgent`, wait until a new `com.apple.MenuBarAgent` pid exists and its AX tree has `com.apple.menuextra.clock`, wait 3 s, log `spike swap applied-after-restart=<bool>`; swap back, restart again, log `spike swap restored=<bool comparing disk values to the originals>`.
  6. Action "Spike: Legacy Seed": `StatusItemDefaults[.preferredPosition, "SkeinSpikeSeed"] = 300`; create `NSStatusBar.system.statusItem(withLength: 30)` with `autosaveName = "SkeinSpikeSeed"`; wait 2 s; log `spike seed distance=<disk value for status:<bundle>::SkeinSpikeSeed>`; set `length = 0` for 3 s, back to 30, log `spike zero-length kept=<bool>`; remove the item; remove the table key via the sentinel write path; log `spike seed cleaned=<bool>`.
  7. Action "Spike: Press Hidden Item": pick the first third-party AX item whose frame is off the visible screen; `AXUIElementPerformAction(element, kAXPressAction)`; log `spike press-offscreen result=<AXError raw value>`.
  8. In `ControlItem.createMenu(with:)`, before the Quit separator, add `#if DEBUG` `menu.addItem(DiagnosticsMenu.make())` `#endif`.
- Verify: Debug build prints `** BUILD SUCCEEDED **` AND `xcodebuild build -project Skein.xcodeproj -scheme Skein -configuration Release -derivedDataPath .ci-output/macos27-release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO 2>&1 | tail -3` prints `** BUILD SUCCEEDED **` (proves the `#if DEBUG` guard compiles out).

### Task 1.6 — Script harness

- Target files: `Scripts/VerifyMenuBar27.swift`.
- Steps:
  1. Model the file on `Scripts/VerifyLaunchMotion.swift` (header comment with build command, `@main`, `fail(_:)`, exit 1 on error).
  2. `ax-dump`: for every running app, read `AXExtrasMenuBar` children; print one JSON line per item `{"pid":…,"x":…,"width":…,"hasIdentifier":…}` plus a final line `ax-dump items=<n>`. For `com.apple.MenuBarAgent`, walk `AXChildren` to depth 4 and count `AXMenuBarItem`s with identifiers. Pass `--show-bundles` to include bundle ids (only for local use; never paste into committed files).
  3. `strip-capture <output.png>`: capture `x = screen.frame.minX, y = 0, width = screen.frame.width, height = 40` of the screen at origin `(0,0)` with `SCScreenshotManager.captureImage(in:)`; write PNG; print `strip-capture: <w>x<h>`.
  4. `cliff-probe <length>`: create an `NSStatusItem` titled `ZZ`, set `length`, wait 2 s, print `cliff-probe length=<l> axWidth=<w> overflowButtons=<n>` where `n` is the count of `AXButton` children in MenuBarAgent's tree; remove the item.
  5. `--expect-contains <text>` on every subcommand.
  6. No table subcommand: table access is only valid from the bundled app (Context).
- Verify: `xcrun swiftc -parse-as-library Scripts/VerifyMenuBar27.swift -o .ci-output/verify-menubar27 && .ci-output/verify-menubar27 ax-dump --expect-contains 'ax-dump items='` exits 0.

### Task 1.7 — Run the spikes and record answers

- Goal: every later decision point has a recorded answer, with raw evidence kept out of the repository.
- Target files: `plans/260915-0954-macos27-menu-bar-support/reports/spike-results.md`.
- Steps (the maintainer must be present for S3–S5 because they restart MenuBarAgent):
  1. `Scripts/run-dev.sh` to install Skein Dev built from this branch. Save all raw logs with `/usr/bin/log show --last 10m --predicate 'subsystem == "com.ariadnev.Skein.dev"' --style compact > .ci-output/spikes.log`.
  2. **Backup first:** add Skein Dev to Full Disk Access, relaunch, run "Dump Layout Table"; confirm the log shows `access=granted disk=<n>` with `n` ≥ 5 and a `diag table dump` path. If not, STOP (Failure Protocol).
  3. **S1 `CLIFF_MARGIN`**: on each display alone, `.ci-output/verify-menubar27 cliff-probe <width/2 - m>` for `m` in 96, 64, 32, 16; honored means `honored=true` on that display's MenuBarAgent window (a new slot of width `length + 16`). Counting all `AXButton`s is wrong: third-party item proxies on the main display are `AXButton`s too. The notched and small displays' cliffs depend on arrangement, free space and the notch; record them as partial unless measured with that display as main. Record the smallest margin honored on every display; default 64 unless a display drops at 64.
  4. **S2**: remove Skein Dev from Full Disk Access, relaunch, run "Spike: Table Access" → record `PREFS_READ_WITHOUT_FDA`, `DISK_READ_WITHOUT_FDA`. Re-add, relaunch, run "Spike: Table Access" and "Spike: Sentinel Write" → record `DISK_READ_WITH_FDA` and `WRITE_WITH_FDA` (= `persisted`). `WRITE_WITH_FDA=yes` requires `cleaned=true`.
  5. **S3**: run "Spike: Swap Two Items" → record `LIVE_RESORT` (applied-without-restart), `RESTART_APPLIES` (applied-after-restart); `restored=true` is required.
  6. **S4/S5**: run "Spike: Legacy Seed" → `LEGACY_SEED=yes` when distance is within ±20 of 300; `ZERO_LENGTH_KEEPS_SLOT`; `cleaned=true` is required.
  7. **S6 `CONTROLITEM_WINDOWFRAME`**: temporarily add `Logger.controlItem.debug("windowFrame \(String(describing: windowFrame))")` in the `window?.publisher(for: \.frame)` sink of `ControlItem.swift`; record `yes` if a non-nil on-screen frame logs for the Skein icon; remove the line.
  8. **S7 `SCK_PILL`**: run `strip-capture` 3 times; record `yes` if a capture indicator stays in the menu bar afterwards.
  9. **S8 `SCK_PROMPT_WHEN_DENIED`**: in System Settings remove Screen Recording from Terminal, run `strip-capture` once; record `yes` if a consent prompt appears; restore the grant.
  10. **S9 `AXPRESS_OFFSCREEN`**: collapse the hidden section (dividers shown, one icon left of the divider), run "Spike: Press Hidden Item"; `yes` when the result is 0 and the item's menu opened.
  11. Write `spike-results.md` with one `KEY=value` line per key and a short evidence note without bundle identifiers.
- Success criteria: all keys recorded; cleanup flags true.
- Verify: `grep -cE '^(CLIFF_MARGIN|PREFS_READ_WITHOUT_FDA|DISK_READ_WITHOUT_FDA|DISK_READ_WITH_FDA|WRITE_WITH_FDA|LIVE_RESORT|RESTART_APPLIES|LEGACY_SEED|ZERO_LENGTH_KEEPS_SLOT|CONTROLITEM_WINDOWFRAME|SCK_PILL|SCK_PROMPT_WHEN_DENIED|AXPRESS_OFFSCREEN)=' plans/260915-0954-macos27-menu-bar-support/reports/spike-results.md` prints `13` AND `grep -cE "sentinel .*cleaned=true|seed cleaned=true|swap restored=true" .ci-output/spikes.log` prints `3` AND `grep -c "windowFrame" Skein/MenuBar/ControlItem/ControlItem.swift` prints `0` AND `grep -cE "com\.|pl\.|ru\.|org\." plans/260915-0954-macos27-menu-bar-support/reports/spike-results.md` prints `0`.

### Task 1.8 — Lint, release build, commit, PR

- Steps:
  1. `swiftlint lint --strict --quiet` (advisory; CI decides).
  2. Release build like task 1.5.
  3. `git add Skein/MenuBar/MacOS27 Skein/Utilities/Defaults.swift Skein/MenuBar/ControlItem/ControlItem.swift Scripts/TestMenuBarLayoutMath.swift Scripts/VerifyMenuBar27.swift plans/260915-0954-macos27-menu-bar-support/reports/spike-results.md && git commit -m "feat(menu-bar): add the macOS 27 runtime gate and verification tooling"`.
  4. `git push -u origin HEAD && gh pr create --base main --fill`.
- Verify: Release build prints `** BUILD SUCCEEDED **` AND `gh pr checks --watch --required` exits 0.

## Decision rules later phases apply

| Spike result | Consequence |
|---|---|
| `CLIFF_MARGIN` ≠ 64 | Phase 2 sets `defaultCliffMargin` to the value and updates the test numbers |
| `PREFS_READ_WITHOUT_FDA=no` and `DISK_READ_WITHOUT_FDA=no` | Phase 3 lists items without the table (AX order, own items by window frame) and logs `layout table unreadable` |
| `DISK_READ_WITH_FDA=no` or `WRITE_WITH_FDA=no` | STOP before phase 6: moving cannot be implemented under macOS 27's container policy; escalate and ask the maintainer |
| `RESTART_APPLIES=no` | STOP before phase 6 for the same reason |
| `LIVE_RESORT=yes` | Phase 6 skips the restart and waits 1 s |
| `LEGACY_SEED=no` | Phase 2 creates spacers once and logs the one-time Cmd-drag instruction; phase 8 documents it |
| `ZERO_LENGTH_KEEPS_SLOT=no` | Phase 2 rests spacers at length 1 |
| `CONTROLITEM_WINDOWFRAME=no` | Phase 3 identifies Skein's own items by table key only, and phase 4 takes the Skein icon frame from the Accessibility snapshot |
| `SCK_PILL=yes` | Phase 5 captures only while Menu Bar Layout, search or Skein Bar is presented |
| `SCK_PROMPT_WHEN_DENIED=yes` | Phase 5 never calls ScreenCaptureKit unless `CGPreflightScreenCaptureAccess()` is true |
| `AXPRESS_OFFSCREEN=no` | Phase 4 reveals the section before every press (already the design); no change otherwise |

## Risks

- S3–S5 mutate the maintainer's menu bar; the in-app dump in step 2 is the backup and each spike verifies its own restore.
- `MenuBarPlatform.usesMenuBarAgent` is a `static let`; toggling `ForceLegacyMenuBar` requires relaunch by design.

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
