---
title: "macOS 27 menu bar support — Skein 2.0.0"
description: "Make Skein hide, show, list, image, click and rearrange menu bar items on macOS 27, where MenuBarAgent composites the bar into one window, while macOS 14–26 behave exactly as today."
status: in-progress
priority: P1
effort: "13-16 days"
branch: feat/macos27-menu-bar-support
tags: [feature, macos27, menu-bar, critical]
blockedBy: []
blocks: []
created: 2026-09-15
---

# macOS 27 menu bar support — Skein 2.0.0

## Overview

macOS 27 broke both mechanisms Skein is built on. A status item longer than roughly half the display width is dropped instead of pushing other items off screen, and status items are no longer per-app windows, so enumeration, images, hit testing, temp-show and moving all fail. This plan rebuilds every affected subsystem behind one runtime gate (`MenuBarPlatform.usesMenuBarAgent`) and ships it as a single 2.0.0 release.

Evidence and decisions: [brainstorm](../reports/brainstorm-260915-1406-macos27-menu-bar-support.md), [diagnosis](../reports/debugger-260915-1332-macos27-hidden-section-not-hiding.md), [third-party techniques](../reports/researcher-260915-1340-macos27-menu-bar-hiding-techniques.md), [Apple official sources](../reports/researcher-260915-1650-apple-official-macos27-menu-bar.md).

## Maintainer decisions (do not re-open)

| Topic | Decision |
|---|---|
| Scope | Full rebuild (hide/show, enumeration, images, events, search, Skein Bar, temp-show, moving) |
| Moving other apps' items | Full Disk Access only; no NSOpenPanel grant path; no synthetic Cmd-drag on macOS 27 |
| Hiding on macOS 27 (2026-09-16) | Full Disk Access required. MenuBarAgent rewrites the layout order while items are hidden, so each hide anchors the hidden block through one verified table write. Without it, sections stay shown and a card explains why; Skein Bar, search and images still work |
| Item images | Screen Recording required on macOS 27 for images, Menu Bar Layout and search images; hide/show works without it |
| Applying a new order | Batch changes, restart MenuBarAgent once per apply |
| Release | One release, 2.0.0, after all phases |
| macOS 14–26 | Unchanged; every new path is behind `MenuBarPlatform.usesMenuBarAgent` |

## What Apple documents for macOS 27

Full report: [Apple official sources](../reports/researcher-260915-1650-apple-official-macos27-menu-bar.md).

- Apple documents nothing about MenuBarAgent, single-window compositing, the length cliff or the layout table. Every macOS 27 mechanism in this plan is reverse-engineered and verified on hardware, so each carries a runtime check.
- The only new status item API, `NSStatusItem.expandedInterfaceDelegate` / `NSStatusItemExpandedInterfaceSession` (27.0), covers an app's own item. It cannot read or move other apps' items. ([docs](https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacedelegate))
- macOS 27 Release Notes, System Integrity Protection: access to other developer teams' app data and app group containers is now denied by default, with no prompt. The layout table lives in Apple's `com.apple.MenuBar` group container, so phase 1 spike S2 measures read and write access with and without Full Disk Access before phase 6 depends on it. ([release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes))
- macOS 27 Release Notes, Deprecations: apps can no longer access the local TCC database directly. Skein must detect permissions through public checks (`AXIsProcessTrusted`, ScreenCaptureKit, reading the table file), never TCC.db.
- `NSStatusItem.isVisible` stays `true` when the system temporarily hides an item for lack of space, so it cannot signal a collapsed section. ([docs](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible))

## Phases (execution order = file order)

