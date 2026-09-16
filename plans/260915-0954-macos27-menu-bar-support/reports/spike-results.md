# Phase 1 spike results

macOS 27.0 (26A428), Xcode 27.0 (27A266a), three displays attached (3008pt main, 1800pt notched, 1080pt).
Raw evidence stays in `.ci-output/` (gitignored). This file holds values and counts only.

## Recorded

DISK_READ_WITH_FDA=yes
WRITE_WITH_FDA=yes
LIVE_RESORT=yes
RESTART_APPLIES=yes
LEGACY_SEED=no
ZERO_LENGTH_KEEPS_SLOT=yes
CONTROLITEM_WINDOWFRAME=yes
SCK_PILL=yes
AXPRESS_OFFSCREEN=yes

## Pending (not yet measured; not recorded as values)

- S2 `PREFS_READ_WITHOUT_FDA`, `DISK_READ_WITHOUT_FDA`: Full Disk Access was granted before these could be measured. Needs Skein Dev removed from Full Disk Access once, a relaunch, and "Spike: Table Access".
- S8 `SCK_PROMPT_WHEN_DENIED`: needs Screen Recording removed from the terminal host once. The desktop automation host also needs Screen Recording, so this runs with the maintainer present.
- S1 `CLIFF_MARGIN`: partial, no value recorded. With all three displays attached, a new slot of width `length + 16` in each display's MenuBarAgent window gave:
  - 3008pt main display: honored at margins 96, 64, 32 and 16 (lengths 1408–1488); an earlier bracket measured 1496 honored and 1516 dropped, consistent with half width.
  - 1800pt notched display (not main): dropped at every margin (804–884). Lengths 444–524 were honored but folded into the notch chevron. An earlier bracket measured 616 honored and 656 dropped.
  - 1080pt display (not main): dropped at every margin (444–524). An earlier bracket measured 216 honored and 316 dropped.
  - Non-main displays are limited by free space beside the frontmost app's menus and by the notch, not by half their width. This undermines phase 2's `floor(narrowest / 2) - margin` unit and needs a maintainer decision before phase 2. Measuring each display as main is still outstanding.

## Evidence notes

- Backup: "Dump Layout Table" before any write read 14 keys from disk with access granted. After all spikes, a second dump matched the backup exactly (14 keys, 0 changed).
- S2: with Full Disk Access, preferences read, disk read, the sentinel write synchronized and persisted to disk, and cleanup removed it.
- S3: two third-party items from different apps swapped order right after the on-disk write, without a restart, and stayed swapped after a MenuBarAgent restart. Both keys were restored on disk and MenuBarAgent was restarted again.
- S4/S5 (provisional): the seeded preferred position never produced a table key for the new item within 2 seconds, so `LEGACY_SEED=no` by the phase's table criterion; whether the seed still positions the item was not measured (compare Accessibility x, not the table). After 3 seconds at length 0 the item returned to the same Accessibility x; because it had no table key, both placements may simply be default placement, so `ZERO_LENGTH_KEEPS_SLOT=yes` is weak. Phase 2 re-checks both by Accessibility position for a keyed spacer and keeps length 1 as the fallback. Cleanup succeeded.
- S6: streamed debug logs recorded one on-screen frame for the Skein icon. Other logged frames had a zero origin and zero height and still passed the screen-intersection guard, so later phases must reject zero-height frames. Debug-level messages are not persisted on this machine; use `log stream`.
- S7: a privacy indicator dot stayed at the trailing end after three strip captures.
- S9: `AXPRESS_OFFSCREEN=yes` is recorded by the opened menu, not the phase's "result 0" criterion: pressing an off-screen third-party item opened its menu at the left edge of the main display, and the Accessibility call returned -25204 (cannot complete) because the target was inside synchronous menu tracking. The wrong menu location is one more reason phase 4 reveals the section before pressing.
- S2 without Full Disk Access must be measured from Skein Dev launched by Launch Services (`open` or `Scripts/run-dev.sh`), never by executing the binary from a terminal that has Full Disk Access.
- Tooling: the Skein icon is not drawn on any display on macOS 27 while the hidden divider is 10000pt, so the Diagnostics menu is unreachable. Skein Dev (Debug only) also runs each diagnostics action when a distributed notification `<bundle id>.diagnostics` names it.
- Toolchain: Xcode 27's SwiftUI makes `LinearGradient(...).opacity(...)` in CompactSlider 1.1.6–1.2.1 ambiguous. Local spike builds used a patched checkout under `.ci-output/`; the repository fix is still open.

## Phase 2 hardware measurements (2026-09-16)

All three displays attached, measured through MenuBarAgent's Accessibility windows. Raw dumps stay in `.ci-output/`.

