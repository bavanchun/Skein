<div align="center">
    <img src="Skein/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width=200 height=200>
    <h1>Skein</h1>
</div>

Skein is a menu bar manager for macOS. It hides and shows menu bar items, and gives you a set of tools for arranging and customising the menu bar around them.

It is part of the [Ariadnev](https://ariadnev.com) ecosystem.

**Skein is derived from [Ice](https://github.com/jordanbaird/Ice) by Jordan Baird**, and the overwhelming majority of its source code originates there. Skein is an independent project rather than a maintained fork: it has its own name, releases, and direction, and it is not affiliated with or endorsed by the upstream project. It remains licensed under GPL-3.0, and Jordan Baird's copyright is preserved in [`LICENSE`](LICENSE). See [`docs/UPSTREAM.md`](docs/UPSTREAM.md) for the full provenance record.

![Banner](https://github.com/user-attachments/assets/4423085c-4e4b-4f3d-ad0f-90a217c03470)

[![Download](https://img.shields.io/badge/download-latest-brightgreen?style=flat-square)](https://github.com/bavanchun/Skein/releases/latest)
![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
![Requirements](https://img.shields.io/badge/requirements-macOS%2014%2B-fa4e49?style=flat-square)
[![License](https://img.shields.io/github/license/bavanchun/Skein?style=flat-square)](LICENSE)

## Install

Download the `Skein-<version>.zip` file from the [latest release](https://github.com/bavanchun/Skein/releases/latest) and move the unzipped app into your `Applications` folder.

Skein is signed with a personal development certificate rather than a Developer ID, so on first launch macOS may require you to allow it explicitly in System Settings → Privacy & Security.

Skein needs Accessibility and Screen Recording permissions to manage and capture menu bar items.

### macOS 27

On macOS 27, menu bar architecture changes require specific permissions depending on which features you use:

- **Accessibility**: Required to hide, show, and interact with menu bar items.
- **Screen Recording**: Required to capture and display menu bar item preview images in Menu Bar Layout, item search, and the Skein Bar. Hiding and showing items continues to work without it.
- **Full Disk Access**: Required to rearrange menu bar items by writing to the system menu bar layout table.

Applying a new layout reloads the menu bar once after a confirmation prompt. Layout backups are automatically created before each change and live in **Settings → Advanced → Menu Bar Layout Backups**, where previous layouts can be restored at any time.

When rearranging items, dropping an item into an empty section or the leftmost slot is refused with a message asking you to drop it next to another item. This is deliberate: without an adjacent anchor item in the system layout table, the item would remain visible on the menu bar.

## Features

### Menu bar item management

- [x] Hide menu bar items
- [x] "Always-hidden" menu bar section
- [x] Show hidden menu bar items when hovering over the menu bar
- [x] Show hidden menu bar items when an empty area in the menu bar is clicked
- [x] Show hidden menu bar items by scrolling or swiping in the menu bar
- [x] Automatically rehide menu bar items
- [x] Hide application menus when they overlap with shown menu bar items
- [x] Drag and drop interface to arrange individual menu bar items
- [x] Display hidden menu bar items in a separate bar (e.g. for MacBooks with the notch)
- [x] Search menu bar items
- [x] Menu bar item spacing (BETA)
- [ ] Profiles for menu bar layout
- [ ] Individual spacer items
- [ ] Menu bar item groups
- [ ] Show menu bar items when trigger conditions are met

### Menu bar appearance

- [x] Menu bar tint (solid and gradient)
- [x] Menu bar shadow
- [x] Menu bar border
- [x] Custom menu bar shapes (rounded and/or split)
- [ ] Remove background behind menu bar
- [ ] Rounded screen corners
- [ ] Different settings for light/dark mode

### Hotkeys

- [x] Toggle individual menu bar sections
- [x] Show the search panel
- [x] Enable/disable the Skein Bar
- [x] Show/hide section divider icons
- [x] Toggle application menus
- [ ] Enable/disable auto rehide
- [ ] Temporarily show individual menu bar items

### Other

- [x] Launch at login
- [x] Automatic updates
- [ ] Menu bar widgets

## Why does Skein only support macOS 14 and later?

Skein uses a number of system APIs that are available starting in macOS 14. As such, there are no plans to support earlier versions of macOS.

## Gallery

#### Show hidden menu bar items below the menu bar

![Skein Bar](https://github.com/user-attachments/assets/f1429589-6186-4e1b-8aef-592219d49b9b)

#### Drag-and-drop interface to arrange menu bar items

![Menu Bar Layout](https://github.com/user-attachments/assets/095442ba-f2d0-4bb4-9632-91e26ef8d45b)

#### Customize the menu bar's appearance

![Menu Bar Appearance](https://github.com/user-attachments/assets/8c22c185-c3d2-49bb-971e-e1fc17df04b3)

#### Menu bar item search

![Menu Bar Item Search](https://github.com/user-attachments/assets/d1a7df3a-4989-4077-a0b1-8e7d5a1ba5b8)

#### Custom menu bar item spacing

![Menu Bar Item Spacing](https://github.com/user-attachments/assets/b196aa7e-184a-4d4c-b040-502f4aae40a6)

## Credits

Skein is a fork of [jordanbaird/Ice](https://github.com/jordanbaird/Ice) by Jordan Baird, licensed under GPL-3.0. All original functionality and the overwhelming majority of the source code originate from that project.

## License

Skein is available under the [GPL-3.0 license](LICENSE), inherited from Ice.