| # | Phase | Depends on | Effort | Status |
|---|-------|-----------|--------|--------|
| 1 | [Foundation and verification spikes](./phase-01-foundation-and-verification-spikes.md) | — | 2.5d | Partial (PR #35; 3 spikes pending, CLIFF_MARGIN partial) |
| 2 | [Hide and show on macOS 27](./phase-02-hide-show-on-macos27.md) (rewritten: measured unit, then anchored hidden block) | 1 | 4d | In progress |
| 3 | [Accessibility item enumeration and table reader](./phase-03-ax-item-enumeration-and-table-reader.md) | 1, 2 | 3d | Merged (PR #38) |
| 4 | [Events, search, Skein Bar and temp-show](./phase-04-events-search-skein-bar-and-temp-show.md) | 3 | 2d | Merged (PR #40) |
| 5 | [Item images with Screen Recording](./phase-05-item-images-with-screen-recording.md) | 3, 4 | 1.5d | Merged (PR #43) |
| 6 | [Layout table writer and Full Disk Access](./phase-06-layout-table-writer-and-full-disk-access.md) | 3 | 2.5d | Merged (PR #41) |
| 7 | [Item moving](./phase-07-item-moving.md) | 4, 5, 6 | 2d | Merged (PR #44; empty-section drop refused) |
| 8 | [Release 2.0.0](./phase-08-release-2-0-0.md) | 1–7 | 1d | Pending |

After phase 2 merges, the maintainer installs Skein Dev as the daily driver to accumulate real-world cliff evidence. That is not a release.

## Verification toolkit (built in phase 1, used by every phase)

- `Scripts/TestMenuBarLayoutMath.swift` compiles with `Skein/MenuBar/MacOS27/MenuBarLayoutMath.swift` and prints `PASS` — the unit tests for pure logic.
- `Scripts/VerifyMenuBar27.swift` — `ax-dump`, `strip-capture`, `cliff-probe`, non-zero exit on `--expect-contains` failure. No table access: scripts have no bundle ID and are denied Apple's group container on macOS 27.
- Skein Dev "macOS 27 Diagnostics" menu (`#if DEBUG`) — table dump to `~/Library/Caches/<bundle id>/diagnostics/`, item-cache dump, spikes and a Debug move action. All layout-table evidence comes from here.
- Builds: `Skein Dev` (Debug) and `Skein` (Release, unsigned, like CI). SwiftLint in CI is authoritative.
- Runtime lines grepped from `/usr/bin/log show --predicate 'subsystem == "com.ariadnev.Skein.dev"'` saved under `.ci-output/`.

## Non-Negotiable Guardrails

- One short-lived branch per phase (`feat/macos27-p<N>-<slug>`), PR into `main`, squash merge, Conventional Commits (`docs/DEVELOPMENT_WORKFLOW.md`).
- Never edit `~/Library/Group Containers/com.apple.MenuBar/…/com.apple.MenuBar.plist` with file APIs; write only through CFPreferences, read-modify-write, verified on disk, after a timestamped backup (phase 6).
- Every MenuBarAgent restart is confirmed by the user. Nothing restarts it automatically.
- Use `Constants.bundleIdentifier` for Skein's own table keys; never hardcode or duplicate it.
- No new 27-only SDK symbols: the build uses the macOS 26.5 SDK and CI builds with whatever `macos-latest` ships.
- Evidence privacy: the repository is public and Skein logs publicly. Screenshots, dumps and logs stay in `.ci-output/`; committed reports hold pass/fail and counts only; table keys are never logged outside `#if DEBUG`.
- Every phase file carries a Failure Protocol. A failed Verify step stops the phase.

## Success Criteria

- [ ] On macOS 27, hidden and always-hidden sections hide and show by click, hotkey, hover and scroll on the 1800pt notched, 3008pt and 1080pt portrait displays, alone and combined.
- [ ] The runtime self-test logs `collapse self-test honored` for every screen configuration.
- [ ] Menu Bar Layout and search list real items with real images; clicking an item in Skein Bar or search opens its menu.
- [ ] Dragging an item between sections in Menu Bar Layout persists across a MenuBarAgent restart and a Skein relaunch.
- [ ] No `Missing control item for hidden section` log lines on macOS 27.
- [ ] The `Skein` Release build and SwiftLint pass in CI; the macOS ≤26 code paths are unchanged in review.
- [ ] 2.0.0 tagged by the maintainer, appcast enclosure length matches the ZIP.

## Red Team Review

### Session — 2026-09-15
**Findings:** 15 after deduplicating 37 (15 accepted, 0 rejected; one sub-point rejected, see below)
**Severity breakdown:** 6 Critical, 9 High

| # | Finding | Severity | Disposition | Applied To |
|---|---------|----------|-------------|------------|
| 1 | Nine `getMenuBarItems` callers silently get `[]` on macOS 27 (hide app menus, appearance overlay, spacing, layout drop) | Critical | Accept | Phase 3 (route both getters, caller list, task 3.7), Phase 8 rows 14, 19–21 |
| 2 | Write "verification" read back the process cache, so failed writes passed | Critical | Accept | Phase 1 (disk-parsed sentinel spike), Phase 6 (synchronize + on-disk check) |
| 3 | Full-table rewrite could wipe unknown keys or the whole table on a nil read | Critical | Accept | Phase 6 (`applyMoves` read-modify-write, count check, abort on nil) |
| 4 | Self-test step-down re-called a no-op `hide()` and persisted a global override | Critical | Accept | Phase 1 (`learnedCap`), Phase 2 (per-configuration in-memory cap, state re-publish) |
| 5 | Hit-test frames counted the widened divider and spacers; new 1 s main-actor AX timer | Critical | Accept | Phase 4 (exclude own pid, snapshot, no singleton timer) |
| 6 | Temp-show and reveal-capture used `show()`, which opens Skein Bar or returns early | Critical | Accept | Phase 4 (`revealForTemporaryUse`), Phase 5, bounded rehide |
| 7 | `MenuBarItem.windowID` refactor left silently compiling sites (`SkeinBar` `ForEach` id, `ownerName`, `sourcePID`) | High | Accept | Phase 3 task 3.4 review checklist |
| 8 | Spacer positions wiped on removal, bad seeds, always-hidden spacers regrow when disabled | High | Accept | Phase 2 (never remove on screen change, gap seeding, `isAddedToMenuBar` gate) |
| 9 | Pending drags snapped back on cache rebuild; shared instance reset by the repair | High | Accept | Phase 7 (recorded moves + overlay, repair separate) |
| 10 | Table written before restart preflight; no rollback on restart failure | High | Accept | Phase 6 (preflight first, rollback) |
| 11 | Full Disk Access check used an API without errno and changed onboarding | High | Accept | Phase 1 (`open(2)` errno), Phase 6/7 (on demand, not in `allPermissions`) |
| 12 | Screen Recording check: data race, possible prompts, never-refreshing cache | High | Accept | Phase 1 spike S8, Phase 5 (passive `CGPreflightScreenCaptureAccess`) |
| 13 | Automatic MenuBarAgent restarts (launch repair, pane close, restore) | High | Accept | Phase 6/7 (confirmation for every restart) |
| 14 | Verify steps read the table from an unbundled script (denied), so diffs passed vacuously; evidence leaked to a public repo | High | Accept | Phase 1 diagnostics menu, all Verify steps, privacy guardrail |
| 15 | One-time, possibly unwritten, stale backup; wrong last-resort doc | High | Accept | Phase 6 (`LayoutBackups`, keep 10, abort on failure), Phase 8 docs |

Rejected sub-point: removing `ForceLegacyMenuBar`, `CollapseUnitOverride`, the Debug move action and layout backups as scope creep. They are safety and recovery mechanisms required by the plan's "undocumented mechanism with runtime checks" constraint; the override now only lowers the unit and nothing in Skein writes it.

### Whole-Plan Consistency Sweep
- Files reread: plan.md, phase-01 … phase-08.
- Decision deltas checked: 15 (see table), plus spike keys renamed (`READ_WITHOUT_FDA` → `PREFS_READ_WITHOUT_FDA` / `DISK_READ_WITHOUT_FDA`, added `DISK_READ_WITH_FDA`, `SCK_PROMPT_WHEN_DENIED`, `AXPRESS_OFFSCREEN`; 13 keys).
- Stale terms searched: `AccessibilityFrames`, `table-read`, `LayoutTableReader`, `canonicalDistances`, `FullDiskAccessPermission`, `onDisappear` auto-apply, `ResetControl`.
- Unresolved contradictions: 0.

## Validation Log

### Session 1 — 2026-09-15
**Trigger:** post red-team validation of genuine decision points
**Questions asked:** 4

#### Questions & Answers

1. **[Tradeoffs]** Always-hidden section images: the plan never reveals that section automatically for capture, because revealing can expose icons the user deliberately hid (for example during screen sharing); its slots stay empty until the user shows it once. Keep that?
   - Options: Leave empty until shown manually (Recommended) | Reveal briefly on opening Menu Bar Layout
   - **Answer:** Leave empty until shown manually
   - **Rationale:** Privacy of deliberately hidden items outweighs complete images.
2. **[Risks]** Opening Menu Bar Layout, search or Skein Bar reveals the hidden section for about half a second to capture missing images, once per item set until items or screens change. Acceptable?
   - Options: Accept (Recommended) | Only when opening Menu Bar Layout
   - **Answer:** Accept
   - **Rationale:** Required for real images in search and Skein Bar under the Screen Recording decision.
3. **[Architecture]** Closing Menu Bar Layout with unapplied changes?
   - Options: Ask Apply/Discard/Keep Editing (Recommended) | Discard silently
   - **Answer:** Ask Apply/Discard/Keep Editing
   - **Rationale:** Keeps every MenuBarAgent restart user-confirmed.
4. **[Assumptions]** Up to 6 spacers per divider (12 hidden status items) on the three-display setup, with a one-time Cmd-drag if `LEGACY_SEED=no`. Acceptable?
   - Options: Accept (Recommended) | Spacers for the hidden divider only
   - **Answer:** Accept
   - **Rationale:** Hiding must work on the 3008pt display for both sections.

#### Confirmed Decisions
- Always-hidden images: placeholders until shown — matches phase 5 task 5.5 step 3.
- Hidden-section reveal-capture: accepted — matches phase 5 task 5.5.
- Pane close prompt: three choices — matches phase 7 task 7.5 step 3.
- Spacers on both dividers — matches phase 2 task 2.5.

#### Impact on Phases
- None; all answers confirm the current phase text.

### Whole-Plan Consistency Sweep
- Files reread: plan.md, phase-01 … phase-08.
- Decision deltas checked: 4.
- Reconciled stale references: 0.
- Unresolved contradictions: 0.

## Open questions

- Whether MenuBarAgent can re-sort without a restart (spike S3, `LIVE_RESORT`). If yes, phase 6 skips the restart.
- Whether the app can read the table without Full Disk Access (spike S2). If not, phase 3 lists items without it as specified.
- Whether Full Disk Access lets a Personal Team signed app persist writes to Apple's group container under macOS 27's deny-by-default policy (spike S2, `WRITE_WITH_FDA`). If not, moving is not implementable and the plan stops before phase 6 to ask the maintainer.
