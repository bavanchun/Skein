---
phase: 1
title: "P0 — v1.2.2 patch (3 HIGH fixes + About URL + AccentColor)"
status: completed
priority: P0
effort: "0.5 day"
dependencies: []
release: "v1.2.2"
---

# Phase 1: P0 — v1.2.2 patch

## Overview

Fix three HIGH-severity defects surfaced by the 2026-08-28 audit, correct the About-pane 404, and update the app AccentColor from Ice blue to rope orange `#E86A33` to match the new icon identity. Ship as v1.2.2 patch release. Zero feature work in this phase.

## Requirements

### Functional
- Every code change corresponds 1:1 to an audit finding.
- Behavior of every surrounding function preserved.
- v1.2.2 tagged and released; ZIP + DMG uploaded; appcast enclosure byte-matched.

### Non-Functional
- Diff must stay under 60 lines of Swift excluding the AccentColor colorset JSON.
- No new dependencies. No new files except AccentColor json diff.
- No test file added in this phase unless a fix genuinely needs one (KISS).

## Architecture

Four surgical edits + one asset update:

1. `Skein/Utilities/ScreenCapture.swift:63-72` — add `defer { pointer.deallocate() }` immediately after the `allocate(...)` call. This closes the leak that fires on every menu bar item hover.
2. `Skein/MenuBar/Spacing/MenuBarItemSpacingManager.swift:169` — change `break` to `continue` inside the `guard let app else { … }` so a nil `NSRunningApplication` skips that PID rather than aborting the whole relaunch loop.
3. `Skein/Bridging/Bridging.swift:104,122,140` — replace `list[..<Int(realCount)]` with `list.prefix(Int(realCount))` (or `list[..<min(Int(realCount), list.count)]`); apply the same clamp at all three slice sites.
4. `Skein/Settings/SettingsPanes/AboutSettingsPane.swift:23` — replace repo URL `https://github.com/bavanchun/Skein` with `https://github.com/bavanchun/ariadnev-skein`.
5. `Skein/Assets.xcassets/AccentColor.colorset/Contents.json` — replace the Ice blue color values with `#E86A33` rope orange for Any Appearance, keeping the light/dark structure intact.

## Related Code Files

- Modify: `Skein/Utilities/ScreenCapture.swift`
- Modify: `Skein/MenuBar/Spacing/MenuBarItemSpacingManager.swift`
- Modify: `Skein/Bridging/Bridging.swift`
- Modify: `Skein/Settings/SettingsPanes/AboutSettingsPane.swift`
- Modify: `Skein/Assets.xcassets/AccentColor.colorset/Contents.json`
- Modify: `CHANGELOG.md` (add `## [1.2.2] - 2026-08-XX` entry — do not touch other version sections)
- Modify: `Skein.xcodeproj/project.pbxproj` (bump `MARKETING_VERSION` 1.2.1→1.2.2, `CURRENT_PROJECT_VERSION` 1122→1123, both occurrences)

## OUT OF SCOPE (do not touch)

- `MenuBarItemManager.swift` (god-class refactor lives in a later plan).
- Any `MenuBarOverlayPanel.swift` polling changes (deferred).
- Any upstream cherry-picks (P2/P3 phases).
- Any docs beyond `CHANGELOG.md` (P1b docs hygiene phase covers those).
- `Resources/` cleanup (P1b phase).
- Landing page (P1a phase).
- README.md (unless the AccentColor change requires reference — it does not).

## Implementation Steps

