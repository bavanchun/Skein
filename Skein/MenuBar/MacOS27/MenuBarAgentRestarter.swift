//
//  MenuBarAgentRestarter.swift
//  Skein
//

import ApplicationServices
import Cocoa
import Foundation

/// Safe preflight and restart management for MenuBarAgent on macOS 27.
@MainActor
enum MenuBarAgentRestarter {
    private static let logger = Logger(category: "MenuBarAgentRestarter")
    private static let clockIdentifier = "com.apple.menuextra.clock"
    private static let agentBundleIdentifier = "com.apple.MenuBarAgent"

    /// Indicates whether layout changes take effect immediately without restarting MenuBarAgent,
    /// as measured by live item reordering.
    static let liveResortApplies = true

    /// Indicates whether a restart operation is currently in progress.
    private(set) static var isRestarting = false

    /// Performs preflight checks to determine whether MenuBarAgent can be safely restarted.
    ///
    /// - Parameter checkingRestarting: Whether to check if a restart is already in progress.
    /// - Returns: A human-readable refusal reason if unsafe, or `nil` if safe to proceed.
    static func preflight(checkingRestarting: Bool = true) -> String? {
        if
            checkingRestarting,
            isRestarting
        {
            return "restart in progress"
        }

        if NSEvent.pressedMouseButtons != 0 {
            return "mouse button down"
        }

        let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let onScreenWindows = WindowInfo.getOnScreenWindows()
        if onScreenWindows.contains(where: { $0.layer == popupLevel }) {
            return "a menu is open"
        }

        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleIdentifier)
        for agent in agents {
            if
                let launchDate = agent.launchDate,
                Date().timeIntervalSince(launchDate) < 12
            {
                return "menu bar just restarted"
            }
        }

        return nil
    }

    /// Restarts MenuBarAgent with preflight checks and waits for the replacement process to expose the clock item.
    ///
    /// - Returns: `true` if MenuBarAgent restarted successfully within the timeout, or `false` otherwise.
    static func restart() async -> Bool {
        guard !isRestarting else {
            return false
        }

        isRestarting = true
        defer {
            isRestarting = false
        }

        if preflight(checkingRestarting: false) != nil {
            return false
        }

        let oldPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleIdentifier).map(\.processIdentifier))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["MenuBarAgent"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("killall failed: \(error.localizedDescription)")
            return false
        }

        let startTime = Date()
        let deadline = startTime.addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            let agents = NSRunningApplication.runningApplications(withBundleIdentifier: agentBundleIdentifier)
            if
                let agent = agents.first(where: { !oldPIDs.contains($0.processIdentifier) }),
                containsClock(in: AXUIElementCreateApplication(agent.processIdentifier))
            {
                let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
                logger.notice("MenuBarAgent restarted in \(elapsedMs) ms")
                return true
            }
        }

        logger.notice("MenuBarAgent restart timed out")
        return false
    }

    // MARK: - Accessibility Helpers

    private static func containsClock(in element: AXUIElement, depth: Int = 5) -> Bool {
        let identifier = attribute(kAXIdentifierAttribute, of: element) as? String
        let role = attribute(kAXRoleAttribute, of: element) as? String
        if identifier == clockIdentifier {
            if
                role == nil ||
                role == "AXMenuBarItem"
            {
                return true
            }
        }
        guard depth > 0 else {
            return false
        }
        return children(of: element).contains { containsClock(in: $0, depth: depth - 1) }
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let list = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] else {
            return []
        }
        return list
    }
}
