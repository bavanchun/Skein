//
//  MenuBarLayoutMath.swift
//  Skein
//

import CoreGraphics
import Foundation

/// Pure geometry for macOS 27's status item cliff. No AppKit.
enum MenuBarLayoutMath {
    /// Margin kept below half the narrowest screen width.
    static let defaultCliffMargin: CGFloat = 64

    /// The largest length a single status item may take on every attached screen.
    ///
    /// `userOverride` is the user's pinned value; `learnedCap` is the self-test's
    /// in-memory cap for the current screen configuration. Both only lower the result.
    static func collapseUnit(
        screenWidths: [CGFloat],
        margin: CGFloat = defaultCliffMargin,
        userOverride: CGFloat? = nil,
        learnedCap: CGFloat? = nil
    ) -> CGFloat {
        guard let narrowest = screenWidths.min(), narrowest > 0 else {
            return 200
        }
        var unit = (narrowest / 2).rounded(.down) - margin
        if let userOverride, userOverride > 0 {
            unit = min(unit, userOverride)
        }
        if let learnedCap {
            unit = min(unit, learnedCap)
        }
        return min(max(unit, 200), 4900)
    }

    /// Spacer items needed next to one divider so the total span covers the widest screen.
    static func spacerCount(screenWidths: [CGFloat], unit: CGFloat) -> Int {
        guard let widest = screenWidths.max(), unit > 0 else {
            return 0
        }
        return max(0, Int((widest / unit).rounded(.up)) - 1)
    }
}
