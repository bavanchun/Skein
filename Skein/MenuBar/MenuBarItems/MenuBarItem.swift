//
//  MenuBarItem.swift
//  Skein
//

import Cocoa

// MARK: - MenuBarItem

/// A representation of an item in the menu bar.
struct MenuBarItem {
    /// An accessibility-based backing for a menu bar item on macOS 27 and later.
    struct AccessibilityBacking: Hashable {
        /// The underlying accessibility element representing the item.
        let element: AXUIElement

        /// The frame of the item in CoreGraphics screen coordinates.
        let frame: CGRect

        /// The process identifier of the application that created the item.
        let pid: pid_t

        /// The bundle identifier of the owning application, or `nil` if unknown.
        let bundleID: String?

        /// The raw layout table key for the item, or `nil` if unpaired.
        let tableKey: String?

        /// A Boolean value that indicates whether the item's identity was grouped
        /// due to untrustworthy frames or count mismatch.
        let isGroupedIdentity: Bool

        static func == (lhs: AccessibilityBacking, rhs: AccessibilityBacking) -> Bool {
            switch (lhs.tableKey, rhs.tableKey) {
            case let (lhsKey?, rhsKey?):
                return lhsKey == rhsKey
            case (nil, nil):
                return lhs.pid == rhs.pid && lhs.frame == rhs.frame
            default:
                // A keyed and an unkeyed item are never equal, which keeps equality
                // consistent with the hash below.
                return false
            }
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(tableKey ?? "\(pid)")
        }
    }

    /// The backing storage of the menu bar item.
    enum Backing: Hashable {
        case window(WindowInfo)
        case accessibility(AccessibilityBacking)
    }

    /// The item's backing representation.
    let backing: Backing

    /// The menu bar item info associated with this item.
    let info: MenuBarItemInfo

    /// The process identifier of the application that created the item.
    ///
    /// Before macOS 26, this is the same as ``ownerPID``. From macOS 26 on,
    /// item windows are owned by the Control Center, so the creating process
    /// is resolved out of process and may be `nil` if resolution failed.
    let sourcePID: pid_t?

    /// The item's window, or `nil` if backed by Accessibility.
    var window: WindowInfo? {
        switch backing {
        case .window(let window): window
        case .accessibility: nil
        }
    }

    /// The identifier of the item's window, or `nil` if backed by Accessibility.
    var windowID: CGWindowID? {
        window?.windowID
    }

    /// The frame of the item.
    var frame: CGRect {
        switch backing {
        case .window(let window): window.frame
        case .accessibility(let backing): backing.frame
        }
    }

    /// The title of the item.
    var title: String? {
        switch backing {
        case .window(let window):
            window.title
        case .accessibility(let backing):
            if
                let tableKey = backing.tableKey,
                let key = MenuBarLayoutMath.LayoutTableKey(rawKey: tableKey)
            {
                key.name
            } else {
                info.title.isEmpty ? nil : info.title
            }
        }
    }

