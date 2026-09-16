---
phase: 5
title: "Item images with Screen Recording"
status: complete
priority: P1
effort: "1.5d"
dependencies: [3, 4]
---

# Phase 5: Item images with Screen Recording

## Goal

On macOS 27, Menu Bar Layout, search and Skein Bar show each item's real menu bar image, captured with ScreenCaptureKit from the menu bar strip and cropped by fresh Accessibility frames, with Screen Recording required for these features and hide/show working without it.

## Context

- Current capture: `Skein/MenuBar/MenuBarItems/MenuBarItemImageCache.swift:102-190` crops a composite of item windows, which do not exist on macOS 27. Updates run on a 3 s timer plus screen, space and `itemCache` changes (`:39-75`).
- Permission: `Skein/Utilities/ScreenCapture.swift:12-44` infers permission from item window titles, and `cachedCheckPermissions()` caches for the process; only `Skein/Main/AppState.swift:149` resets it. `ScreenRecordingPermission` polls `checkPermissions()` every second (`Skein/Permissions/Permission.swift:65-78`).
- The project builds in Swift 5 mode (`SWIFT_VERSION = 5.0`), so the compiler does not catch data races: state written from ScreenCaptureKit callbacks must hop to the main actor.
- Spikes: `SCK_PILL`, `SCK_PROMPT_WHEN_DENIED`.
- Hidden items are pushed away and have stale frames, so a section is captured only while its control item state is `.showItems`. "Hidden" is decided by `controlItem.state == .hideItems`, never by `MenuBarSection.isHidden` (which is false in Skein Bar mode while items stay pushed away).
- Reveals for capture use phase 4's `revealForTemporaryUse()` / `concealAfterTemporaryUse()`. The always-hidden section is never revealed automatically; its slots show placeholders until the user shows it.

## Files to Create / Modify

| Action | Path | Purpose |
|---|---|---|
| Create | `Skein/MenuBar/MacOS27/MenuBarStripCapture.swift` | one-shot strip capture and crop |
| Modify | `Skein/Utilities/ScreenCapture.swift` | passive check on 27 |
| Modify | `Skein/MenuBar/MenuBarItems/MenuBarItemImageCache.swift` | 27 capture path, reveal-capture, attempted set |
| Modify | `Skein/Permissions/Permission.swift` | wording on 27 |
| Modify | `Skein/Settings/SettingsPanes/MenuBarLayoutSettingsPane.swift` | message and placeholder note on 27 |

## Tasks

### Task 5.1 — Branch

- Steps: `git switch main && git pull --ff-only && git switch -c feat/macos27-p5-images`.
- Verify: `git branch --show-current` prints `feat/macos27-p5-images`.

### Task 5.2 — Passive permission check on macOS 27

- Target files: `ScreenCapture.swift`.
- Steps:
  1. At the top of `checkPermissions()`: `if MenuBarPlatform.usesMenuBarAgent { return CGPreflightScreenCaptureAccess() }`. No ScreenCaptureKit call happens in any polled path.
  2. In `cachedCheckPermissions(reset:)`, when `MenuBarPlatform.usesMenuBarAgent`, bypass the cache and return `checkPermissions()`.
- Verify: `grep -c "SCShareableContent" Skein/Utilities/ScreenCapture.swift` prints `1` (the existing request call only).

### Task 5.3 — Strip capture

- Target files: `Skein/MenuBar/MacOS27/MenuBarStripCapture.swift`.
- Steps:
  1. `@MainActor enum MenuBarStripCapture { static func capture(screen: NSScreen) async -> (image: CGImage, originX: CGFloat, scale: CGFloat)? }`.
  2. Guard: return nil unless `CGPreflightScreenCaptureAccess()` is true (so a denied app never triggers a prompt, spike S8).
  3. Rect in global CoreGraphics coordinates: `let mainHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? screen.frame.height`; `CGRect(x: screen.frame.minX, y: mainHeight - screen.frame.maxY, width: screen.frame.width, height: screen.getMenuBarHeight() ?? 24)`.
  4. `let image = try await SCScreenshotManager.captureImage(in: rect)`; on error log `strip capture error <code>` (category `StripCapture`) and return nil. `scale = CGFloat(image.width) / rect.width`.
  5. `static func crop(_ capture: (image: CGImage, originX: CGFloat, scale: CGFloat), itemFrame: CGRect) -> CGImage?`: `capture.image.cropping(to: CGRect(x: (itemFrame.minX - capture.originX) * capture.scale, y: 0, width: itemFrame.width * capture.scale, height: CGFloat(capture.image.height)))`.
