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
