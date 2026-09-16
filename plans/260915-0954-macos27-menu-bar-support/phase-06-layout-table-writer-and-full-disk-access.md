---
phase: 6
title: "Layout table writer and Full Disk Access"
status: complete
priority: P1
effort: "2.5d"
dependencies: [3]
---

# Phase 6: Layout table writer and Full Disk Access

## Goal

On macOS 27, Skein can apply a set of item moves to MenuBarAgent's layout table with read-modify-write semantics, a verified on-disk result, a timestamped backup, a safe MenuBarAgent restart with rollback, and an on-demand Full Disk Access check, without changing onboarding.

## Context

- Read `reports/spike-results.md`. This phase must not start when `DISK_READ_WITH_FDA=no`, `WRITE_WITH_FDA=no` or `RESTART_APPLIES=no` (phase 1 rules).
- Table access helpers: `Skein/MenuBar/MacOS27/LayoutTableFile.swift` (`access()`, `readFromDisk()`, `readViaPreferences()`, `preferencesDomain`).
- Apple, macOS 27 Release Notes (System Integrity Protection): other teams' app group containers are denied by default with no prompt. A denied CFPreferences domain reads as "not found", and an in-process read-back can come from the process cache. A write counts as successful only when `CFPreferencesAppSynchronize` returns `true` AND `readFromDisk()` shows the change.
- Write rule: start from a fresh `readFromDisk()`, change only the moved keys (and the minimum neighbors needed to open a slot), keep every other key and value byte for byte, and never write when the fresh read is nil or the resulting key count differs from the fresh count.
- Restart hazards: launchd throttles respawn when MenuBarAgent lived under 10 s; a restart closes open menus and drops drags. All checks run before the write.
- Full Disk Access has no query API. `LayoutTableFile.access()` uses `open(2)` errno: `.granted`, `.denied` (EACCES/EPERM), `.missing` (ENOENT, table not created yet), `.failed`. Settings URL: `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
- Decision: Full Disk Access is required for moving items on macOS 27, not for launch. It is checked on demand and is not part of `PermissionsManager.allPermissions`, so `permissionsState` and onboarding (`Skein/Permissions/PermissionsView.swift:13,21,130`, `Skein/Main/AppDelegate.swift:55-61`) do not change.
- Every MenuBarAgent restart requires explicit user confirmation (phase 7 owns the prompts; this phase exposes `apply` returning a result).
- Logging: `Shared/Utilities/Logging.swift` logs publicly; never log table keys or bundle identifiers outside `#if DEBUG`.

## Moved into phase 2 (2026-09-16)

Hiding on macOS 27 now needs a verified table write on each hide, so these move into phase 2 and are already done when this phase starts:

- Task 6.3, `LayoutBackups`.
- Task 6.5's writer, minus the restart and rollback steps: the read-modify-write, the on-disk verification and the `ApplyResult` cases it needs.

This phase keeps `applyMoves` (task 6.2), `MenuBarAgentRestarter` (task 6.4), the restart and rollback paths in `apply`/`restore`, the backups pane and the Debug move action. Read phase 2's Revision 5 before starting, and extend the existing types instead of creating parallel ones.

## Files to Create / Modify

| Action | Path | Purpose |
|---|---|---|
| Create | `Skein/MenuBar/MacOS27/LayoutTableWriter.swift` | preflight, backup, read-modify-write, verify, rollback |
| Create | `Skein/MenuBar/MacOS27/MenuBarAgentRestarter.swift` | preflight and restart |
| Create | `Skein/MenuBar/MacOS27/LayoutBackups.swift` | timestamped backups, list, restore |
| Modify | `Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift` | `applyMoves` |
| Modify | `Scripts/TestMenuBarLayoutMath.swift` | tests |
| Modify | `Skein/Settings/SettingsPanes/AdvancedSettingsPane.swift` | "Menu Bar Layout Backups" (27 only) |
| Modify | `Skein/MenuBar/MacOS27/DiagnosticsMenu.swift` | "Move First Visible Item to Hidden" (Debug) |

## Tasks

### Task 6.1 — Branch

- Steps: `git switch main && git pull --ff-only && git switch -c feat/macos27-p6-table-writer`.
- Verify: `git branch --show-current` prints `feat/macos27-p6-table-writer`.

### Task 6.2 — Apply moves on a table (pure logic)

