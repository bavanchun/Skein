//
//  MenuBarItemImageCache.swift
//  Skein
//

import Cocoa
import Combine

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// The cached item images.
    @Published private(set) var images = [MenuBarItemInfo: CGImage]()

    /// The screen of the cached item images.
    private(set) var screen: NSScreen?

    /// The height of the menu bar of the cached item images.
    private(set) var menuBarHeight: CGFloat?

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A set of menu bar item infos that have already been attempted for reveal-capture.
    @MainActor
    private var attemptedReveal = Set<MenuBarItemInfo>()

    /// A Boolean value that indicates whether reveal-capture is currently executing.
    @MainActor
    private var isPerformingRevealCapture = false

    /// The date of the last reveal-capture operation.
    @MainActor
    private var lastRevealCaptureDate: Date?

    /// Creates a cache with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the cache.
    @MainActor
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            if MenuBarPlatform.usesMenuBarAgent {
                let hiddenIdentityPublisher = appState.itemManager.$itemCache
                    .map { Set($0[.hidden].map(\.info)) }
                    .removeDuplicates()
                    .mapToVoid()

                Publishers.Merge(
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).mapToVoid(),
                    hiddenIdentityPublisher
                )
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.attemptedReveal.removeAll()
                }
                .store(in: &c)

                let timerPublisher = Timer.publish(every: 3, on: .main, in: .default)
                    .autoconnect()
                    .filter { [weak appState] _ in
                        guard let appState else {
                            return false
                        }
                        let nav = appState.navigationState
                        return nav.isSkeinBarPresented ||
                            nav.isSearchPresented ||
                            (nav.isSettingsPresented && nav.settingsNavigationIdentifier == .menuBarLayout)
                    }
                    .mapToVoid()

                let environmentPublisher = Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .mapToVoid()

                let statePublisher = Publishers.Merge3(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().mapToVoid(),
                    appState.itemManager.$itemCache.removeDuplicates().mapToVoid(),
                    appState.permissionsManager.screenRecordingPermission.$hasPermission.removeDuplicates().mapToVoid()
                )

                Publishers.Merge3(
                    timerPublisher,
                    environmentPublisher,
                    statePublisher
                )
                .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
                .sink { [weak self, weak appState] in
                    guard
                        let self,
                        let appState
                    else {
                        return
                    }
                    guard appState.permissionsManager.screenRecordingPermission.hasPermission else {
                        return
                    }
                    Task {
                        await self.updateCache()
                    }
                }
                .store(in: &c)
            } else {
                Publishers.Merge3(
                    // Update every 3 seconds at minimum.
                    Timer.publish(every: 3, on: .main, in: .default).autoconnect().mapToVoid(),

                    // Update when the active space or screen parameters change.
                    Publishers.Merge(
                        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                    )
                    .mapToVoid(),

                    // Update when the average menu bar color or cached items change.
                    Publishers.Merge(
                        appState.menuBarManager.$averageColorInfo.removeDuplicates().mapToVoid(),
                        appState.itemManager.$itemCache.removeDuplicates().mapToVoid()
                    )
                )
                .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
                .sink { [weak self] in
                    guard let self else {
                        return
                    }
                    Task.detached {
                        if ScreenCapture.cachedCheckPermissions() {
                            await self.updateCache()
                        }
                    }
                }
                .store(in: &c)
            }
        }

        cancellables = c
    }

    /// Logs a reason for skipping the cache.
    private func logSkippingCache(reason: String) {
        Logger.imageCache.debug("Skipping menu bar item image cache as \(reason)")
    }

    /// Returns a Boolean value that indicates whether caching menu bar items failed for
    /// the given section.
    @MainActor
    func cacheFailed(for section: MenuBarSection.Name) -> Bool {
        guard ScreenCapture.cachedCheckPermissions() else {
            return true
        }
        if
            MenuBarPlatform.usesMenuBarAgent,
            section == .hidden || section == .alwaysHidden,
            let controlItem = appState?.menuBarManager.section(withName: section)?.controlItem,
            controlItem.state == .hideItems
        {
            return false
        }
        let items = appState?.itemManager.itemCache[section] ?? []
        guard !items.isEmpty else {
            return false
        }
        let keys = Set(images.keys)
        for item in items where keys.contains(item.info) {
            return false
        }
        return true
    }

    /// Captures the images of the current menu bar items and returns a dictionary containing
    /// the images, keyed by the current menu bar item infos.
    func createImages(for section: MenuBarSection.Name, screen: NSScreen) async -> [MenuBarItemInfo: CGImage] {
        if MenuBarPlatform.usesMenuBarAgent {
            return await createImagesFromStrip(for: section, screen: screen)
        }

        guard let appState else {
            return [:]
        }

        let items = await appState.itemManager.itemCache[section]

        var images = [MenuBarItemInfo: CGImage]()
        let backingScaleFactor = screen.backingScaleFactor
        let displayBounds = CGDisplayBounds(screen.displayID)
        let option: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        let defaultItemThickness = NSStatusBar.system.thickness * backingScaleFactor

        var itemInfos = [CGWindowID: MenuBarItemInfo]()
        var itemFrames = [CGWindowID: CGRect]()
        var windowIDs = [CGWindowID]()
        var frame = CGRect.null

        for item in items {
            guard let windowID = item.windowID else {
                continue
            }
            guard
                // Use the most up-to-date window frame.
                let itemFrame = Bridging.getWindowFrame(for: windowID),
                itemFrame.minY == displayBounds.minY
            else {
                continue
            }
            itemInfos[windowID] = item.info
            itemFrames[windowID] = itemFrame
            windowIDs.append(windowID)
            frame = frame.union(itemFrame)
        }

        if
            let compositeImage = ScreenCapture.captureWindows(windowIDs, option: option),
            CGFloat(compositeImage.width) == frame.width * backingScaleFactor
        {
            for windowID in windowIDs {
                guard
                    let itemInfo = itemInfos[windowID],
                    let itemFrame = itemFrames[windowID]
                else {
                    continue
                }

                let frame = CGRect(
                    x: (itemFrame.origin.x - frame.origin.x) * backingScaleFactor,
                    y: (itemFrame.origin.y - frame.origin.y) * backingScaleFactor,
                    width: itemFrame.width * backingScaleFactor,
                    height: itemFrame.height * backingScaleFactor
                )

                guard let itemImage = compositeImage.cropping(to: frame) else {
                    continue
                }

                images[itemInfo] = itemImage
            }
        } else {
            Logger.imageCache.warning("Composite image capture failed. Attempting to capturing items individually.")

            for windowID in windowIDs {
                guard
                    let itemInfo = itemInfos[windowID],
                    let itemFrame = itemFrames[windowID]
                else {
                    continue
                }

                let frame = CGRect(
                    x: 0,
                    y: ((itemFrame.height * backingScaleFactor) / 2) - (defaultItemThickness / 2),
                    width: itemFrame.width * backingScaleFactor,
                    height: defaultItemThickness
                )

                guard
                    let itemImage = ScreenCapture.captureWindow(windowID, option: option),
                    let croppedImage = itemImage.cropping(to: frame)
                else {
                    continue
                }

                images[itemInfo] = croppedImage
            }
        }

        return images
    }

    /// Captures menu bar item images from the menu bar strip for the given section and screen.
    @MainActor
    private func createImagesFromStrip(
        for section: MenuBarSection.Name,
        screen: NSScreen
    ) async -> [MenuBarItemInfo: CGImage] {
        guard let appState else {
            return [:]
        }
        guard let menuBarSection = appState.menuBarManager.section(withName: section) else {
            return [:]
        }
        if section == .hidden || section == .alwaysHidden {
            if menuBarSection.controlItem.state == .hideItems {
                return [:]
            }
        }

        await appState.itemManager.refreshAccessibilitySnapshot()

        let sectionItems = appState.itemManager.itemCache[section]
        let sectionInfos = Set(sectionItems.map(\.info))
        let snapshot = appState.itemManager.accessibilitySnapshot

        let mainHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? screen.frame.height
        let screenBounds = CGRect(
            x: screen.frame.minX,
            y: mainHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )

        let targetItems = snapshot.filter { item in
            guard sectionInfos.contains(item.info) else {
                return false
            }
            guard
                item.frame.width > 0,
                item.frame.width < 400
            else {
                return false
            }
            return screenBounds.intersects(item.frame) &&
                item.frame.minX >= screen.frame.minX &&
                item.frame.maxX <= screen.frame.maxX
        }

        guard !targetItems.isEmpty else {
            return [:]
        }

        guard let capture = await MenuBarStripCapture.capture(screen: screen) else {
            return [:]
        }

        var result = [MenuBarItemInfo: CGImage]()
        for item in targetItems {
            if let cropped = MenuBarStripCapture.crop(capture, itemFrame: item.frame) {
                result[item.info] = cropped
            }
        }

        return result
    }

    /// Updates the cache for the given sections, without checking whether caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        guard
            let appState,
            let screen = NSScreen.main
        else {
            return
        }

        var newImages = [MenuBarItemInfo: CGImage]()

        for section in sections {
            guard await !appState.itemManager.itemCache[section].isEmpty else {
                continue
            }
            let sectionImages = await createImages(for: section, screen: screen)
            guard !sectionImages.isEmpty else {
                if !MenuBarPlatform.usesMenuBarAgent {
                    Logger.imageCache.warning("Update image cache failed for \(section.logString)")
                }
                continue
            }
            newImages.merge(sectionImages) { (_, new) in new }
        }

        await MainActor.run { [newImages] in
            images.merge(newImages) { (_, new) in new }
        }

        self.screen = screen
        self.menuBarHeight = screen.getMenuBarHeight()
    }

    /// Updates the cache for the given sections, if necessary.
    func updateCache(sections: [MenuBarSection.Name]) async {
        guard let appState else {
            return
        }

        let isSkeinBarPresented = await appState.navigationState.isSkeinBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented

        if !isSkeinBarPresented && !isSearchPresented {
            guard await appState.navigationState.isAppFrontmost else {
                logSkippingCache(reason: "Skein Bar not visible, app not frontmost")
                return
            }
            guard await appState.navigationState.isSettingsPresented else {
                logSkippingCache(reason: "Skein Bar not visible, Settings not visible")
                return
            }
            guard case .menuBarLayout = await appState.navigationState.settingsNavigationIdentifier else {
                logSkippingCache(reason: "Skein Bar not visible, Settings visible but not on Menu Bar Layout")
                return
            }
        }

        guard await !appState.itemManager.isMovingItem else {
            logSkippingCache(reason: "an item is currently being moved")
            return
        }

        guard await !appState.itemManager.itemHasRecentlyMoved else {
            logSkippingCache(reason: "an item was recently moved")
            return
        }

        await updateCacheWithoutChecks(sections: sections)

        if MenuBarPlatform.usesMenuBarAgent {
            await performRevealCaptureHiddenIfNeeded(sections: sections)
        }
    }

    /// Performs reveal-capture for the hidden section on macOS 27 if any hidden items need images.
    @MainActor
    private func performRevealCaptureHiddenIfNeeded(sections: [MenuBarSection.Name]) async {
        guard MenuBarPlatform.usesMenuBarAgent else {
            return
        }
        guard sections.contains(.hidden) else {
            return
        }
        guard let appState else {
            return
        }
        guard
            appState.permissionsManager.screenRecordingPermission.hasPermission,
            CGPreflightScreenCaptureAccess()
        else {
            return
        }

        let isSkeinBarPresented = appState.navigationState.isSkeinBarPresented
        let isSearchPresented = appState.navigationState.isSearchPresented
        let isMenuBarLayoutPresented = appState.navigationState.isSettingsPresented &&
            appState.navigationState.settingsNavigationIdentifier == .menuBarLayout
        guard
            isSkeinBarPresented ||
            isSearchPresented ||
            isMenuBarLayoutPresented
        else {
            return
        }

        guard !appState.itemManager.isMovingItem else {
            return
        }

        guard !isPerformingRevealCapture else {
            return
        }

        if let lastRevealCaptureDate {
            guard Date().timeIntervalSince(lastRevealCaptureDate) >= 30 else {
                return
            }
        }

        let hiddenItems = appState.itemManager.itemCache[.hidden]
        let missingInfos = hiddenItems.map(\.info).filter { info in
            images[info] == nil && !attemptedReveal.contains(info)
        }
        guard !missingInfos.isEmpty else {
            return
        }

        guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }
        guard let screen = NSScreen.main else {
            return
        }

        lastRevealCaptureDate = Date()
        isPerformingRevealCapture = true
        let didChange = hiddenSection.revealForTemporaryUse()
        defer {
            if didChange {
                hiddenSection.concealAfterTemporaryUse()
            }
            isPerformingRevealCapture = false
        }

        try? await Task.sleep(nanoseconds: 400_000_000)

        let newImages = await createImagesFromStrip(for: .hidden, screen: screen)

        attemptedReveal.formUnion(missingInfos)

        Logger.imageCache.notice("reveal-capture hidden items=\(missingInfos.count) images=\(newImages.count)")

        images.merge(newImages) { (_, new) in new }
    }

    /// Updates the cache for all sections, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isSkeinBarPresented = await appState.navigationState.isSkeinBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isSettingsPresented = await appState.navigationState.isSettingsPresented

        var sectionsNeedingDisplay = [MenuBarSection.Name]()
        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isSkeinBarPresented,
            let section = await appState.menuBarManager.skeinBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCache(sections: sectionsNeedingDisplay)
    }
}

// MARK: - Logger

private extension Logger {
    static let imageCache = Logger(category: "MenuBarItemImageCache")
}