- The first collapse design logged `self-test failed` 7 times in about 6 minutes after the spacers were placed right of the hidden divider. The cause was a before/after slot delta probed on an already-applied length. Skein Dev was quit and the spacer positions restored from backup: 6/6 keys verified on disk.
- M1 overflow: items the system moves into the « overflow keep slot frames that overlap each other beside the chevron. Frames still intersect the bar, so overflow is detected by overlap, not by intersection.
- M3 identity: slots have no `AXIdentifier`.
  - On the main display's window, each slot's child is the app's `AXButton`, which exposes the button's title and `setAccessibilityIdentifier` value (2/2 test items).
  - On the other windows the child is an `AXApplication` without an identifier.
- Window children are not in x order.
- M4 ladder: test items of 248pt and 1400pt were added together.
  - The 3008pt window listed both slots (264 and 1416).
  - The 1080pt and 1800pt windows listed only the 264 slot.
  - A 700pt item was dropped on both non-main windows and honored on the main one.
- The 1080pt display already shows an overflow chevron with no Skein items collapsed.
- M5 (cap volatility across frontmost apps): not measured.

## Shared menu bar space (2026-09-16)

Three displays attached, no Skein running for the item tests.

- Divider-only search on Skein Dev: the longest honored lengths were 1496 on the 3008pt main display, 588 on the 1800pt notched display and 280 on the 1080pt display. The next probes up (1560, 652 and 392) were dropped.
- Applying a divider of 264 with spacers of 572 and 1480, each sized from one display's cap alone, dropped the divider:
  - the main display listed spacer slots 588 and 1496 but no divider slot;
  - the 1800pt display listed slot 588 but no divider slot;
  - the 1080pt display listed only the divider.
  - Items share each display's free space, in order from the trailing edge.
- Test items of 264, 292 and 892:
  - 1080pt window: slot 280 only.
  - 1800pt window: slots 280 and 308.
  - Main window: slots 280, 308 and 908.
  - An item that doesn't fit in the remaining space is skipped, while smaller items still fit.
- With those three items present, the main display also listed a fourth slot of 616 (item 600), but not a slot of 1216 (item 1200). The main display's free space is larger than its single-item cap of about 1512.

## Notch regions and resized divider slots (2026-09-16)

- 1800pt notched display, with the ladder applied (divider 264, spacers 292 and 828): the window listed the 308 spacer slot but no divider slot.
  - About 210pt was free right of the notch.
  - A single item of up to 588 fit, left of the notch.
  - Free space on a notched display is two regions, not one.
- Main display: after the divider was lengthened past its cap, the window kept listing the divider at its previous width. A freshly added 4192pt item had no slot on any window.
- Ten app activations with the hidden section collapsed produced no collapse probes.

## Anchoring and spacer sizing (2026-09-16)

Skein Dev with the anchor implementation, then test items with Skein Dev quit. Three displays: 3008pt main, 1800pt notched, 1080pt.

- **The anchor works.** One hide wrote the table once (`layout table apply succeeded`, 23 keys) and logged `collapse anchored count=5`. The four third-party keys of the hidden block moved to 8192-8216, and the hidden set was identical before and after.
- **Quitting while the section was collapsed changed nothing.** The divider's distance and the hidden set were unchanged, and the anchored values survived. The earlier corruption path is closed.
- **One long spacer covers less than several medium ones.** A single item longer than roughly 1500 is dropped on the main display, and a dropped item covers nothing:
  - 264 + 1400: the main display honored both slots, 1696pt total.
  - 264 + 1496: the main display honored only the divider.
  - 900 + 800: both honored, 1732pt total.
- **The main display does show an overflow chevron.** Ten items of 300 gave seven honored slots there (2212pt) and a chevron. Six items of 300 were all honored with no chevron.
- **Spacer size decides which displays keep the divider:**
  - divider 264 with six 300: main honored six spacers and the divider with a chevron; the 1800pt display honored one spacer and the divider; the 1080pt display honored only the divider.
  - divider 264 with four 400: main honored four spacers and the divider without a chevron; both narrower displays honored only the divider.
  - divider 264 with three 500: main honored three spacers and the divider; both narrower displays honored only the divider.
- So spacers must be small enough to pack on the widest display and large enough that narrower displays drop them. On this hardware that is about 400, not the single 1136 the ladder produced.
- Six spacers at the 6-spacer budget, divider 264:
  - six of 400: the main display honored four spacers and the divider, 1944pt, no chevron; both narrower displays honored only the divider.
  - six of 450: the main display honored four spacers and the divider, 2144pt, with a chevron; both narrower displays honored only the divider.
  - Spacers that do not fit are dropped, which costs nothing.
