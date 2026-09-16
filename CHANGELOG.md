# Changelog

All notable changes to Skein are recorded here. Skein follows Semantic Versioning; the bump rules and approval gate are defined in [`docs/release-guide.md`](docs/release-guide.md).

## [2.0.0] - 2026-09-16

### Added

- Support for macOS 27: menu bar item hiding, showing, and drag-and-drop arrangement on macOS 27's updated menu bar architecture.
- Menu bar layout backups: automatically creates timestamped backups of the system menu bar layout table before applying changes, with restore functionality available in Settings → Advanced.
- Full Disk Access status banner: guides permission configuration in the Menu Bar Layout pane when running on macOS 27, where rearranging items requires Full Disk Access to write the layout table.

### Changed

- On macOS 27, Screen Recording permission is required to capture and display menu bar item preview images in Menu Bar Layout, item search, and the Skein Bar (section hiding and showing continues to work without it).
- Applying a rearranged layout in Menu Bar Layout on macOS 27 reloads the menu bar once after explicit user confirmation.

### Fixed

- Fixed an issue where hidden menu bar sections did not hide on macOS 27 due to system changes in status item management and window ownership.
- Fixed an issue where Menu Bar Layout showed an empty item list on macOS 27 due to changed status item window attribution.

## [1.4.0] - 2026-09-05

### Changed

- Show-on-hover now listens for pointer movement through a listen-only `CGEvent` tap instead of an `NSEvent` run loop monitor. Mouse tracking elsewhere in the system — hovering a button, sweeping across a toolbar — no longer competes with Skein for the same event delivery, which is where the stutter came from. A tap that macOS disables for overrunning its callback now turns itself back on, so hover keeps working after a burst of load instead of going quiet until the next launch. (Ported from upstream Ice `292556f`, with the recovery branch from `eb5d14a`.)

### Fixed

- On macOS 26, menu bar items are attributed to the app that created them again. macOS 26 changed which process owns an item's window — every menu bar item now reports Control Center as its owner — so Skein saw a bar full of identically-named items, could not tell them apart in Menu Bar Layout, and could not reliably locate its own control items. Skein now resolves each item's real owning process and identifies items by that instead. macOS 14 and 15 are unaffected: they still run the previous owner-based path, which is also the fallback if the helper below cannot be reached.

### Added

- `MenuBarItemService`, an XPC helper embedded in `Skein.app/Contents/XPCServices/`, answers which application created a given menu bar item. The accessibility queries that answer that question can block on an unresponsive app, so they now run in the helper rather than in Skein itself, and a hung status item can no longer stall the interface. The helper accepts connections only from a process signed by the same team.

## [1.3.0] - 2026-09-05

No app behavior changed in this release. It exists to record a documentation and
repository cleanup that had accumulated across the Ice → Frost → Skein renames.

### Changed

- Documentation now matches reality: the upstream lineage table records the Skein bundle identifier from 1.2.0 rather than a 2.0.0 that never shipped, the Sparkle feed address is written as `https://skein.ariadnev.com/appcast.xml` everywhere, the upgrade guide points at whatever release is current instead of a pinned old one, the two issue numbers in `FREQUENT_ISSUES.md` are labelled as upstream Ice issues, and the docs inventory lists every file in `docs/`.
- The release guide's `sign_update` path now points into `.release-output/DerivedData`, where the release build actually puts Sparkle's tools.

### Removed

- 16 MB of unreferenced design assets inherited from Ice: `Resources/Icon.fig`, `Resources/Icon.png`, `Resources/rearranging.gif`, and `Resources/rearranging.mov`. Nothing in the app or the README referenced them.
- `Skein/Resources/Acknowledgements.rtf`, superseded by the PDF the About pane actually loads.
- Migration code for Ice 0.8.0 through 0.11.10. Skein reads preferences under `com.ariadnev.Skein`, a domain that has only ever existed since 1.2.0, so those branches could never fire. One of them logged an error on every launch because its guard could not be satisfied; that noise is gone with it.

## [1.2.2] - 2026-09-05

### Fixed

- Closed memory leak in `ScreenCapture.captureWindows` by ensuring allocated unsafe buffer pointer is deallocated on scope exit.
- Fixed premature loop termination in menu bar item spacing manager so non-matching apps continue instead of aborting the restart loop.
- Clamped CGS window list array slice bounds across private bridging helpers to eliminate out-of-bounds crash risks under high window churn.
- Updated repository URL in the About settings pane to point to the renamed `bavanchun/ariadnev-skein` repository.

