//
//  MenuBarLayoutMath.swift
//  Skein
//

import CoreGraphics
import Foundation

/// Pure geometry for macOS 27's status item cliff and search math. No AppKit.
enum MenuBarLayoutMath {
    /// Padding added by MenuBarAgent to an item's length to produce its slot width.
    static let slotPadding: CGFloat = 16

    /// Smallest divider unit to test.
    static let minimumUnit: CGFloat = 40

    /// Largest divider unit permitted on macOS 27.
    static let maximumUnit: CGFloat = 4900

    /// Search resolution in points for cliff probing.
    static let searchResolution: CGFloat = 16

    /// Maximum spacer items permitted per divider.
    static let maximumSpacersPerDivider = 6

    /// A snapshot of matching slots and notch chevrons observed on one display's menu bar window.
    struct DisplayObservation: Equatable {
        var matchingSlots: Int
        var chevrons: Int

        init(matchingSlots: Int = 0, chevrons: Int = 0) {
            self.matchingSlots = matchingSlots
            self.chevrons = chevrons
        }

        init(_ matchingSlots: Int, _ chevrons: Int) {
            self.matchingSlots = matchingSlots
            self.chevrons = chevrons
        }
    }

    /// Computes the initial probe unit for a screen configuration.
    static func startUnit(screenWidths: [CGFloat], userOverride: CGFloat? = nil) -> CGFloat {
        let positiveWidths = screenWidths.filter { $0 > 0 }
        guard let narrowest = positiveWidths.min() else {
            return 200
        }
        var unit = (narrowest / 2).rounded(.down) - slotPadding
        if
            let userOverride,
            userOverride > 0
        {
            unit = min(unit, userOverride)
        }
        return min(max(unit, minimumUnit), maximumUnit)
    }

    /// Computes the next binary search probe between an honored low and dropped high bound.
    static func nextProbe(honored low: CGFloat, dropped high: CGFloat) -> CGFloat? {
        guard high - low > 2 * searchResolution else {
            return nil
        }
        return low + (((high - low) / 2) / searchResolution).rounded(.down) * searchResolution
    }

    /// Spacer items needed next to one divider so the total span covers the widest screen.
    static func spacerCount(widestWidth: CGFloat, unit: CGFloat) -> Int {
        guard
            widestWidth > 0,
            unit > 0
        else {
            return 0
        }
        let count = Int((widestWidth / unit).rounded(.up)) - 1
        return min(max(0, count), maximumSpacersPerDivider)
    }

    /// Determines whether the unit and spacer count cover the widest screen.
    static func coversWidest(widestWidth: CGFloat, unit: CGFloat, spacers: Int) -> Bool {
        unit * CGFloat(spacers + 1) >= widestWidth
    }

    /// Evaluates whether an item length is honored across all displays.
    static func isHonored(
        before: [String: DisplayObservation],
        after: [String: DisplayObservation],
        expectedIncrease: Int
    ) -> Bool {
        guard
            !after.isEmpty,
            expectedIncrease >= 1
        else {
            return false
        }
        for (key, afterObs) in after {
            let beforeObs = before[key] ?? DisplayObservation(matchingSlots: 0, chevrons: 0)
            guard afterObs.matchingSlots - beforeObs.matchingSlots >= expectedIncrease else {
                return false
            }
            guard afterObs.chevrons <= beforeObs.chevrons else {
                return false
            }
        }
        return true
    }
}
