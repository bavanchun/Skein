//
//  CollapseSpacers.swift
//  Skein
//

import Cocoa

/// Manages spacer status items used to push items out of view on wide displays.
@MainActor
final class CollapseSpacers {
    /// Tracks whether spacer creation has been logged during this app launch.
    private static var hasLoggedSpacerCreation = false

    /// Resting length for inactive spacers.
    ///
    /// Resting at 1pt until a keyed spacer is proven to keep its slot at 0.
    static let restingLength: CGFloat = 1

    /// The autosave name of the parent divider.
    private let dividerAutosaveName: String

    /// Underlying status items for spacers.
    private var items: [NSStatusItem] = []

    /// Creates a spacer controller for the given divider autosave name.
    init(dividerAutosaveName: String) {
        self.dividerAutosaveName = dividerAutosaveName
    }

    /// Ensures that at least `count` spacer items have been created.
    func ensureCount(_ count: Int) {
        let initialCount = items.count
        while items.count < count {
            let item = NSStatusBar.system.statusItem(withLength: Self.restingLength)
            let autosaveName = "\(dividerAutosaveName)Spacer\(items.count)"
            item.autosaveName = autosaveName
            item.button?.isEnabled = false
            item.button?.setAccessibilityIdentifier(autosaveName)
            items.append(item)
        }
        if
            items.count > initialCount,
            !Self.hasLoggedSpacerCreation
        {
            Self.hasLoggedSpacerCreation = true
            Logger.collapse.notice("spacers created count=\(items.count); Cmd-drag them right of the divider once")
        }
    }

    /// Applies lengths to active and resting spacers.
    func apply(lengths: [CGFloat]) {
        for (index, item) in items.enumerated() {
            if index < lengths.count {
                item.length = lengths[index]
            } else {
                item.length = Self.restingLength
            }
        }
    }

    /// Removes all spacer status items while preserving their preferred positions.
    func removeAll() {
        for item in items {
            let autosaveName = item.autosaveName as String
            let cached = StatusItemDefaults[.preferredPosition, autosaveName]
            NSStatusBar.system.removeStatusItem(item)
            StatusItemDefaults[.preferredPosition, autosaveName] = cached
        }
        items.removeAll()
    }
}

// MARK: - Logger
private extension Logger {
    static let collapse = Logger(category: "Collapse")
}