- Target files: `MenuBarLayoutMath.swift`, `Scripts/TestMenuBarLayoutMath.swift`.
- Steps:
  1. `enum Move: Equatable { case leftOf(key: String, target: String), rightOf(key: String, target: String) }`.
  2. `static func applyMoves(_ moves: [Move], to table: [String: Double]) -> [String: Double]?`: return nil if any key or target is missing. For each move in order: let `t = table[target]`; the neighbor on the requested side is the key with the nearest distance greater than `t` (for `leftOf`) or smaller than `t` (for `rightOf`), or `t + 40` / `max(t - 40, 0.5)` if none; set `table[key] = (t + neighbor) / 2`. If the gap is < 0.01, renumber only the `status:` keys between the target and that neighbor by spacing them 1.0 apart outward from the target, never touching `module:` keys or unknown keys. Return the result.
  3. Tests: unknown key `other:x` survives unchanged; `module:Clock` unchanged; moving `status:a::1` left of `status:b::1` yields a distance greater than b's; the key count is unchanged; a missing target returns nil; three consecutive moves into the same gap stay strictly ordered.
- Verify: test command exits 0 and prints `PASS`.

### Task 6.3 — Backups

- Target files: `Skein/MenuBar/MacOS27/LayoutBackups.swift`.
- Steps:
  1. Directory: `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(Constants.bundleIdentifier).appendingPathComponent("LayoutBackups")`; create with `createDirectory(withIntermediateDirectories: true)`.
  2. `static func save(_ table: [String: Double]) throws -> URL`: write `layout-<ISO8601 basic>.plist` via `PropertyListSerialization.data(fromPropertyList:format: .binary)` and `write(to:options: .atomic)`; then keep the newest 10 files and delete older ones.
  3. `static func list() -> [(date: Date, url: URL)]` newest first; `static func load(_ url: URL) -> [String: Double]?`.
- Verify: no verification needed (task 6.7 covers it).

### Task 6.4 — Restarter with preflight

- Target files: `Skein/MenuBar/MacOS27/MenuBarAgentRestarter.swift`.
- Steps:
  1. `@MainActor enum MenuBarAgentRestarter`.
  2. `static func preflight() -> String?` returning a refusal reason or nil: `isRestarting` → "restart in progress"; `NSEvent.pressedMouseButtons != 0` → "mouse button down"; any on-screen window with `layer == Int(CGWindowLevelForKey(.popUpMenuWindow))` → "a menu is open"; the `com.apple.MenuBarAgent` process `launchDate` less than 12 s ago → "menu bar just restarted".
  3. `static func restart() async -> Bool`: set `isRestarting = true` (defer false); re-run `preflight()` and return false if it refuses; run `/usr/bin/killall MenuBarAgent` with `Process`; poll every 250 ms up to 20 s until a new pid exists AND its Accessibility tree contains an `AXMenuBarItem` with `AXIdentifier == "com.apple.menuextra.clock"`; log `MenuBarAgent restarted in <ms> ms` or `MenuBarAgent restart timed out`.
- Verify: no verification needed (task 6.7 covers it).

### Task 6.5 — Writer

- Target files: `Skein/MenuBar/MacOS27/LayoutTableWriter.swift`.
- Steps:
  1. `enum ApplyResult: Equatable { case applied, refused(String), unreadable, noChange, writeFailed, backupFailed, restartFailedRolledBack, restartFailedRollbackFailed }`.
  2. `@MainActor static func apply(_ moves: [MenuBarLayoutMath.Move]) async -> ApplyResult`:
     1. Unconditionally `if let reason = MenuBarAgentRestarter.preflight() { return .refused(reason) }`, whatever
        `LIVE_RESORT` measured. Refusing while a mouse button is held or a menu is open protects the write itself,
        not only the restart, and under `LIVE_RESORT=yes` it is what makes a refusal observable at all.
     2. `guard LayoutTableFile.access() == .granted, let fresh = LayoutTableFile.readFromDisk() else { return .unreadable }`.
     3. `guard let next = MenuBarLayoutMath.applyMoves(moves, to: fresh), next.count == fresh.count else { return .noChange }`; return `.noChange` if `next == fresh`.
     4. `do { _ = try LayoutBackups.save(fresh) } catch { return .backupFailed }`.
     5. `guard write(next) else { return .writeFailed }`.
     6. If `LIVE_RESORT=yes`: sleep 1 s, return `.applied`.
     7. `if await MenuBarAgentRestarter.restart() { return .applied }`; else `return write(fresh) ? .restartFailedRolledBack : .restartFailedRollbackFailed`.
  3. `private static func write(_ table: [String: Double]) -> Bool`: `CFPreferencesSetAppValue("TrailingItemPreferredPositions" as CFString, table as CFDictionary, LayoutTableFile.preferencesDomain)`; `guard CFPreferencesAppSynchronize(LayoutTableFile.preferencesDomain) else { log; return false }`; poll `readFromDisk()` every 200 ms for up to 2 s until it equals `table`; on timeout log `layout table write failed` and return false.
  4. `@MainActor static func restore(_ url: URL) async -> ApplyResult`: load; preflight; backup current; write; restart; same rollback rule.
  5. Log only the result case name, never keys.