- Verify: no verification needed (task 5.6 covers it).

### Task 5.4 — Image cache on macOS 27

- Target files: `MenuBarItemImageCache.swift`.
- Steps:
  1. Gate the timer-driven update on macOS 27 with `appState.permissionsManager.screenRecordingPermission.hasPermission` instead of `ScreenCapture.cachedCheckPermissions()`; on macOS 27 also skip the 3 s timer unless Menu Bar Layout, search or Skein Bar is presented (this satisfies `SCK_PILL=yes` either way).
  2. In `createImages(for:screen:)`: `if MenuBarPlatform.usesMenuBarAgent { return await createImagesFromStrip(for: section, screen: screen) }`.
  3. `createImagesFromStrip`: if the section's `controlItem.state == .hideItems` (for `.hidden`/`.alwaysHidden`), return `[:]`. Otherwise `await appState.itemManager.refreshAccessibilitySnapshot()`, keep snapshot items whose `info` is in `itemCache[section]`, whose frame is on this screen and whose width < 400; capture once; crop each; return `[info: image]`.
- Verify: no verification needed (task 5.6 covers it).

### Task 5.5 — Reveal-capture for the hidden section

- Target files: `MenuBarItemImageCache.swift` (`updateCache()`).
- Steps:
  1. Add `@MainActor private var attemptedReveal: Set<MenuBarItemInfo> = []`, cleared when `itemCache` or screen parameters change.
  2. When `MenuBarPlatform.usesMenuBarAgent`, Screen Recording is granted, Menu Bar Layout / search / Skein Bar is presented, `!appState.itemManager.isMovingItem`, and some `itemCache[.hidden]` items have neither an image nor an entry in `attemptedReveal`: call `hiddenSection.revealForTemporaryUse()`, sleep 400 ms, capture `.hidden` with `createImagesFromStrip` (state is now `.showItems`), add every attempted info to `attemptedReveal`, then `hiddenSection.concealAfterTemporaryUse()` only if the reveal changed state. Log `reveal-capture hidden items=<n> images=<m>`.
  3. Never reveal `.alwaysHidden` automatically. Its slots render the existing empty placeholder until the user shows that section, at which point the normal path captures it.
  4. Merge new images over old ones only for infos present in the new result (existing `merge` semantics).
- Verify: no verification needed (task 5.6 covers it).

### Task 5.6 — Messaging and live verification

- Target files: `Permission.swift`, `MenuBarLayoutSettingsPane.swift`.
- Steps:
  1. In `ScreenRecordingPermission.init`, when `MenuBarPlatform.usesMenuBarAgent`, details = `["Display images of menu bar items.", "Required for Menu Bar Layout, search and Skein Bar images on macOS 27."]`; keep `isRequired: false`.
  2. In `MenuBarLayoutSettingsPane.missingScreenRecordingPermission`, on macOS 27 title = `"Menu Bar Layout requires Screen Recording on macOS 27"`. Under the Always-Hidden bar add the caption `"Show the always-hidden section once to load its images."` on macOS 27.
  3. `Scripts/run-dev.sh`; grant Screen Recording; open Settings → Menu Bar Layout; wait 10 s; open search; enable Skein Bar and open it.
  4. `/usr/bin/log show --last 5m --predicate 'subsystem == "com.ariadnev.Skein.dev"' --style compact > .ci-output/p5.log`.
  5. Revoke Screen Recording for Skein Dev, relaunch, toggle the hidden section twice, open Menu Bar Layout.
- Success criteria: visible and hidden slots show icons; always-hidden shows placeholders plus caption; with Screen Recording revoked hide/show works and the macOS 27 message shows; no consent prompt appears while revoked.
- Verify: `grep -c "reveal-capture hidden" .ci-output/p5.log` prints ≥ 1 AND `grep -c "strip capture error" .ci-output/p5.log` prints `0`. Icons, placeholders, message and absence of a prompt are manual checks recorded in the PR description.

### Task 5.7 — Lint, release build, commit, PR

- Commit: `feat(menu-bar): capture menu bar item images with ScreenCaptureKit on macOS 27`.
- Verify: Release build succeeds AND `gh pr checks --watch --required` exits 0.

## Risks

- macOS may periodically re-ask Screen Recording consent; the passive check reflects revocation within a second.
- The hidden section flashes once when the editor, search or Skein Bar opens with missing images; the attempted set prevents repeats.

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
