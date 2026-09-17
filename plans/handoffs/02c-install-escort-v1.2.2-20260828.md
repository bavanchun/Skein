---
type: coordinator-brief
supersedes: 02b-install-escort-restart-20260828-1155.md
created: 2026-09-05
filename-note: the 20260828 stamp comes from the phase-02 plan, which names this
  exact path in its PM verification checklist. The brief was written 2026-09-05.
plan: plans/260828-2226-audit-fixes-p0-p3/phase-02-p1a-landing-ship.md
target: Skein v1.2.2 (build 1123)
---

# Coordinator brief — Skein v1.2.2 upgrade + screenshot capture

Read this file first. `02b-install-escort-restart-20260828-1155.md` stays
authoritative on rationale and safety reasoning; where the two disagree on
**current machine state**, this file wins — the machine has moved on since 02b
was written.

## Your role

**You are an escort, not an operator.** The maintainer performs every step on
their own machine. You explain, you verify, you gate. You do not open
Skein.app, you do not capture the screenshots, and you do not run anything
against `/Applications`.

## What changed since 02b — verified on 2026-09-05

02b was written for a machine where Frost was installed and Skein had never
launched. **That is no longer the situation.** Verified read-only just now:

| Check | 02b (2026-08-28) | Now (2026-09-05) |
|---|---|---|
| `/Applications/Frost.app` | exists | **gone** |
| `/Applications/Skein.app` | absent | **present, v1.2.1 (build 1122), running** |
| `com.vchun.Frost` defaults domain | present | **gone** |
| `com.ariadnev.Skein` defaults domain | absent | **present, 38 keys** |
| `~/frost-prefs-backup-260828.plist` | created | **still present, 65 KB** |

So steps 1–8 of `docs/upgrade-frost-to-skein.md` have **already been completed**
by the maintainer. The one-shot migration gate that 02b guarded is closed, and
it closed successfully.

### The migration is verified, not assumed

Diffing `~/frost-prefs-backup-260828.plist` (37 keys) against the live
`com.ariadnev.Skein` domain (38 keys) accounts for every key:

- **26 keys carried over byte-identical** — spacing, rehide strategy and
  interval, section toggles, hover/click/scroll behaviour, dividers, window
  frames, and the rest.
- **5 keys renamed Frost→Skein, values intact:**
  `CustomFrostIconIsTemplate`→`CustomSkeinIconIsTemplate` (`false`),
  `FrostBarLocation`→`SkeinBarLocation` (`0`),
  `ShowFrostIcon`→`ShowSkeinIcon` (`true`),
  `UseFrostBar`→`UseSkeinBar` (`false`),
  `FrostIcon`→`SkeinIcon` (same `Dot` / `DotFill` / `DotStroke` payload; the
  bytes differ only in JSON key order).
- **6 keys differ by live drift, not by loss:** `Hotkeys` (only the
  `EnableFrostBar`→`EnableSkeinBar` rename — all six bindings present and every
  key combination equal, including that one), `MenuBarAppearanceConfigurationV2`,
  two `NSStatusItem Preferred Position` entries, one `NSWindow Frame`, and
  Sparkle's `SULastCheckTime`.
- **1 key is new:** `hasMigrated2_0_0` — the migration's own completion marker.

Nothing was dropped. Do not re-run the migration and do not reinstall Frost to
"re-check" it.

## Keep the backup

`~/frost-prefs-backup-260828.plist` stays where it is. It is the last remaining
copy of Frost's original preferences and it costs 65 KB. Do not delete it as
part of this phase, and do not tidy it away later without asking.

## What is actually left to do

Two things, in order:

1. Move the running install from **1.2.1 → 1.2.2**.
2. Capture the landing-page screenshots.

---

## Part 1 — Upgrade to v1.2.2

Release: <https://github.com/bavanchun/ariadnev-skein/releases/tag/v1.2.2>

| Asset | Bytes | Notes |
|---|---|---|
| `Skein-1.2.2.zip` | **6,178,231** | recommended; this is what Sparkle downloads |
| `Skein-1.2.2.dmg` | 6,650,272 | alternative |
| `appcast.xml` | 2,632 | the feed asset, not for download |

SHA-256 of the published ZIP:

```
c22274390a16a62738722ffbe52574f6c3f4fbf56aa558d3f40199f3179d88e5
```

The published asset was re-downloaded and confirmed byte-identical to the local
signed build, and the appcast enclosure declares `length="6178231"` — an exact
match, which is the gate Sparkle enforces before it will install anything.

### Path A — Sparkle self-update (preferred)

This is the path to try first, because it also closes the last open box in
phase 1: *"Sparkle self-update from 1.2.1 → 1.2.2 works on a real Mac."* Nobody
has proven that on hardware yet, and 1.2.1 users will take exactly this path.

1. Skein menu → **Check for Updates…**
2. Expect an offer for **1.2.2**. If it says "You're up to date", the feed did
   not reach the app — go to *If Sparkle offers nothing* below.
3. Read the release notes shown in the dialog; they come from the appcast's
   `<description>`. Confirm they describe 1.2.2 (leak fix, loop fix, slice fix,
   About URL, accent colour).
4. **Install Update** → let it download and relaunch.
5. After relaunch: Skein menu → **About Skein** should read **1.2.2**.

Report which of these actually happened. A failure here is a real finding, not
an inconvenience — say so rather than falling through to Path B silently.

**If Sparkle offers nothing:** check `skein.ariadnev.com/appcast.xml` in a
browser. It should show `<sparkle:version>1123</sparkle:version>` at the top.
The feed and the Worker route were both verified live on 2026-09-05, so if the
browser sees 1123 and the app does not, the problem is in the app's feed
handling and is worth a bug before working around it.