    /// A Boolean value that indicates whether the item is on screen.
    var isOnScreen: Bool {
        switch backing {
        case .window(let window):
            return window.isOnScreen
        case .accessibility(let backing):
            guard
                backing.frame.width > 0,
                backing.frame.height > 0,
                let primaryScreen = NSScreen.screens.first
            else {
                return false
            }
            let primaryHeight = primaryScreen.frame.height
            return NSScreen.screens.contains { screen in
                let cgFrame = CGRect(
                    x: screen.frame.origin.x,
                    y: primaryHeight - screen.frame.origin.y - screen.frame.height,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
                return cgFrame.intersects(backing.frame)
            }
        }
    }

    /// A Boolean value that indicates whether the item can be moved.
    var isMovable: Bool {
        let immovableItems = Set(MenuBarItemInfo.immovableItems)
        return !immovableItems.contains(info)
    }

    /// A Boolean value that indicates whether the item can be hidden.
    var canBeHidden: Bool {
        let nonHideableItems = Set(MenuBarItemInfo.nonHideableItems)
        return !nonHideableItems.contains(info)
    }

    /// The process identifier of the application that owns the item.
    var ownerPID: pid_t {
        switch backing {
        case .window(let window): window.ownerPID
        case .accessibility(let backing): backing.pid
        }
    }

    /// The name of the application that owns the item.
    ///
    /// This may have a value when ``owningApplication`` does not have
    /// a localized name.
    var ownerName: String? {
        switch backing {
        case .window(let window):
            window.ownerName
        case .accessibility(let backing):
            NSRunningApplication(processIdentifier: backing.pid)?.localizedName
        }
    }

    /// The application that owns the item.
    var owningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: ownerPID)
    }

    /// A name associated with the item that is suited for display to
    /// the user.
    var displayName: String {
        var fallback: String { "Unknown" }
        guard let owningApplication else {
            return ownerName ?? title ?? fallback
        }
        var bestName: String {
            owningApplication.localizedName ??
            ownerName ??
            owningApplication.bundleIdentifier ??
            fallback
        }
        guard let title else {
            return bestName
        }
        // by default, use the application name, but handle a few special cases
        return switch MenuBarItemInfo.Namespace(owningApplication.bundleIdentifier) {
        case .controlCenter:
            switch title {
            case "AccessibilityShortcuts": "Accessibility Shortcuts"
            case "BentoBox": bestName // Control Center
            case "FocusModes": "Focus"
            case "KeyboardBrightness": "Keyboard Brightness"
            case "MusicRecognition": "Music Recognition"
            case "NowPlaying": "Now Playing"
            case "ScreenMirroring": "Screen Mirroring"
            case "StageManager": "Stage Manager"
            case "UserSwitcher": "Fast User Switching"
            case "WiFi": "Wi-Fi"
            default: title
            }
        case .systemUIServer:
            switch title {
            case "TimeMachine.TMMenuExtraHost"/*Sonoma*/, "TimeMachineMenuExtra.TMMenuExtraHost"/*Sequoia*/: "Time Machine"
            default: title
            }
        case MenuBarItemInfo.Namespace("com.apple.Passwords.MenuBarExtra"): "Passwords"
        default:
            bestName
        }
    }

    /// A Boolean value that indicates whether the item is currently
    /// in the menu bar.
    var isCurrentlyInMenuBar: Bool {
        switch backing {
        case .window(let window):
            let list = Set(Bridging.getWindowList(option: .menuBarItems))
            return list.contains(window.windowID)
        case .accessibility:
            return isOnScreen
        }
    }

    /// A string to use for logging purposes.
    var logString: String {
        String(describing: info)
    }

    /// Creates a menu bar item backed by Accessibility.
    init(accessibility: AccessibilityBacking, info: MenuBarItemInfo) {
        self.backing = .accessibility(accessibility)
        self.info = info
        self.sourcePID = accessibility.pid
    }

    /// Creates a menu bar item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    private init(uncheckedItemWindow itemWindow: WindowInfo) {
        self.backing = .window(itemWindow)
        self.info = MenuBarItemInfo(uncheckedItemWindow: itemWindow)
        self.sourcePID = itemWindow.ownerPID
    }

    /// Creates a menu bar item from the given window and source process identifier.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    @available(macOS 26.0, *)
    private init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?) {
        self.backing = .window(itemWindow)
        self.info = MenuBarItemInfo(uncheckedItemWindow: itemWindow, sourcePID: sourcePID)
        self.sourcePID = sourcePID
    }

    /// Creates a menu bar item.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `itemWindow` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter itemWindow: A window that contains information about the item.
    init?(itemWindow: WindowInfo) {
        guard itemWindow.isMenuBarItem else {
            return nil
        }
        self.init(uncheckedItemWindow: itemWindow)
    }

    /// Creates a menu bar item with the given source process identifier.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `itemWindow` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameters:
    ///   - itemWindow: A window that contains information about the item.
    ///   - sourcePID: The process identifier of the application that created the
    ///     item, or `nil` if it could not be resolved.
    @available(macOS 26.0, *)
    init?(itemWindow: WindowInfo, sourcePID: pid_t?) {
        guard itemWindow.isMenuBarItem else {
            return nil
        }
        self.init(uncheckedItemWindow: itemWindow, sourcePID: sourcePID)
    }

    /// Creates a menu bar item with the given window identifier.
    ///
    /// The parameters passed into this initializer are verified during the menu
    /// bar item's creation. If `windowID` does not represent a menu bar item,
    /// the initializer will fail.
    ///
    /// - Parameter windowID: An identifier for a window that contains information
    ///   about the item.
    init?(windowID: CGWindowID) {
        guard let window = WindowInfo(windowID: windowID) else {
            return nil
        }
        self.init(itemWindow: window)
    }
}

