//
//  MenuBarAgentWindows.swift
//  Skein
//

import Cocoa

/// Observes MenuBarAgent's per-display menu bar windows through Accessibility.
@MainActor
enum MenuBarAgentWindows {
    /// Observes the matching slots and notch chevrons in MenuBarAgent's per-display windows.
    static func observe(slotWidth: CGFloat) -> [String: MenuBarLayoutMath.DisplayObservation] {
        guard AXHelpers.isProcessTrusted() else {
            return [:]
        }
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent")
        guard !agents.isEmpty else {
            return [:]
        }

        var observations = [String: MenuBarLayoutMath.DisplayObservation]()

        for agent in agents {
            guard let appElement = AXHelpers.application(for: agent) else {
                continue
            }
            let windows = AXHelpers.children(for: appElement).filter {
                AXHelpers.role(for: $0) == .window
            }
            for window in windows {
                guard let frame = AXHelpers.frame(for: window) else {
                    continue
                }
                let key = "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))"
                let children = AXHelpers.children(for: window)

                var matchingSlots = 0
                var chevrons = 0

                for child in children {
                    if
                        let childFrame = AXHelpers.frame(for: child),
                        abs(childFrame.width - slotWidth) < 1
                    {
                        matchingSlots += 1
                    }
                    if AXHelpers.description(for: child) == "Show Hidden Menu Bar Items" {
                        chevrons += 1
                    }
                }

                observations[key] = MenuBarLayoutMath.DisplayObservation(
                    matchingSlots: matchingSlots,
                    chevrons: chevrons
                )
            }
        }

        return observations
    }
}
