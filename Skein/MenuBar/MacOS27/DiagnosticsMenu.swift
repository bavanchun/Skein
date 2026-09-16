//
//  DiagnosticsMenu.swift
//  Skein
//

#if DEBUG
import ApplicationServices
import Cocoa

/// A Debug-only menu that observes and exercises macOS 27's layout table from
/// inside the bundled app, where Apple's group container policy can grant access.
///
/// Logs contain counts and flags only; table keys never leave the process.
@MainActor
enum DiagnosticsMenu {
    private static let logger = Logger(category: "Diagnostics")
    private static let sentinelName = "SkeinSpikeSentinel"
    private static let seedName = "SkeinSpikeSeed"
    private static let clockIdentifier = "com.apple.menuextra.clock"
    private static let agentBundleIdentifier = "com.apple.MenuBarAgent"

    /// Retains the menu item targets for the lifetime of the app.
    private static let target = Target()

    private static var isRemoteTriggerInstalled = false

    private static let actions: [(String, Selector)] = [
        ("Dump Layout Table", #selector(Target.dumpLayoutTable)),
        ("Dump Item Cache", #selector(Target.dumpItemCache)),
        ("Spike: Table Access", #selector(Target.spikeTableAccess)),
        ("Spike: Sentinel Write", #selector(Target.spikeSentinelWrite)),
        ("Spike: Swap Two Items", #selector(Target.spikeSwapTwoItems)),
        ("Spike: Legacy Seed", #selector(Target.spikeLegacySeed)),
        ("Spike: Press Hidden Item", #selector(Target.spikePressHiddenItem)),
    ]

    /// Runs a diagnostics action when a distributed notification names it.
    ///
    /// On macOS 27 the Skein icon can be dropped from the menu bar, which makes the
    /// menu unreachable; this lets the same actions run from a script instead.
    /// Post `<bundle id>.diagnostics` with the action title as the object.
    /// Enable with `defaults write com.ariadnev.Skein.dev DiagnosticsRemoteTrigger -bool true` and relaunch.
    static func installRemoteTrigger() {
        guard Defaults.bool(forKey: .diagnosticsRemoteTrigger) else {
            return
        }
        // Setup can run more than once; a second observer would run every action twice.
        guard !isRemoteTriggerInstalled else {
            return
        }
        isRemoteTriggerInstalled = true
        let name = Notification.Name("\(Constants.bundleIdentifier).diagnostics")
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { notification in
            let title = notification.object as? String
            MainActor.assumeIsolated {
                guard let selector = actions.first(where: { $0.0 == title })?.1 else {
                    logger.notice("diag remote trigger ignored: unknown action")
                    return
                }
                logger.notice("diag remote trigger \(title ?? "")")
                target.perform(selector)
            }
        }
    }

    /// Creates the "macOS 27 Diagnostics" item with its submenu.
    static func make() -> NSMenuItem {
        let item = NSMenuItem(title: "macOS 27 Diagnostics", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "macOS 27 Diagnostics")
        for (title, action) in actions {
            let actionItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            actionItem.target = target
            submenu.addItem(actionItem)
        }
        item.submenu = submenu
        return item
    }

    /// AppKit sends menu actions on the main thread; nested types do not inherit isolation.
    @MainActor
    private final class Target: NSObject {
        @objc func dumpLayoutTable() {
            DiagnosticsMenu.dumpLayoutTable()
        }

        @objc func dumpItemCache() {
            DiagnosticsMenu.dumpItemCache()
        }

        @objc func spikeTableAccess() {
            DiagnosticsMenu.spikeTableAccess()
        }

        @objc func spikeSentinelWrite() {
            Task { await DiagnosticsMenu.spikeSentinelWrite() }
        }

        @objc func spikeSwapTwoItems() {
            Task { await DiagnosticsMenu.spikeSwapTwoItems() }
        }

        @objc func spikeLegacySeed() {
            Task { await DiagnosticsMenu.spikeLegacySeed() }
        }

        @objc func spikePressHiddenItem() {
            DiagnosticsMenu.spikePressHiddenItem()
        }
    }

    // MARK: Actions

    private static func dumpItemCache() {
        let widths = NSScreen.screens.map(\.frame.width)
        let spacers = CollapseController.shared.spacerLengths(for: widths)
        let length = spacers.first ?? 0
        logger.notice("diag collapse spacers=\(spacers.count) length=\(Int(length))")
    }

    private static func dumpLayoutTable() {
        let access = LayoutTableFile.access()
        let disk = LayoutTableFile.readFromDisk()
        let prefs = LayoutTableFile.readViaPreferences()
        logger.notice("diag access=\(access) disk=\(disk.map { String($0.count) } ?? "nil") prefs=\(prefs.map { String($0.count) } ?? "nil")")
        guard let disk else {
            return
        }
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Constants.bundleIdentifier)
                .appendingPathComponent("diagnostics")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("table-\(Int(Date().timeIntervalSince1970)).json")
            let data = try JSONSerialization.data(withJSONObject: disk, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
            logger.notice("diag table dump \(file.path)")
        } catch {
            logger.error("diag table dump failed: \(error.localizedDescription)")
        }
    }

    private static func spikeTableAccess() {
        let access = LayoutTableFile.access()
        let prefsRead = LayoutTableFile.readViaPreferences() != nil
        let diskRead = LayoutTableFile.readFromDisk() != nil
        logger.notice("spike access=\(access) prefsRead=\(prefsRead) diskRead=\(diskRead)")
    }

    private static func spikeSentinelWrite() async {
        guard LayoutTableFile.readFromDisk() != nil else {
            logger.notice("spike sentinel aborted: unreadable")
            return
        }
        let key = "status:\(Constants.bundleIdentifier)::\(sentinelName)"
        let sentinel = 9999.5
        let synced = writePositions { $0[key] = sentinel }
        try? await Task.sleep(for: .seconds(1))
        let persisted = LayoutTableFile.readFromDisk()?[key] == sentinel
        _ = writePositions { $0[key] = nil }
        try? await Task.sleep(for: .seconds(1))
        let cleaned = LayoutTableFile.readFromDisk()?[key] == nil
        logger.notice("spike sentinel synced=\(synced) persisted=\(persisted) cleaned=\(cleaned)")
    }

    private static func spikeSwapTwoItems() async {
        guard let original = LayoutTableFile.readFromDisk() else {
            logger.notice("spike swap aborted: unreadable")
            return
        }
        let candidates = original
            .filter { key, _ in
                guard let bundle = bundleIdentifier(fromStatusKey: key) else {
                    return false
                }
                return !bundle.hasPrefix("com.apple.") && bundle != Constants.bundleIdentifier && firstItemX(forBundle: bundle) != nil
            }
            .sorted { $0.value > $1.value }
        // The order check compares apps, so the two keys must belong to different bundles.
        guard
            let first = candidates.first,
            let second = candidates.first(where: { bundleIdentifier(fromStatusKey: $0.key) != bundleIdentifier(fromStatusKey: first.key) })
        else {
            logger.notice("spike swap aborted: fewer than 2 running third-party apps")
            return
        }
        logger.notice("spike swap keys=2")

        // A larger distance from the trailing edge means further left, so after
        // the swap the second item must sit left of the first.
        _ = writePositions {
            $0[first.key] = second.value
            $0[second.key] = first.value
        }
        try? await Task.sleep(for: .seconds(1))
        let swappedOnDisk = LayoutTableFile.readFromDisk().map { $0[first.key] == second.value && $0[second.key] == first.value } ?? false
        logger.notice("spike swap written=\(swappedOnDisk)")
        try? await Task.sleep(for: .seconds(2))
        logger.notice("spike swap applied-without-restart=\(isSwapped(firstKey: first.key, secondKey: second.key))")

        let restarted = await restartMenuBarAgent()
        try? await Task.sleep(for: .seconds(3))
        logger.notice("spike swap restart=\(restarted) applied-after-restart=\(isSwapped(firstKey: first.key, secondKey: second.key))")

        _ = writePositions {
            $0[first.key] = first.value
            $0[second.key] = second.value
        }
        try? await Task.sleep(for: .seconds(1))
        _ = await restartMenuBarAgent()
        let restored = LayoutTableFile.readFromDisk().map { $0[first.key] == first.value && $0[second.key] == second.value } ?? false
        logger.notice("spike swap restored=\(restored)")
    }

    private static func spikeLegacySeed() async {
        let key = "status:\(Constants.bundleIdentifier)::\(seedName)"
        StatusItemDefaults[.preferredPosition, seedName] = 300
        let item = NSStatusBar.system.statusItem(withLength: 30)
        item.autosaveName = seedName
        item.button?.title = "S"
        try? await Task.sleep(for: .seconds(2))
        let distance = LayoutTableFile.readFromDisk()?[key]
        logger.notice("spike seed distance=\(distance.map { String($0) } ?? "nil")")

        let before = itemX(pid: ProcessInfo.processInfo.processIdentifier, title: "S")
        item.length = 0
        try? await Task.sleep(for: .seconds(3))
        item.length = 30
        try? await Task.sleep(for: .seconds(1))
        let after = itemX(pid: ProcessInfo.processInfo.processIdentifier, title: "S")
        let kept = LayoutTableFile.readFromDisk()?[key] != nil && before != nil && after != nil && abs((before ?? 0) - (after ?? 0)) < 2
        logger.notice("spike zero-length kept=\(kept) before=\(before.map { String(Int($0)) } ?? "nil") after=\(after.map { String(Int($0)) } ?? "nil")")

        NSStatusBar.system.removeStatusItem(item)
        StatusItemDefaults[.preferredPosition, seedName] = nil
        _ = writePositions { $0[key] = nil }
        try? await Task.sleep(for: .seconds(1))
        logger.notice("spike seed cleaned=\(LayoutTableFile.readFromDisk()?[key] == nil)")
    }

    private static func spikePressHiddenItem() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications {
            guard
                app.processIdentifier != ownPID,
                let bundle = app.bundleIdentifier,
                !bundle.hasPrefix("com.apple.")
            else {
                continue
            }
            for element in extrasItems(pid: app.processIdentifier) {
                guard let frame = frame(of: element), !isOnScreen(frame) else {
                    continue
                }
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                logger.notice("spike press-offscreen result=\(result.rawValue)")
                return
            }
        }
        logger.notice("spike press-offscreen aborted: no offscreen third-party item")
    }

    // MARK: Table writes

    /// Read-modify-writes the positions through CFPreferences and synchronizes to disk.
    ///
    /// Aborts when no base dictionary can be read, so an unreadable table is never
    /// replaced by a partial one.
    private static func writePositions(_ modify: (inout [String: Double]) -> Void) -> Bool {
        let domain = LayoutTableFile.preferencesDomain
        guard var positions = LayoutTableFile.readViaPreferences() ?? LayoutTableFile.readFromDisk() else {
            logger.notice("diag write aborted: unreadable")
            return false
        }
        modify(&positions)
        CFPreferencesSetAppValue(LayoutTableFile.positionsKey as CFString, positions as CFDictionary, domain)
        return CFPreferencesAppSynchronize(domain)
    }

    // MARK: MenuBarAgent

    /// Restarts MenuBarAgent and waits until its replacement exposes the clock.
    private static func restartMenuBarAgent() async -> Bool {
        let oldPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleIdentifier).map(\.processIdentifier))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["MenuBarAgent"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("diag killall failed: \(error.localizedDescription)")
            return false
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            let agents = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleIdentifier)
            if
                let agent = agents.first(where: { !oldPIDs.contains($0.processIdentifier) }),
                containsIdentifier(clockIdentifier, in: AXUIElementCreateApplication(agent.processIdentifier), depth: 5)
            {
                return true
            }
        }
        return false
    }

    // MARK: Accessibility

    private static func bundleIdentifier(fromStatusKey key: String) -> String? {
        guard key.hasPrefix("status:"), let range = key.range(of: "::") else {
            return nil
        }
        return String(key[key.index(key.startIndex, offsetBy: 7)..<range.lowerBound])
    }

    private static func isSwapped(firstKey: String, secondKey: String) -> Bool {
        guard
            let firstBundle = bundleIdentifier(fromStatusKey: firstKey),
            let secondBundle = bundleIdentifier(fromStatusKey: secondKey),
            let firstX = firstItemX(forBundle: firstBundle),
            let secondX = firstItemX(forBundle: secondBundle)
        else {
            return false
        }
        return secondX < firstX
    }

    private static func firstItemX(forBundle bundle: String) -> CGFloat? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            return nil
        }
        return extrasItems(pid: app.processIdentifier).compactMap { frame(of: $0)?.minX }.min()
    }