### Changed

- Updated application `AccentColor` to warm rope orange (`#E86A33`) to align with the new app icon identity.

## [1.2.1] - 2026-08-28

### Changed

- Skein has its own app icon: a rope tied into an infinity loop on a warm orange field, drawn in Icon Composer so macOS 26 renders it with the system's own material, lighting, and dark and tinted variants. The About tab and search panel mark are redrawn from the same figure. This replaces the last artwork inherited from Ice.

### Added

- `Scripts/make-dmg.sh` builds a disk image for the website download, staging the app beside an `/Applications` shortcut. Sparkle continues to update from the ZIP, so the update feed is unchanged.

## [1.2.0] - 2026-08-23

### Changed

- The app is now **Skein**, part of the Ariadnev ecosystem. Everything visible was renamed: app name, Xcode project and scheme, source folder, Swift symbols, menu titles, and documentation.
- The bundle identifier moved to `com.ariadnev.Skein`. Settings, the menu bar layout, and hotkeys are imported automatically on first launch, so nothing needs to be rebuilt by hand.
- Update checks now resolve through `skein.ariadnev.com` rather than a GitHub repository URL. The feed address is baked into every build, so routing it through an address the project controls means a future move cannot cut off updates again.
- The project left GitHub's fork network and lives at [`bavanchun/ariadnev-skein`](https://github.com/bavanchun/ariadnev-skein). It remains GPL-3.0 and derived from [Ice](https://github.com/jordanbaird/Ice); Jordan Baird's copyright is unchanged.

### Upgrade notes

macOS ties Accessibility and Screen Recording to an app's bundle identifier, so both permissions must be granted again in System Settings → Privacy & Security. Frost can be removed once Skein is running.

## [1.1.0] - 2026-07-28

### Added

- Documented development workflow in [`docs/DEVELOPMENT_WORKFLOW.md`](docs/DEVELOPMENT_WORKFLOW.md): trunk-based branching, pull requests into `main`, Conventional Commits, and the upstream synchronization policy.
- Documented the upstream Ice relationship and sync state in [`docs/UPSTREAM.md`](docs/UPSTREAM.md).

### Changed

- The menu bar icon formerly listed as "Ice Cube" is now **Snowflake**, drawn from SF Symbols. Anyone who had selected the old icon is moved to Snowflake automatically on first launch; nothing needs to be done by hand.
- Release tags are now SSH-signed. `main` is protected: changes reach it through pull requests only.

### Removed

- The Ice Cube image assets, the last Ice-branded artwork outside the app icon.

## [1.0.1] - 2026-07-28

### Fixed

- Removed Sparkle's update-permission prompt, which appeared on first launch with buttons that could not be clicked. As a menu bar accessory app, Frost cannot bring that dialog to the front. Automatic update checks are now on by default and both settings remain available in Settings → About.

### Changed

- Completed the rebrand in files the initial sweep missed: SwiftLint configuration, funding metadata, issue templates, and the code of conduct now refer to Frost and route to this fork.

## [1.0.0] - 2026-07-28

### Changed

- Renamed the application from Ice to Frost across every visible layer: app name, Xcode project and scheme, source folder, Swift symbols, menu titles, and documentation.
- Changed the bundle identifier to `com.vchun.Frost`.

### Upgrade notes

- macOS treats the new bundle identifier as a different application. **Accessibility and Screen Recording permissions must be granted again**, and settings from the previous build are not carried over.
- Remove any older `Ice.app` build to avoid two menu bar icons competing for the same items.

## [0.11.12] - 2026-07-27

### Added

- First personal build of the fork: own bundle identifier, signing identity, copyright, and Sparkle update feed, so it no longer shares preferences or update channel with upstream Ice.

---

Releases before this fork are documented in [jordanbaird/Ice](https://github.com/jordanbaird/Ice/releases).

[Unreleased]: https://github.com/bavanchun/Skein/compare/v2.0.0...HEAD
[2.0.0]: https://github.com/bavanchun/Skein/compare/v1.4.0...v2.0.0
[1.4.0]: https://github.com/bavanchun/Skein/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/bavanchun/Skein/compare/v1.2.2...v1.3.0
[1.2.2]: https://github.com/bavanchun/Skein/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/bavanchun/Skein/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/bavanchun/Skein/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/bavanchun/Skein/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/bavanchun/Skein/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/bavanchun/Skein/compare/v0.11.12...v1.0.0
[0.11.12]: https://github.com/bavanchun/Skein/releases/tag/v0.11.12
