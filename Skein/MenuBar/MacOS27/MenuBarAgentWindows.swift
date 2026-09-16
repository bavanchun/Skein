//
//  MenuBarAgentWindows.swift
//  Skein
//

import AXSwift
import Cocoa

/// Observes MenuBarAgent's per-display menu bar windows through Accessibility.
@MainActor
enum MenuBarAgentWindows {
    /// Observes the menu bar windows and composited slots in MenuBarAgent.
    static func observe() -> [String: MenuBarLayoutMath.DisplayObservation]? {
        guard AXHelpers.isProcessTrusted() else {
            return nil
        }
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
        guard !agents.isEmpty else {
            return nil
        }

        var allWindows: [UIElement] = []
        for agent in agents {
            guard let appElement = AXHelpers.application(for: agent) else {
                continue
            }
            let windows = AXHelpers.children(for: appElement).filter {
                AXHelpers.role(for: $0) == .window
            }
            allWindows.append(contentsOf: windows)
        }

        guard allWindows.count == NSScreen.screens.count else {
            return nil
        }

        var observations = [String: MenuBarLayoutMath.DisplayObservation]()

        for window in allWindows {
            guard let frame = AXHelpers.frame(for: window) else {
                continue
            }
            let children = AXHelpers.children(for: window)
            guard !children.isEmpty else {
                return nil
            }
            let key = "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))"
            var slots: [MenuBarLayoutMath.Slot] = []

            for child in children {
                guard let childFrame = AXHelpers.frame(for: child) else {
                    continue
                }
                let isChevron = AXHelpers.description(for: child) == "Show Hidden Menu Bar Items"
                var identifier: String?
                var pid: pid_t?
                let slotChildren = AXHelpers.children(for: child)
                if
                    let firstChild = slotChildren.first,
                    AXHelpers.role(for: firstChild) == .button
                {
                    identifier = AXHelpers.identifier(for: firstChild)
                    pid = AXHelpers.processIdentifier(for: firstChild)
                }
                slots.append(
                    MenuBarLayoutMath.Slot(
                        frame: childFrame,
                        isChevron: isChevron,
                        identifier: identifier,
                        pid: pid
                    )
                )
            }

            observations[key] = MenuBarLayoutMath.DisplayObservation(
                bar: frame,
                slots: slots
            )
        }

        return observations
    }
}