    private static func itemX(pid: pid_t, title: String) -> CGFloat? {
        extrasItems(pid: pid)
            .first { (attribute(kAXTitleAttribute, of: $0) as? String) == title }
            .flatMap { frame(of: $0)?.minX }
    }

    private static func extrasItems(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = attribute(kAXExtrasMenuBarAttribute, of: app) else {
            return []
        }
        // swiftlint:disable:next force_cast
        return children(of: bar as! AXUIElement)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
    }

    private static func containsIdentifier(_ identifier: String, in element: AXUIElement, depth: Int) -> Bool {
        if (attribute(kAXIdentifierAttribute, of: element) as? String) == identifier {
            return true
        }
        guard depth > 0 else {
            return false
        }
        return children(of: element).contains { containsIdentifier(identifier, in: $0, depth: depth - 1) }
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute(kAXPositionAttribute, of: element),
            let sizeValue = attribute(kAXSizeAttribute, of: element)
        else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        guard
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        // swiftlint:enable force_cast
        return CGRect(origin: position, size: size)
    }

    /// Accessibility frames use top-left global coordinates, like `CGDisplayBounds`.
    private static func isOnScreen(_ frame: CGRect) -> Bool {
        guard frame.width > 0 else {
            return false
        }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.contains { CGDisplayBounds($0).contains(center) }
    }
}
#endif