1. Branch `feat/phase-01-p0-v1.2.2-patch` from `main`.
2. Apply fix 1 (leak): open ScreenCapture.swift, locate the `allocate` line, insert `defer { pointer.deallocate() }` immediately after. Compile.
3. Apply fix 2 (loop): change `break` → `continue`. Compile.
4. Apply fix 3 (slice): all three sites. Compile.
5. Apply fix 4 (URL): About pane. Compile.
6. Apply fix 5 (accent): replace `Contents.json` color values with rope orange `#E86A33`. Verify Xcode Assets Catalog previews correctly.
7. Bump version: pbxproj (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`), CHANGELOG new section.
8. Build Release: `xcodebuild -project Skein.xcodeproj -scheme Skein -configuration Release build` — must exit 0 with no new warnings compared to `main`.
9. Sign the Release build (Apple Development cert) — verify `codesign -dv Skein.app` clean.
10. Package ZIP + DMG using `Scripts/make-dmg.sh` on the signed build.
11. Verify Sparkle enclosure byte-count matches ZIP size to the byte.
12. Open PR titled `release: 1.2.2 (P0 patch — leak + loop + slice + about + accent)` with a checklist body that mirrors this phase's DoD.

## PM VERIFICATION CHECKLIST (Claude Code runs this before merging)

- [x] `git diff main..HEAD --stat` shows exactly the 7 files listed in Related Code Files (Swift = 4, JSON = 1, CHANGELOG.md, project.pbxproj) — no more, no fewer.
- [x] ScreenCapture.swift diff contains `defer { pointer.deallocate() }`.
- [x] MenuBarItemSpacingManager.swift diff shows `break` → `continue`.
- [x] Bridging.swift diff shows all three slice sites patched (`grep -n 'list\[..<' Bridging.swift` returns 0).
- [x] AboutSettingsPane.swift URL is exactly `https://github.com/bavanchun/ariadnev-skein`.
- [x] AccentColor.colorset Contents.json has `#E86A33` (or its component form 0.910/0.416/0.200) for the "Any Appearance" color.
- [x] pbxproj shows exactly 2 `MARKETING_VERSION = 1.2.2;` lines and 2 `CURRENT_PROJECT_VERSION = 1123;` lines.
- [x] CHANGELOG has a `## [1.2.2] - <date>` section with Fixed subsection listing all 4 code fixes and Changed subsection listing the accent color; version comparison link appended at bottom.
- [x] `xcodebuild ... build` exit 0, warning delta zero.
- [x] `codesign -dv` on release build shows `Identifier=com.ariadnev.Skein`.
- [x] `stat -f %z Skein-1.2.2.zip` == appcast `length="…"` value.
- [x] No changes to any file in OUT OF SCOPE list.

## Success Criteria

- [x] PR opened, CI green, PM verification checklist all boxes ticked.
- [ ] After PM merge and tag: v1.2.2 tag on `main`, GitHub release published with ZIP + DMG, appcast rolled forward, Sparkle self-update from 1.2.1 → 1.2.2 works on a real Mac. — tag, release (ZIP+DMG) and appcast done and byte-verified; self-update tested on hardware 2026-09-05 and **fails**: the appcast placed `sparkle:edSignature` inside `<item>` rather than on `<enclosure>`, so Sparkle rejected the download at validation. Tracked as issue #30. Byte-length matching was verified all along; signature placement never was. The feed was republished with the signatures on the enclosures on 2026-09-05 and the live gate passes; the box stays open until a self-update is re-run on hardware against it.
- [x] `plans/reports/scout-260828-2201-security-quality.md` HIGH-01, HIGH-02, HIGH-03 items marked resolved with PR link.

## Risk Assessment

- **AccentColor RGB accuracy.** Design intent is warm rope orange, exact value picked from icon. Risk: agy inputs wrong hex. Signal: PM diff review, then visual check on running app. Response: PM adjusts hex value directly rather than another agy round-trip.
- **Slice clamp regression.** `list.prefix` vs indexed slice have slightly different semantics if `realCount == 0`. Signal: launch app, open menu bar item search — no crash. Response: revert to indexed with explicit `min()` clamp.
- **Sparkle byte mismatch.** Historic pattern in this repo. Signal: `ls -l ZIP` vs appcast xml diff. Response: regenerate appcast, do not upload until match.

---

## AGY BRIEF (feed this verbatim to agy)

Bạn là developer thực thi Phase 1 của plan `plans/260828-2226-audit-fixes-p0-p3/plan.md`. Đọc kỹ file `phase-01-p0-v1.2.2-patch.md` — đó là hợp đồng của phase này. Không được vượt scope, không được lấy sáng kiến ngoài Related Code Files.

CWD: `/Users/vchun/Codes/My-projects/tools/Menubar-Manager/Skein`
Branch bạn phải tạo: `feat/phase-01-p0-v1.2.2-patch` (từ `main`).

### Skills bắt buộc dùng (không bỏ qua)
- `/ak:scout` — xác nhận vị trí exact của 5 điểm sửa trước khi edit; đọc audit report `plans/reports/scout-260828-2201-security-quality.md` để có bối cảnh.
- `/ak:fix` — cho 3 HIGH fixes.
- `/ak:test` — build Release + spot-check.
- `/ak:code-review` — self-review diff trước khi push.
- `/ak:ship` — chuẩn bị release artifact (ZIP, DMG, appcast) nhưng **không tag, không publish release**.

### Hard rules (vi phạm = phase reject)
1. KHÔNG sửa file nào ngoài danh sách Related Code Files. Không "tiện tay" refactor.
2. KHÔNG `git tag`, KHÔNG `gh release create`, KHÔNG `gh pr merge`. Bạn dừng ở `gh pr create` + CI green.
3. KHÔNG `--force`, KHÔNG `--no-verify`.
4. KHÔNG chạm `/Applications/Skein.app` hoặc `/Applications/Frost.app`.
5. KHÔNG chạm Cloudflare Worker.
6. Nếu bị stuck (build fail, hex value không chắc, conflict): dùng `/ak:advise` gọi kongming, báo lại counsel cho tôi (PM), KHÔNG tự pivot approach.

### Deliverables khi xong
1. PR đã tạo trên `bavanchun/ariadnev-skein`, title đúng format phase quy định.
2. CI xanh.
3. In dòng chính xác cuối cùng: `PHASE_1_DONE: <PR URL>`

Bắt đầu.

## Kongming checkpoint (PM run, không phải agy)

PM invokes `kongming` counsel **before merging** with the following: goal (v1.2.2 patch), what agy did (paste PR summary), evidence (diff, CI status, verification checklist state), the specific question: "Do these 3 bug fixes carry any regression risk I've missed given the calling patterns of ScreenCapture.captureImage, MenuBarItemSpacingManager.applySpacing, and Bridging.getWindowList across the codebase?"
