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

    /// A composited status item slot observed in a MenuBarAgent window.
    struct Slot: Equatable {
        var frame: CGRect
        var isChevron: Bool
        var identifier: String?
        var pid: pid_t?

        init(
            frame: CGRect,
            isChevron: Bool,
            identifier: String? = nil,
            pid: pid_t? = nil
        ) {
            self.frame = frame
            self.isChevron = isChevron
            self.identifier = identifier
            self.pid = pid
        }
    }

    /// An observation of a MenuBarAgent menu bar window and its slots.
    struct DisplayObservation: Equatable {
        var bar: CGRect
        var slots: [Slot]
    }

    /// The collapse state of a single display.
    enum DisplayState: String, Equatable {
        case collapsed
        case dividerDropped
        case itemsVisible
    }

    /// Determines whether a slot is overflowed, off-bar, or in an overflow pile.
    static func isOverflowed(
        _ slot: Slot,
        among slots: [Slot],
        bar: CGRect = .null
    ) -> Bool {
        if slot.isChevron {
            return true
        }
        if slot.frame.width <= 0 {
            return true
        }
        if
            !bar.isNull,
            !bar.isEmpty,
            !slot.frame.intersects(bar)
        {
            return true
        }
        var foundSelf = false
        for other in slots {
            guard !other.isChevron else {
                continue
            }
            if !foundSelf, other == slot {
                foundSelf = true
                continue
            }
            let overlap = min(slot.frame.maxX, other.frame.maxX) - max(slot.frame.minX, other.frame.minX)
            if overlap > 1 {
                return true
            }
        }
        return false
    }

    /// Evaluates the collapse state for a display observation.
    static func state(
        of observation: DisplayObservation,
        dividerIdentifier: String,
        dividerSlotWidth: CGFloat,
        ownIdentifiers: Set<String>,
        ownSlotWidths: Set<CGFloat>
    ) -> DisplayState {
        let sortedSlots = observation.slots.sorted { $0.frame.minX < $1.frame.minX }

        func isOurs(_ slot: Slot) -> Bool {
            if let id = slot.identifier {
                return ownIdentifiers.contains(id)
            }
            return ownSlotWidths.contains { abs(slot.frame.width - $0) <= 1 }
        }

        // The width must match even when the identifier does: after a length change,
        // the main display can still list the divider's slot at its previous width
        // while the new length is dropped.
        func isDivider(_ slot: Slot) -> Bool {
            if
                let id = slot.identifier,
                id != dividerIdentifier
            {
                return false
            }
            return abs(slot.frame.width - dividerSlotWidth) <= 1
        }

        guard sortedSlots.contains(where: isDivider) else {
            return .dividerDropped
        }

        let oursNotOverflowed = sortedSlots.filter {
            isOurs($0) && !isOverflowed($0, among: sortedSlots, bar: observation.bar)
        }
        guard !oursNotOverflowed.isEmpty else {
            return .collapsed
        }

        let smallestOursMinX = oursNotOverflowed.map(\.frame.minX).min() ?? 0
        let hasVisibleThirdParty = sortedSlots.contains { slot in
            !isOurs(slot)
                && !isOverflowed(slot, among: sortedSlots, bar: observation.bar)
                && slot.frame.minX < smallestOursMinX
        }

        if hasVisibleThirdParty {
            return .itemsVisible
        }
        return .collapsed
    }

    /// Finds process identifiers from `hiddenPIDs` that have leaked to the right of our block.
    static func leakedProcessIdentifiers(
        in observation: DisplayObservation,
        dividerIdentifier: String,
        dividerSlotWidth: CGFloat,
        ownIdentifiers: Set<String>,
        ownSlotWidths: Set<CGFloat>,
        hiddenPIDs: Set<pid_t>
    ) -> Set<pid_t> {
        guard !hiddenPIDs.isEmpty else {
            return []
        }
        let sortedSlots = observation.slots.sorted { $0.frame.minX < $1.frame.minX }

        func isOurs(_ slot: Slot) -> Bool {
            if let id = slot.identifier {
                return ownIdentifiers.contains(id)
            }
            return ownSlotWidths.contains { abs(slot.frame.width - $0) <= 1 }
        }

        let oursNotOverflowed = sortedSlots.filter {
            isOurs($0) && !isOverflowed($0, among: sortedSlots, bar: observation.bar)
        }
        guard let largestOursMaxX = oursNotOverflowed.map(\.frame.maxX).max() else {
            return []
        }

        var leaked = Set<pid_t>()
        for slot in sortedSlots {
            guard
                !isOurs(slot),
                !isOverflowed(slot, among: sortedSlots, bar: observation.bar),
                slot.frame.minX >= largestOursMaxX,
                let pid = slot.pid,
                hiddenPIDs.contains(pid)
            else {
                continue
            }
            leaked.insert(pid)
        }
        return leaked
    }

    /// Summarizes display states into a single overall state.
    static func summary(_ states: [DisplayState]) -> DisplayState? {
        guard !states.isEmpty else {
            return nil
        }
        if states.contains(.dividerDropped) {
            return .dividerDropped
        }
        if states.contains(.itemsVisible) {
            return .itemsVisible
        }
        return .collapsed
    }

    /// Computes the divider and spacer lengths for display caps.
    static func ladderLengths(
        caps: [CGFloat],
        margin: CGFloat = 16
    ) -> (divider: CGFloat, spacers: [CGFloat]) {
        guard !caps.isEmpty else {
            return (startUnit(screenWidths: []), [])
        }
        let sortedCaps = caps.sorted()
        var dedupedCaps: [CGFloat] = []
        for cap in sortedCaps {
            if
                let last = dedupedCaps.last,
                abs(cap - last) <= 2
            {
                continue
            }
            dedupedCaps.append(cap)
        }
        guard let c1 = dedupedCaps.first else {
            return (startUnit(screenWidths: []), [])
        }

        func slot(_ x: CGFloat) -> CGFloat {
            x + slotPadding
        }

        let divider = min(max(c1 - margin, minimumUnit), maximumUnit)
        let used = slot(divider)

        // A spacer must be longer than the second-widest display's cap so that every
        // narrower display drops it. A notch splits a display's free space into two
        // regions, so a spacer honored there can take the region the divider needs.
        // Only the widest display gets a ladder spacer; fill spacers cover the rest.
        var spacers: [CGFloat] = []
        if
            dedupedCaps.count > 1,
            let widest = dedupedCaps.last
        {
            let secondWidest = dedupedCaps[dedupedCaps.count - 2]
            let spacerSlot = slot(widest) - used - margin
            if
                spacerSlot > slot(secondWidest),
                spacerSlot - slotPadding >= minimumUnit
            {
                spacers.append(min(spacerSlot - slotPadding, maximumUnit))
            }
        }
        return (divider, spacers)
    }

    /// Computes the search bounds for fill spacers in remaining display space.
    static func fillBounds(
        caps: [CGFloat],
        ladder: (divider: CGFloat, spacers: [CGFloat])
    ) -> (lower: CGFloat, upper: CGFloat)? {
        guard !caps.isEmpty else {
            return nil
        }
        let sortedCaps = caps.sorted()
        var dedupedCaps: [CGFloat] = []
        for cap in sortedCaps {
            if
                let last = dedupedCaps.last,
                abs(cap - last) <= 2
            {
                continue
            }
            dedupedCaps.append(cap)
        }
        guard let largest = dedupedCaps.last else {
            return nil
        }

        let lower: CGFloat
        if dedupedCaps.count >= 2 {
            lower = dedupedCaps[dedupedCaps.count - 2] + 1
        } else {
            lower = minimumUnit
        }

        let upper = min(largest, maximumUnit)
        guard upper >= lower else {
            return nil
        }
        return (lower, upper)
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
}
