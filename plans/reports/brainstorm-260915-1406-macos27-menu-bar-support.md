---
type: brainstorm
date: 2026-09-15
status: accepted
decision: full A + B (user choice)
advice: kongming recommended A then B-lite; user chose full B
inputs:
  - plans/reports/debugger-260915-1332-macos27-hidden-section-not-hiding.md
  - plans/reports/researcher-260915-1340-macos27-menu-bar-hiding-techniques.md
---

# macOS 27 menu bar support for Skein

## Summary

macOS 27 broke both mechanisms Skein is built on. A status item longer than roughly half the display
width is dropped instead of pushing other items off screen, and status items are no longer per-app
windows, so enumeration, images, moving, hit testing and the layout editor all fail. Hiding can be
restored by keeping divider lengths under the cliff and adding spacer items. Reordering other apps'
items works by writing MenuBarAgent's `TrailingItemPreferredPositions` table and restarting
MenuBarAgent, which this session verified. The user chose to rebuild the full feature set (A + B)
rather than the narrower A + B-lite that kongming recommended.

## Contract

**Outcome.** On macOS 27 Skein again hides and shows its hidden and always-hidden sections by click,
hotkey, hover and scroll, lists and shows images of menu bar items, moves items between sections from
the layout editor and search, and positions Skein Bar, on single and multi-display setups. macOS 26 and
earlier behave exactly as today.

**Constraints.**
- Every macOS 27 path is runtime-gated; the macOS ≤26 code path stays unchanged.
- Distribution stays Sparkle, Personal Team signing, not sandboxed. No entitlement-gated Apple SPI
  (`com.apple.private.menubar.allow` is unobtainable).
- No mandatory Full Disk Access. Table access comes from a user grant on the single file (NSOpenPanel),
  with FDA optional.
- No shipped synthetic Cmd-drag for moving items (it reordered the user's items by accident in testing).
- No ScreenCaptureKit streams (they paint a capture pill inside the bar); one-shot captures only.
- Cliff values must be runtime-computed with a defaults override, since Apple already changed internals
  between beta 8 and GM.

**Non-goals.**
- Porting Thaw's macOS 27 engine (not public: PR #773 closed, `thaw-app/prk-bin` unavailable).
- Tidy-style blur overlays.
- Hiding individual items of multi-item apps, or items MenuBarAgent cannot attribute to a bundle
  (iStat-style); these are open problems in Thaw, Bartender and BetterTouchTool too.
- App Store distribution.

**Acceptance criteria.**
1. On the 1800pt notched display, the 3008pt LG and the 1080pt ARZOPA, alone and combined, toggling the
   hidden section hides and reveals items; hidden items are reachable through the native `«` overflow.
2. A runtime self-test reports the divider length as honoured for every screen configuration; a dropped
   divider is detected and the unit stepped down.
3. No "Missing control item for hidden section" log spam on macOS 27.
4. The layout editor and search list real items with names and images, and moving an item between
   sections persists across MenuBarAgent restarts and app relaunches.
5. Show on hover/click/scroll and Skein Bar positioning work on macOS 27.
6. The macOS 26 build path passes the existing CI build and SwiftLint unchanged.

## Options considered

| Option | Depends most on | Fails first when |
|---|---|---|
| A: length cap + spacers (hide/show only) | The drop cliff staying near width/2 | A 27.x release moves the cliff or forbids zero-length spacer slots |
| B-lite: A + AX enumeration + app-icon images + table-write reordering | MenuBarAgent re-reading the table on restart | Apple relocates or locks the table again |
| Full B (chosen): B-lite + real item images, hit testing, temp-show, Skein Bar | Everything above plus one-shot captures of the single "Menubar" window mapped to AX frames | AX frames go stale for pushed items (observed) or capture needs Screen Recording the user declines |
| C: port Thaw | Thaw publishing its engine | Now: source is not public |
| D: blur overlay (Tidy) | Compositor blending | Multi-display, and it cannot reorder |

**Better approaches.** Kongming judged A then B-lite the better fit for a solo maintainer: full B spans
seven subsystems against undocumented internals. The user accepted that trade-off and chose full B; the
plan should phase it so A ships first and each B subsystem is independently shippable.

## Evidence verified this session

- Cliff (1800pt display): 880 pushed items away; 890, 898, 901, 910, 920 were dropped. External: 1480 ok,
  1500 dropped on 3008pt. Proposed unit `floor(narrowest.width / 2) - 64`, clamped `[200, 4900]`; spacer
  count per divider `max(0, ceil(widest.width / unit) - 1)`.
- AX `AXExtrasMenuBar` gives item frames, but frames of pushed-away items stay stale.
- Synthetic Cmd-drag still reorders, but the bar reflows mid-gesture.
- Layout table: `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`,
  key `TrailingItemPreferredPositions`, `status:<bundle-id>::<autosaveName>` → distance from the trailing
  edge. Readable from a CLI process without FDA.
- Table write spike: `defaults write <path> TrailingItemPreferredPositions -dict-add …` persisted and was
  not overwritten, but the bar did not re-sort live. After `killall MenuBarAgent` (launchd respawned it
  in under 5 s) the bar applied the new order. Third-party items reappeared after the restart. Leftover
  probe keys were removed by rewriting the dict.
- MenuBarAgent binary strings (kongming): `legacyPreferredPositions` fallback, `DefaultsKVO`,
  `VisibilityRestrictionServer` gated by `com.apple.private.menubar.allow`.

## Verification to run before or during planning

1. Table read/write from the Skein Dev app process (not the CLI), with and without an NSOpenPanel grant.
2. Whether a write can trigger a re-sort without restarting MenuBarAgent (CFPreferences write through the
   app, distributed notification, or KVO), since a restart flickers every item.
3. Legacy-key seeding: does a fresh item with `NSStatusItem Preferred Position <name>` land at that
   position? Decides spacer placement.
4. Cliff sweep on the LG 3008 and ARZOPA 1080 displays, alone and together.
5. Notch: items pushed past the notch reachable via `«` and draggable back.
6. Zero-length spacer keeps its table slot; `length = 0` divider constraint still works.
7. `controlItem.windowFrame` on 27 for hover and click; fallback to Skein's own AX frame.
8. MenuBarAgent's overflow button appearing in AX as the self-test signal.
9. One-shot `CGWindowListCreateImage` of the "Menubar" window with Screen Recording, cropped by AX frames,
   without a capture pill.

## Risks

- Apple changes the cliff, table location or restart behaviour in 27.x; mitigate with runtime unit,
  self-test, defaults override and a reset-layout tool.
- Restarting MenuBarAgent to apply order flickers the whole bar; batch moves into one restart.
- Stale AX frames break image cropping and hit testing for hidden items; capture only while revealed.
- Full B scope is large for one maintainer; phase so A ships independently.

## Handoff

Next: `/ak:plan --advice` with this contract, phased as A (hide/show) first, then B subsystems
(enumeration, images, moving, events, Skein Bar), each with its own acceptance evidence.

## Unresolved questions

- Can Skein trigger a re-sort without restarting MenuBarAgent?
- Does the NSOpenPanel grant work for a non-sandboxed, Personal Team signed app, or is FDA required here?
- Exact cliff behaviour on the 1080pt portrait ARZOPA display.