- Verify: no verification needed (task 6.7 covers it).

### Task 6.6 — Backups UI and Debug action

- Target files: `AdvancedSettingsPane.swift`, `DiagnosticsMenu.swift`.
- Steps:
  1. On macOS 27 only, add `SkeinSection("Menu Bar Layout Backups")` listing `LayoutBackups.list()` dates (newest 10) with a "Restore…" button per row. The button shows an `NSAlert`: "Restore the menu bar layout from <date>? The menu bar reloads once." with "Restore" and "Cancel". On "Restore", call `LayoutTableWriter.restore(url)` and show the result case in an alert when it is not `.applied`.
  2. When `LayoutTableFile.access()` is `.denied`, show instead: "Full Disk Access is required to restore layouts on macOS 27" and a button opening the settings URL.
  3. Debug action "Move First Visible Item to Hidden": build a `.leftOf(key: <table key of the rightmost third-party visible item>, target: <HItem key>)` move, confirm with an `NSAlert`, call `apply`, log `diag apply result=<case>`.
- Verify: Debug build prints `** BUILD SUCCEEDED **` AND `grep -c "allPermissions" Skein/Permissions/PermissionsManager.swift` is unchanged from `main` (`git diff main -- Skein/Permissions/PermissionsManager.swift | wc -l` prints `0`).

### Task 6.7 — Live verification

- Steps:
  1. Grant Full Disk Access to `/Applications/Skein Dev.app`; `Scripts/run-dev.sh`; relaunch.
  2. Diagnostics → "Dump Layout Table" (note the dump path in the log).
  3. Diagnostics → "Move First Visible Item to Hidden" → confirm.
  4. Diagnostics → "Dump Item Cache" and "Dump Layout Table" again.
  5. Advanced → Menu Bar Layout Backups → Restore the newest backup → confirm; "Dump Layout Table".
  6. Hold the mouse button down on the desktop and trigger step 3 via keyboard (menu opened with Control-click on the Skein icon, arrow keys, Return) to observe a refusal.
  7. `/usr/bin/log show --last 10m --predicate 'subsystem == "com.ariadnev.Skein.dev"' --style compact > .ci-output/p6.log`; compare the first and last dump JSON files with `cmp`.
- Success criteria: step 3 applies once, the item appears in the hidden section, step 5 restores the original table exactly, step 6 is refused without any write.
- Verify: `grep -c "diag apply result=applied" .ci-output/p6.log` prints ≥ 1 AND `grep -c "MenuBarAgent restart timed out" .ci-output/p6.log` prints `0` AND `grep -c "layout table write failed" .ci-output/p6.log` prints `0` AND `grep -c "diag apply result=refused" .ci-output/p6.log` prints ≥ 1 AND `cmp <first dump> <last dump>` exits 0 AND `ls "$HOME/Library/Application Support/com.ariadnev.Skein.dev/LayoutBackups" | wc -l` prints ≥ 2.

### Task 6.8 — Lint, release build, commit, PR

- Commit: `feat(menu-bar): write MenuBarAgent's layout table safely on macOS 27`.
- Verify: Release build succeeds AND `gh pr checks --watch --required` exits 0.

## Security considerations

- The only path Skein writes outside its own container is the MenuBarAgent layout table, through CFPreferences, after a verified backup.
- Skein never reads other Full Disk Access–protected paths and never reads TCC.db.
- Skein only ever runs `killall MenuBarAgent`, after user confirmation; never `cfprefsd` or `ControlCenter`.
- Logs contain result cases and counts, not keys or bundle identifiers.

## Risks

- If Apple changes the table format, `applyMoves` returns nil (missing keys) or the count check fails, so nothing is written.
- Last-resort recovery (documented in phase 8): restore a backup from Advanced settings; otherwise, in a Terminal with Full Disk Access, `defaults delete "$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar" TrailingItemPreferredPositions && killall MenuBarAgent`.

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