### Path B — manual ZIP (fallback only)

Use only if Path A fails, and say that it failed first.

1. Download `Skein-1.2.2.zip` from the release page.
2. Verify before opening:
   ```
   stat -f %z ~/Downloads/Skein-1.2.2.zip     # expect 6178231
   shasum -a 256 ~/Downloads/Skein-1.2.2.zip  # expect c2227439…d88e5
   ```
   If either differs, stop — do not install it.
3. Double-click to unzip → `Skein.app`.
4. Quit the running Skein from its own menu (**Quit Skein**). Do not `pkill`.
5. Drag the new `Skein.app` into `/Applications`, replacing the old one.
6. Launch it.

### Gatekeeper

Skein is signed with an Apple Development (Personal Team) certificate and is
**not notarized**, so a manually-downloaded copy trips Gatekeeper on first
open. A Sparkle-delivered update does not reach Gatekeeper the same way —
Sparkle validates the EdDSA signature itself.

> **Superseded 2026-09-05.** The sentence above is true — Sparkle does validate
> the EdDSA signature itself, and that validation is exactly what killed every
> update. What was wrong is the inference that Path A therefore worked. Every
> published appcast carried `sparkle:edSignature` as a child of `<item>` rather
> than as an attribute of `<enclosure>`, the only place Sparkle reads it, so the
> validation found no signature and rejected the update after downloading it.
> That is issue #30. Use Path B until the feed is republished.

Two ways through it, both fine:

- **System Settings route:** right-click `Skein.app` → **Open** → **Open** in
  the dialog. If macOS still refuses, open **System Settings → Privacy &
  Security**, scroll to the bottom, click **Open Anyway** next to the Skein
  message, then open the app again.
- **Terminal route:** `xattr -dr com.apple.quarantine /Applications/Skein.app`
  then open normally.

No `sudo` is needed for either. If something asks for `sudo`, stop and report
it.

### Permissions

Accessibility and Screen Recording are keyed to the bundle ID, which has not
changed (`com.ariadnev.Skein`), so the existing grants carry across the upgrade.
If macOS drops them anyway — it occasionally does when an app binary is
replaced — re-grant under **System Settings → Privacy & Security →
Accessibility** and **→ Screen Recording**, then quit and reopen Skein.

### Post-upgrade regression checks

The Frost migration is already done, so these four are no longer a data-loss
gate; they are a check that the 1.2.2 binary did not disturb existing settings.
Open **Skein → Settings** and confirm:

1. **Menu Bar Layout** — same items, same sections, same order as before the
   upgrade.
2. **Hotkeys** — all six bindings present: Enable Skein Bar, Search Menu Bar
   Items, Show Section Dividers, Toggle Always-Hidden Section, Toggle
   Application Menus, Toggle Hidden Section.
3. **Appearance** — tint, shadow, split, and colour unchanged.
4. **General** — Show Skein Icon on, icon still `Dot`, bar location unchanged,
   launch-at-login still registered.

Also worth a look, since 1.2.2 changed them:

5. **About pane** — the GitHub link goes to
   `https://github.com/bavanchun/ariadnev-skein` and returns a real page, not a
   404.
6. **Accent colour** — controls render in rope orange `#E86A33`, not the old Ice
   blue.

If any of 1–4 comes up short: stop and report. Frost is gone, so the only
remaining fallback is `~/frost-prefs-backup-260828.plist` — which is exactly why
it is still on disk.

---

## Part 2 — Screenshots for the landing page

`https://skein.ariadnev.com` still ships placeholder mockups. The landing PR is
blocked on real captures, and only the maintainer can take them.

Capture **after** the upgrade, so every shot shows 1.2.2 and the rope-orange
accent rather than the old blue.

### The six shots

| # | Suggested filename | What it shows |
|---|---|---|
| 1 | `menu-bar-cluttered.png` | The menu bar before Skein tidies it — the problem the product solves |
| 2 | `menu-bar-tidied.png` | The same bar with items hidden — the after |
| 3 | `skein-bar-open.png` | The Skein Bar open, sections visible |
| 4 | `settings-hotkeys.png` | Settings → Hotkeys, bindings listed |
| 5 | `settings-appearance.png` | Settings → Appearance, tint/shadow/split controls |
| 6 | `settings-general.png` | Settings → General |

A search-pane shot is a welcome seventh if it is cheap to take.

### Capture settings

- **2560×1600** (Retina), lossless PNG, or JPEG at quality 90.
- Window shots: `⌘⇧4` then `Space`, click the window. Region shots: `⌘⇧4` and
  drag.
- Light mode is the baseline. Dark mode duplicates are welcome but optional —
  suffix them `-dark`.

### Before you press the shutter

- Quiet notifications (Focus on) — no banners, no Dock badges.
- No visible username, email address, filename, or calendar entry that belongs
  to a real person.
- No other menu bar app that would misrepresent what Skein does.
- Clean desktop, neutral wallpaper.
- Nothing in the clock that reads as a 2am debugging session.

### Where to put them

Save to `~/Desktop/skein-shots-260828/`, then move into
`plans/reports/screenshots-260828/` in this repo and tell the coordinator the
path. Do **not** push them to the web repo — the landing stream owns that copy.

---

## Escalate rather than decide

- Sparkle offers no update, or offers one that fails to install.
- Any of the four regression checks comes up short.
- Anything asks for `sudo`.
- A screenshot cannot be taken without leaking something personal.

Report progress to the coordinator; leave findings in `plans/reports/`.
