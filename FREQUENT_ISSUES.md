# Frequent Issues <!-- omit in toc -->

- [Items are moved to the always-hidden section](#items-are-moved-to-the-always-hidden-section)
- [Skein removed an item](#skein-removed-an-item)
- [Skein does not remember the order of items](#skein-does-not-remember-the-order-of-items)
- [How do I solve the `Skein cannot arrange menu bar items in automatically hidden menu bars` error?](#how-do-i-solve-the-skein-cannot-arrange-menu-bar-items-in-automatically-hidden-menu-bars-error)
- [Items do not hide on macOS 27](#items-do-not-hide-on-macos-27)
- [Menu bar layout looks wrong after rearranging](#menu-bar-layout-looks-wrong-after-rearranging)
- [Drop this item next to another item on macOS 27](#drop-this-item-next-to-another-item-on-macos-27)
- [Spacers appeared left of the divider on macOS 27](#spacers-appeared-left-of-the-divider-on-macos-27)

## Items are moved to the always-hidden section

By default, macOS adds new items to the far left of the menu bar, which is also the location of Skein's always-hidden section. Most apps are configured
to remember the positions of their items, but some are not. macOS treats the items of these apps as new items each time they appear. This results in
these items appearing in the always-hidden section, even if they have been previously been moved.

Skein does not currently manage individual items, and in fact cannot, as of the current release. Once upstream Ice issues
[#6](https://github.com/jordanbaird/Ice/issues/6) and [#26](https://github.com/jordanbaird/Ice/issues/26) are implemented, Skein will be able to
monitor the items in the menu bar, and move the ones it recognizes to their previous locations, even if macOS rearranges them. Both numbers refer to
[jordanbaird/Ice](https://github.com/jordanbaird/Ice), the project Skein is forked from — not to issues in this repository.

## Skein removed an item

Skein does not have the ability to move or remove items. It likely got placed in the always-hidden section by macOS. Option + click the Skein icon to show
the always-hidden section, then Command + drag the item into a different section.

## Skein does not remember the order of items

This is not a bug, but a missing feature. It is being tracked upstream in [jordanbaird/Ice#26](https://github.com/jordanbaird/Ice/issues/26).

## How do I solve the `Skein cannot arrange menu bar items in automatically hidden menu bars` error?

1. Open `System Settings` on your Mac
2. Go to `Control Center`
3. Select `Never` as shown in the image below
4. Update your `Menu Bar Items` in `Skein`
5. Return `Automatically hide and show the menu bar` to your preferred settings

![Disable Menu Bar Hiding](https://github.com/user-attachments/assets/74c1fde6-d310-4fe3-9f2b-703d8ccb636a)

## Items do not hide on macOS 27

On macOS 27, Skein hides menu bar items by collapsing the space occupied by items positioned to the left of section dividers.

If items fail to hide:
1. Ensure section dividers are enabled in **Settings → Menu Bar Items** and that their icons are visible on your menu bar.
2. Confirm that the items you want to hide are positioned to the left of the hidden section divider. Items to the right of the divider remain visible.
3. If items still do not hide fully on custom or ultrawide displays, an advanced setting `CollapseUnitOverride` is available in defaults. This override only lowers the collapse step length to accommodate specific display geometries and will never raise it beyond the system safety boundary:
   ```bash
   defaults write com.ariadnev.Skein CollapseUnitOverride -float <value>
   ```

## Menu bar layout looks wrong after rearranging

If the menu bar layout becomes disordered or unexpected after applying changes on macOS 27, use Skein's automatic backups to revert:

1. Open **Settings → Advanced**.
2. Scroll to **Menu Bar Layout Backups**.
3. Locate the timestamped backup created before your changes and click **Restore…**. Confirm the prompt; the menu bar will reload once with your restored layout.

As a last resort, if restoring from a backup is not possible or the layout table is severely corrupted, you can reset the system menu bar layout table to default macOS placement. In a Terminal that has been granted Full Disk Access:

```bash
defaults delete "$HOME/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar" TrailingItemPreferredPositions && killall MenuBarAgent
```

> [!WARNING]
> This command completely resets the positions of all third-party menu bar items to system defaults and restarts MenuBarAgent. Only use it if Skein's built-in backup restore cannot recover your layout.

## Drop this item next to another item on macOS 27

When rearranging menu bar items in **Settings → Menu Bar Layout**, dropping an item into an empty section or into the leftmost slot of a section displays an alert asking you to drop it next to another item.

This behavior is deliberate rather than a bug or incomplete feature. On macOS 27, status item positions are managed relative to adjacent items in the system layout table. Placing an item into an empty section or at the far left edge without an adjacent reference item would cause macOS to position it outside the managed collapse boundary, leaving the item visible on the menu bar. To move an item into a section, drop it directly to the left or right of an existing item in that section.

## Spacers appeared left of the divider on macOS 27

When Skein allocates status item spacers on macOS 27, the initial placement of newly created spacer items may land to the left of the section divider.

To resolve this, perform a one-time Command-drag: hold the **Command (⌘)** key and drag each spacer item to the right of the divider. Once moved, macOS retains their positions across reboots and launches.
