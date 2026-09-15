# Hidden section does not hide on macOS 27

Date: 2026-09-15. Build: Skein Dev (Debug, `com.ariadnev.Skein.dev`, pid 3030), `main` at c5785d7.

## Summary

Items placed in the hidden section stay visible because macOS 27.0 (installed 2026-09-15 10:30) no longer
reflows the menu bar around an oversized status item. Skein hides a section by setting the hidden control
item's `NSStatusItem.length` to `ControlItem.Lengths.expanded` (10 000 pt), expecting every item to its
left to be pushed off screen. On macOS 27 the length is clamped (~5 000 pt), the left edge stays pinned,
and neighbouring items do not move. The defect is in the OS contract Skein depends on, not in the dev
build; the release build is affected the same way.

A second break shares the cause: status items are no longer per-app windows. `MenuBarAgent`
(`/System/Library/CoreServices/MenuBarAgent.app`) composites the whole bar into one Window Server
window, so `Bridging.getWindowList(option: .menuBarItems)` finds no item windows and
`MenuBarItemManager.cacheItemsIfNeeded()` logs "Missing control item for hidden section" and clears the
item cache. Anything built on item windows (layout editor, moving items, item images, search) cannot work.

## Evidence

1. `InstallHistory.plist`: macOS 27.0 installed 2026-09-15 10:30:26 +07; previous 26.6.2.
2. Skein log, 13:25:24: `[MenuBarItemManager] Missing control item for hidden section`
   (`Skein/MenuBar/MenuBarItems/MenuBarItemManager.swift:342`).
3. `CGWindowListCopyWindowInfo(.optionAll)`: no layer-25 status item windows for any app; Skein Dev owns
   only a zero-size "Skein Bar" window. `CGSGetProcessMenuBarWindowList` returns a single window, id 550,
   owner Window Server, "Menubar", 1800×39.
4. Accessibility (`AXExtrasMenuBar`): Skein Dev hidden control item at x=1284, width 5002 (hide state),
   yet Orca at x=1239 and 1Password at x=1277 stay in place and are visible on screen.
5. Clicking the Skein icon (show on click) toggled the icon between filled and hollow; the screenshots
   before, after the first click and after the second click show identical item layout.
6. Independent probe, no Skein code: a plain `NSStatusItem` set to length 22 → 400 → 3000 → 10000.
   AX width became 402, 3002, 5002 (clamped); every other item kept its x position. Visually the probe
   item turned into a `«` chevron at 400 and vanished at 3000 and 10000.

## Rejected hypotheses

- Dev build isolation (bundle id, XPC service name): the independent probe reproduces the behaviour.
- Missing permissions: the app has Accessibility, AX reads succeed, the Skein control items exist.
- Wrong control item state: AX shows the hidden control item expanded as intended.

## Approaches reported to work on macOS 27

- Spacer items: several status items, each kept under a per-display cliff (an item is dropped once its
  length reaches about half the display width), inflate together so their combined span pushes icons into
  macOS 27's native overflow chevron. Items register under fresh autosave names in order on every launch.
  Source: dwarvesf/hidden PR #392.
- Overlay: borderless windows one level above the menu bar with stacked `NSVisualEffectView` blur paint
  over the hidden zone; icons are activated with `AXPress` through `AXExtrasMenuBar`. Primary display
  only. Source: Itzhaik07/Tidy.
- Bartender 6 beta and BetterTouchTool use an unpublished API that the vendors warn Apple may block.

## Unresolved questions

- Which hiding approach Skein should adopt (spacer items, overlay, or both).
- Whether moving items and the layout editor can be rebuilt on AX positions alone.
- Behaviour on the external 3008 pt display, which was not tested here.
