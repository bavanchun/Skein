//
//  AccessibilityMenuBarItems.swift
//  Skein
//

import ApplicationServices
import Cocoa

/// Enumerates menu bar items through Accessibility on macOS 27 and later.
enum AccessibilityMenuBarItems {
    private static let layoutTableLogger = Logger(category: "LayoutTable")
    private static let lock = NSLock()
    private static var hasLoggedUnreadableTable = false
    private static var hasLoggedUnidentifiableSkein = false

    /// Control item frames for fallback matching when the layout table is unreadable.
    static var controlItemFrames = [ControlItem.Identifier: CGRect]()

    /// Returns the current menu bar items enumerated via Accessibility.
    ///
    /// This function performs blocking Accessibility calls and must never run
    /// on the main actor.
    nonisolated static func current() -> [MenuBarItem] {
        let table = LayoutTableFile.readFromDisk() ?? LayoutTableFile.readViaPreferences()
        if table == nil {
            lock.lock()
            if !hasLoggedUnreadableTable {
                hasLoggedUnreadableTable = true
                layoutTableLogger.notice("layout table unreadable")
            }
            lock.unlock()
        }

        var thirdPartyItems = [MenuBarItem]()
        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier != "com.apple.MenuBarAgent"
        }

        struct DiscoveredAXItem {
            let element: AXUIElement
            let frame: CGRect
            let pid: pid_t
            let bundleID: String?
        }

        var axItemsByBundle = [String: [DiscoveredAXItem]]()

        for app in runningApps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            guard
                let extrasBarValue = attribute(kAXExtrasMenuBarAttribute, of: appElement),
                CFGetTypeID(extrasBarValue) == AXUIElementGetTypeID()
            else {
                continue
            }
            let extrasBar = unsafeDowncast(extrasBarValue, to: AXUIElement.self)
            let children = children(of: extrasBar).filter {

                role(of: $0) == (kAXMenuBarItemRole as String)
            }
            guard !children.isEmpty else {
                continue
            }