// MARK: MenuBarItem Getters
extension MenuBarItem {
    /// Returns an array of the current menu bar items in the menu bar on the given display.
    ///
    /// - Parameters:
    ///   - display: The display to retrieve the menu bar items on. Pass `nil` to return the
    ///     menu bar items across all displays.
    ///   - onScreenOnly: A Boolean value that indicates whether only the menu bar items that
    ///     are on screen should be returned.
    ///   - activeSpaceOnly: A Boolean value that indicates whether only the menu bar items
    ///     that are on the active space should be returned.
    static func getMenuBarItems(on display: CGDirectDisplayID? = nil, onScreenOnly: Bool, activeSpaceOnly: Bool) -> [MenuBarItem] {
        if MenuBarPlatform.usesMenuBarAgent {
            guard Thread.isMainThread else {
                Logger(category: "MenuBarItem").error("sync getMenuBarItems off main on macOS 27")
                return []
            }
            let snapshot = MainActor.assumeIsolated {
                MenuBarItemManager.sharedSnapshotProvider?() ?? []
            }
            return filterAccessibilityItems(snapshot, on: display, onScreenOnly: onScreenOnly)
        }
        return legacyMenuBarItems(on: display, onScreenOnly: onScreenOnly, activeSpaceOnly: activeSpaceOnly)
    }

    /// Filters accessibility-backed items by display bounds and screen visibility.
    private static func filterAccessibilityItems(
        _ items: [MenuBarItem],
        on display: CGDirectDisplayID?,
        onScreenOnly: Bool
    ) -> [MenuBarItem] {
        var result = items
        if let display {
            let bounds = CGDisplayBounds(display)
            result = result.filter { $0.frame.intersects(bounds) }
        }
        if onScreenOnly {
            result = result.filter { $0.isOnScreen }
        }
        return result
    }

    /// Returns an array of the current menu bar items, taking the process that owns
    /// each item's window as the process that created it.
    ///
    /// This is the behavior of every system before macOS 26, and the fallback when
    /// the menu bar item service cannot resolve a creating process.
    private static func legacyMenuBarItems(on display: CGDirectDisplayID?, onScreenOnly: Bool, activeSpaceOnly: Bool) -> [MenuBarItem] {
        let (windowIDs, titlePredicate) = itemWindowIDs(
            on: display,
            onScreenOnly: onScreenOnly,
            activeSpaceOnly: activeSpaceOnly
        )
        return windowIDs.lazy
            .compactMap { windowID in
                MenuBarItem(windowID: windowID)
            }
            .filter(titlePredicate)
            .sortedByOrderInMenuBar()
    }

    /// Returns an array of the current menu bar items in the menu bar on the given
    /// display, resolving the application that created each item.
    ///
    /// On macOS 26 and later, item windows are owned by the Control Center, so the
    /// creating application is resolved through the menu bar item service. Earlier
    /// systems fall back to the synchronous getter, whose owning process is already
    /// the creating one.
    ///
    /// - Parameters:
    ///   - display: The display to retrieve the menu bar items on. Pass `nil` to return the
    ///     menu bar items across all displays.
    ///   - onScreenOnly: A Boolean value that indicates whether only the menu bar items that
    ///     are on screen should be returned.
    ///   - activeSpaceOnly: A Boolean value that indicates whether only the menu bar items
    ///     that are on the active space should be returned.
    static func getMenuBarItems(on display: CGDirectDisplayID? = nil, onScreenOnly: Bool, activeSpaceOnly: Bool) async -> [MenuBarItem] {
        if MenuBarPlatform.usesMenuBarAgent {
            let items = await Task.detached { AccessibilityMenuBarItems.current() }.value
            return filterAccessibilityItems(items, on: display, onScreenOnly: onScreenOnly)
        }

        guard #available(macOS 26.0, *) else {
            return legacyMenuBarItems(on: display, onScreenOnly: onScreenOnly, activeSpaceOnly: activeSpaceOnly)
        }

        let (windowIDs, titlePredicate) = itemWindowIDs(
            on: display,
            onScreenOnly: onScreenOnly,
            activeSpaceOnly: activeSpaceOnly
        )

        var items = [MenuBarItem]()
        for windowID in windowIDs {
            // Check validity before the round trip, so a non-item window
            // never costs a blocking accessibility call in the service.
            guard let window = WindowInfo(windowID: windowID), window.isMenuBarItem else {
                continue
            }
            let itemWindow = MenuBarItemService.ItemWindow(windowID: window.windowID, bounds: window.frame)
            let sourcePID = await MenuBarItemService.Connection.shared.sourcePID(for: itemWindow)
            guard let item = MenuBarItem(itemWindow: window, sourcePID: sourcePID) else {
                continue
            }
            items.append(item)
        }

        return items
            .filter(titlePredicate)
            .sortedByOrderInMenuBar()
    }

    /// Returns the window identifiers of the current menu bar items, along with the
    /// predicate that the items created from them must satisfy.
    private static func itemWindowIDs(
        on display: CGDirectDisplayID?,
        onScreenOnly: Bool,
        activeSpaceOnly: Bool
    ) -> (windowIDs: [CGWindowID], titlePredicate: (MenuBarItem) -> Bool) {
        var option: Bridging.WindowListOption = [.menuBarItems]

        var titlePredicate: (MenuBarItem) -> Bool = { _ in true }
        var boundsPredicate: (CGWindowID) -> Bool = { _ in true }

        if onScreenOnly {
            option.insert(.onScreen)
        }
        if activeSpaceOnly {
            option.insert(.activeSpace)
            titlePredicate = { $0.title != "" }
        }
        if let display {
            let displayBounds = CGDisplayBounds(display)
            boundsPredicate = { windowID in
                guard let windowFrame = Bridging.getWindowFrame(for: windowID) else {
                    return false
                }
                return displayBounds.intersects(windowFrame)
            }
        }

        return (Bridging.getWindowList(option: option).filter(boundsPredicate), titlePredicate)
    }
}

// MARK: MenuBarItem: Equatable
extension MenuBarItem: Equatable {
    static func == (lhs: MenuBarItem, rhs: MenuBarItem) -> Bool {
        lhs.backing == rhs.backing
    }
}

// MARK: MenuBarItem: Hashable
extension MenuBarItem: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(backing)
    }
}

// MARK: MenuBarItemInfo Unchecked Item Window Initializer
private extension MenuBarItemInfo {
    /// Creates a simplified item from the given window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    init(uncheckedItemWindow itemWindow: WindowInfo) {
        if let bundleIdentifier = itemWindow.owningApplication?.bundleIdentifier {
            self.namespace = Namespace(bundleIdentifier)
        } else {
            self.namespace = .null
        }
        if let title = itemWindow.title {
            self.title = title
        } else {
            self.title = ""
        }
    }

    /// Creates a simplified item from the given window, namespaced to the
    /// application that created the item rather than the one that owns its window.
    ///
    /// This initializer does not perform any checks on the window to ensure that
    /// it is a valid menu bar item window. Only call this initializer if you are
    /// certain that the window is valid.
    @available(macOS 26.0, *)
    init(uncheckedItemWindow itemWindow: WindowInfo, sourcePID: pid_t?) {
        var sourceApplication: NSRunningApplication? {
            guard let sourcePID else {
                return nil
            }
            return NSRunningApplication(processIdentifier: sourcePID)
        }
        let application = sourceApplication ?? itemWindow.owningApplication
        if let bundleIdentifier = application?.bundleIdentifier {
            self.namespace = Namespace(bundleIdentifier)
        } else {
            self.namespace = .null
        }
        if let title = itemWindow.title {
            self.title = title
        } else {
            self.title = ""
        }
    }
}