            let bundleID = app.bundleIdentifier ?? ""
            for child in children {
                guard
                    let itemFrame = frame(of: child),
                    itemFrame.width > 0,
                    itemFrame.height > 0
                else {
                    continue
                }
                let item = DiscoveredAXItem(
                    element: child,
                    frame: itemFrame,
                    pid: app.processIdentifier,
                    bundleID: app.bundleIdentifier
                )
                axItemsByBundle[bundleID, default: []].append(item)
            }
        }

        if let table {
            let ordered = MenuBarLayoutMath.orderedKeys(table)
            for (bundleID, items) in axItemsByBundle {
                let bundleKeys = ordered.filter {
                    $0.key.bundleID == bundleID && !$0.key.isModule
                }.map(\.key)

                let allOnScreen = items.allSatisfy { isOnScreen($0.frame) }
                var hasOverlap = false
                if items.count > 1 {
                    for i in 0..<items.count {
                        for j in (i + 1)..<items.count where items[i].frame.intersects(items[j].frame) {
                            hasOverlap = true
                            break
                        }
                        if hasOverlap {
                            break
                        }
                    }
                }

                let framesTrustworthy = allOnScreen && !hasOverlap
                let pairedItems: [DiscoveredAXItem]
                if
                    framesTrustworthy,
                    items.count == bundleKeys.count
                {
                    pairedItems = items.sorted { $0.frame.minX < $1.frame.minX }
                } else {
                    pairedItems = items
                }

                let zipResult = MenuBarLayoutMath.zip(
                    items: pairedItems,
                    keys: bundleKeys,
                    framesTrustworthy: framesTrustworthy
                )

                for (item, key) in zipResult.pairs {
                    let info = MenuBarItemInfo(
                        namespace: .init(item.bundleID),
                        title: key.name
                    )
                    let backing = MenuBarItem.AccessibilityBacking(
                        element: item.element,
                        frame: item.frame,
                        pid: item.pid,
                        bundleID: item.bundleID,
                        tableKey: key.rawKey,
                        isGroupedIdentity: zipResult.grouped
                    )
                    thirdPartyItems.append(MenuBarItem(accessibility: backing, info: info))
                }

                if pairedItems.count > zipResult.pairs.count {
                    for index in zipResult.pairs.count..<pairedItems.count {
                        let item = pairedItems[index]
                        let axIdentifier = stringAttribute(kAXIdentifierAttribute, of: item.element)
                        let axTitle = stringAttribute(kAXTitleAttribute, of: item.element)
                        let title = axIdentifier ?? axTitle ?? ""
                        let info = MenuBarItemInfo(
                            namespace: .init(item.bundleID),
                            title: title
                        )
                        let backing = MenuBarItem.AccessibilityBacking(
                            element: item.element,
                            frame: item.frame,
                            pid: item.pid,
                            bundleID: item.bundleID,
                            tableKey: nil,
                            isGroupedIdentity: true
                        )
                        thirdPartyItems.append(MenuBarItem(accessibility: backing, info: info))
                    }
                }
            }
        } else {
            // Table unreadable fallback
            for (bundleID, items) in axItemsByBundle {
                if bundleID == Constants.bundleIdentifier {
                    // Match Skein control items against known window frames when available
                    lock.lock()
                    let frames = controlItemFrames
                    lock.unlock()

                    for (index, item) in items.enumerated() {
                        var matchedIdentifier: ControlItem.Identifier?
                        for (identifier, controlFrame) in frames {
                            if
                                abs(item.frame.minX - controlFrame.minX) < 2,
                                abs(item.frame.minY - controlFrame.minY) < 2
                            {
                                matchedIdentifier = identifier
                                break
                            }
                        }

                        let title: String
                        if let matchedIdentifier {
                            title = matchedIdentifier.rawValue
                        } else {
                            title = "\(index)"
                            lock.lock()
                            if !hasLoggedUnidentifiableSkein {
                                hasLoggedUnidentifiableSkein = true
                                layoutTableLogger.notice("skein items unidentifiable without layout table")
                            }
                            lock.unlock()
                        }

                        let info = MenuBarItemInfo(namespace: .skein, title: title)
                        let backing = MenuBarItem.AccessibilityBacking(
                            element: item.element,
                            frame: item.frame,
                            pid: item.pid,
                            bundleID: Constants.bundleIdentifier,
                            tableKey: nil,
                            isGroupedIdentity: true
                        )
                        thirdPartyItems.append(MenuBarItem(accessibility: backing, info: info))
                    }
                } else {
                    for item in items {
                        let axIdentifier = stringAttribute(kAXIdentifierAttribute, of: item.element)
                        let axTitle = stringAttribute(kAXTitleAttribute, of: item.element)
                        let title = axIdentifier ?? axTitle ?? ""
                        let info = MenuBarItemInfo(
                            namespace: .init(item.bundleID),
                            title: title
                        )
                        let backing = MenuBarItem.AccessibilityBacking(
                            element: item.element,
                            frame: item.frame,
                            pid: item.pid,
                            bundleID: item.bundleID,
                            tableKey: nil,
                            isGroupedIdentity: true
                        )
                        thirdPartyItems.append(MenuBarItem(accessibility: backing, info: info))
                    }
                }
            }
        }

        // Apple items from MenuBarAgent
        var appleItems = [MenuBarItem]()
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
        if let agent = agents.first {
            let appElement = AXUIElementCreateApplication(agent.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            let axBarItems = findMenuBarItems(in: appElement, maxDepth: 4)

            let moduleKeys = table.map {
                MenuBarLayoutMath.orderedKeys($0).filter(\.key.isModule)
            } ?? []

            for axItem in axBarItems {
                guard
                    let itemFrame = frame(of: axItem),
                    itemFrame.width > 0,
                    itemFrame.height > 0
                else {
                    continue
                }

                let axIdentifier = stringAttribute(kAXIdentifierAttribute, of: axItem)
                let prefix = "com.apple.menuextra."
                if
                    let axIdentifier,
                    axIdentifier.hasPrefix(prefix)
                {
                    let suffix = String(axIdentifier.dropFirst(prefix.count))
                    let isControlCenter = suffix.caseInsensitiveCompare("controlcenter") == .orderedSame
                    let matchingPair = moduleKeys.first { pair in
                        if isControlCenter {
                            return pair.key.name.caseInsensitiveCompare("BentoBox") == .orderedSame
                        } else {
                            return pair.key.name.caseInsensitiveCompare(suffix) == .orderedSame
                        }
                    }

                    let title = matchingPair?.key.name ?? suffix
                    let tableKey = matchingPair?.key.rawKey
                    let info = MenuBarItemInfo(namespace: .controlCenter, title: title)
                    let backing = MenuBarItem.AccessibilityBacking(
                        element: axItem,
                        frame: itemFrame,
                        pid: agent.processIdentifier,
                        bundleID: "com.apple.MenuBarAgent",
                        tableKey: tableKey,
                        isGroupedIdentity: false
                    )
                    appleItems.append(MenuBarItem(accessibility: backing, info: info))
                } else {
                    let axTitle = stringAttribute(kAXTitleAttribute, of: axItem)
                    let title = axIdentifier ?? axTitle ?? ""
                    let info = MenuBarItemInfo(namespace: .controlCenter, title: title)
                    let backing = MenuBarItem.AccessibilityBacking(
                        element: axItem,
                        frame: itemFrame,
                        pid: agent.processIdentifier,
                        bundleID: "com.apple.MenuBarAgent",
                        tableKey: nil,
                        isGroupedIdentity: false
                    )
                    appleItems.append(MenuBarItem(accessibility: backing, info: info))
                }
            }
        }

        let allItems = thirdPartyItems + appleItems

        guard let table else {
            // Unreadable table: order all items by AX x ascending
            return allItems.sorted { $0.frame.minX < $1.frame.minX }
        }

        var keyedItems = [MenuBarItem]()
        var unkeyedItems = [MenuBarItem]()

        for item in allItems {
            if
                case .accessibility(let backing) = item.backing,
                let key = backing.tableKey,
                table[key] != nil
            {
                keyedItems.append(item)
            } else {
                unkeyedItems.append(item)
            }
        }

        keyedItems.sort { lhs, rhs in
            guard
                case .accessibility(let lhsBacking) = lhs.backing,
                case .accessibility(let rhsBacking) = rhs.backing,
                let lhsKey = lhsBacking.tableKey,
                let rhsKey = rhsBacking.tableKey,
                let lhsDist = table[lhsKey],
                let rhsDist = table[rhsKey]
            else {
                return false
            }
            if lhsDist != rhsDist {
                return lhsDist > rhsDist
            }
            return lhsKey < rhsKey
        }

        unkeyedItems.sort { $0.frame.minX < $1.frame.minX }

        var result = keyedItems
        for unkeyed in unkeyedItems {
            if let index = result.firstIndex(where: { $0.frame.minX > unkeyed.frame.minX }) {
                result.insert(unkeyed, at: index)
            } else {
                result.append(unkeyed)
            }
        }

        return result
    }

    // MARK: - Accessibility Helpers

    private static func findMenuBarItems(in element: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        var results = [AXUIElement]()
        func walk(_ current: AXUIElement, depth: Int) {
            if role(of: current) == (kAXMenuBarItemRole as String) {
                results.append(current)
                return
            }
            guard depth < maxDepth else {
                return
            }
            for child in children(of: current) {
                walk(child, depth: depth + 1)
            }
        }
        walk(element, depth: 0)
        return results
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        attribute(name, of: element) as? String
    }

    private static func role(of element: AXUIElement) -> String? {
        stringAttribute(kAXRoleAttribute, of: element)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute(kAXPositionAttribute, of: element),
            let sizeValue = attribute(kAXSizeAttribute, of: element),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let posVal = unsafeDowncast(positionValue, to: AXValue.self)
        let szVal = unsafeDowncast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(posVal, .cgPoint, &position),
            AXValueGetValue(szVal, .cgSize, &size)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func isOnScreen(_ frame: CGRect) -> Bool {
        guard
            frame.width > 0,
            frame.height > 0
        else {
            return false
        }
        var count: UInt32 = 0
        guard
            CGGetActiveDisplayList(0, nil, &count) == .success,
            count > 0
        else {
            return false
        }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else {
            return false
        }
        return displays.contains { display in
            CGDisplayBounds(display).intersects(frame)
        }
    }
}
