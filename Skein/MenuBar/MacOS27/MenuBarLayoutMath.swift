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
        ownSlotWidths: Set<CGFloat>,
        ownPID: pid_t? = nil
    ) -> DisplayState {
        let sortedSlots = observation.slots.sorted { $0.frame.minX < $1.frame.minX }

        func isOurs(_ slot: Slot) -> Bool {
            if let pid = slot.pid, let ownPID {
                return pid == ownPID
            }
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
        hiddenPIDs: Set<pid_t>,
        ownPID: pid_t? = nil
    ) -> Set<pid_t> {
        guard !hiddenPIDs.isEmpty else {
            return []
        }
        let sortedSlots = observation.slots.sorted { $0.frame.minX < $1.frame.minX }

        func isOurs(_ slot: Slot) -> Bool {
            if let pid = slot.pid, let ownPID {
                return pid == ownPID
            }
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

    /// Computes the divider and descending binary ladder spacer lengths for display caps.
    static func ladderPlan(
        caps: [CGFloat],
        hiddenSlotMin: CGFloat,
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
        guard let smallest = dedupedCaps.first else {
            return (startUnit(screenWidths: []), [])
        }

        let divider = min(max(smallest - margin, minimumUnit), maximumUnit)

        guard dedupedCaps.count >= 2 else {
            return (divider, [])
        }

        guard let widestCap = dedupedCaps.last else {
            return (divider, [])
        }

        let tMin = min(max(hiddenSlotMin, 32), 48)
        let limit = widestCap + slotPadding + tMin

        var spacers: [CGFloat] = []
        for k in (0...5).reversed() {
            let slot = tMin * CGFloat(1 << k)
            guard slot <= limit else {
                continue
            }
            let length = slot - slotPadding
            spacers.append(length)
        }

        return (divider, spacers)
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
    /// A parsed key from MenuBarAgent's layout table.
    struct LayoutTableKey: Hashable {
        /// The bundle identifier of the owning application, or `nil` for system modules.
        let bundleID: String?

        /// The autosave name or module name of the item.
        let name: String

        /// A Boolean value that indicates whether the key represents a system module.
        let isModule: Bool

        /// The raw string key in the layout table.
        let rawKey: String

        /// Parses a raw layout table key.
        ///
        /// Supports `status:<bundle>::<name>` and `module:<Name>` with any trailing
        /// `-<digits>` removed from the module name. Unknown formats return `nil`.
        init?(rawKey: String) {
            if rawKey.hasPrefix("status:") {
                let remainder = rawKey.dropFirst(7)
                guard let range = remainder.range(of: "::") else {
                    return nil
                }
                let bundle = String(remainder[..<range.lowerBound])
                let name = String(remainder[range.upperBound...])
                self.bundleID = bundle
                self.name = name
                self.isModule = false
                self.rawKey = rawKey
            } else if rawKey.hasPrefix("module:") {
                let remainder = String(rawKey.dropFirst(7))
                var name = remainder
                if let dashIndex = remainder.lastIndex(of: "-") {
                    let suffix = remainder[remainder.index(after: dashIndex)...]
                    if
                        !suffix.isEmpty,
                        suffix.allSatisfy(\.isNumber)
                    {
                        name = String(remainder[..<dashIndex])
                    }
                }
                self.bundleID = nil
                self.name = name
                self.isModule = true
                self.rawKey = rawKey
            } else {
                return nil
            }
        }
    }

    /// Names of the menu bar sections.
    enum SectionName: Equatable {
        case visible
        case hidden
        case alwaysHidden
    }

    /// Returns the parsed table keys sorted by distance descending.
    static func orderedKeys(_ table: [String: Double]) -> [(key: LayoutTableKey, distance: Double)] {
        table.compactMap { rawKey, distance in
            LayoutTableKey(rawKey: rawKey).map { ($0, distance) }
        }
        .sorted { first, second in
            if first.distance != second.distance {
                return first.distance > second.distance
            }
            return first.key.rawKey < second.key.rawKey
        }
    }

    /// Pairs items with table keys, marking them as grouped when frames are untrustworthy
    /// or item counts differ from table key counts.
    static func zip<Element>(
        items: [Element],
        keys: [LayoutTableKey],
        framesTrustworthy: Bool
    ) -> (pairs: [(Element, LayoutTableKey)], grouped: Bool) {
        if
            framesTrustworthy,
            items.count == keys.count
        {
            let pairs = Swift.zip(items, keys).map { ($0, $1) }
            return (pairs: pairs, grouped: false)
        } else {
            let count = min(items.count, keys.count)
            let pairs = Swift.zip(items.prefix(count), keys.prefix(count)).map { ($0, $1) }
            return (pairs: pairs, grouped: true)
        }
    }

    /// Determines the section for an item at the given distance from the trailing edge.
    static func section(
        forDistance distance: Double,
        hiddenDivider: Double?,
        alwaysHiddenDivider: Double?
    ) -> SectionName {
        if
            let alwaysHiddenDivider,
            distance > alwaysHiddenDivider
        {
            return .alwaysHidden
        }
        if
            let hiddenDivider,
            distance > hiddenDivider
        {
            return .hidden
        }
        return .visible
    }

    /// A relative move operation targeting a layout table key.
    enum Move: Equatable {
        case leftOf(key: String, target: String)
        case rightOf(key: String, target: String)
    }

    /// Applies a sequence of relative moves to a layout table using read-modify-write semantics.
    static func applyMoves(_ moves: [Move], to table: [String: Double]) -> [String: Double]? {
        for move in moves {
            let key: String
            let target: String
            switch move {
            case .leftOf(let k, let t):
                key = k
                target = t
            case .rightOf(let k, let t):
                key = k
                target = t
            }
            guard
                table[key] != nil,
                table[target] != nil
            else {
                return nil
            }
        }

        var result = table

        for move in moves {
            switch move {
            case .leftOf(let key, let target):
                guard
                    let t = result[target],
                    result[key] != nil
                else {
                    return nil
                }
                let greaterDistances = result.compactMap { k, dist -> Double? in
                    guard
                        k != key,
                        dist > t
                    else {
                        return nil
                    }
                    return dist
                }
                let neighbor = greaterDistances.min() ?? (t + 40)
                result[key] = (t + neighbor) / 2
                let gap = abs(neighbor - t)
                if gap < 0.01 {
                    let statusKeys = result.compactMap { k, dist -> (key: String, distance: Double)? in
                        guard
                            k.hasPrefix("status:"),
                            dist > t,
                            dist <= neighbor
                        else {
                            return nil
                        }
                        return (k, dist)
                    }.sorted { $0.distance < $1.distance }
                    for (index, item) in statusKeys.enumerated() {
                        result[item.key] = t + Double(index + 1) * 1.0
                    }
                }

            case .rightOf(let key, let target):
                guard
                    let t = result[target],
                    result[key] != nil
                else {
                    return nil
                }
                let smallerDistances = result.compactMap { k, dist -> Double? in
                    guard
                        k != key,
                        dist < t
                    else {
                        return nil
                    }
                    return dist
                }
                let neighbor = smallerDistances.max() ?? max(t - 40, 0.5)
                result[key] = (t + neighbor) / 2
                let gap = abs(t - neighbor)
                if gap < 0.01 {
                    let statusKeys = result.compactMap { k, dist -> (key: String, distance: Double)? in
                        guard
                            k.hasPrefix("status:"),
                            dist < t,
                            dist >= neighbor
                        else {
                            return nil
                        }
                        return (k, dist)
                    }.sorted { $0.distance > $1.distance }
                    for (index, item) in statusKeys.enumerated() {
                        result[item.key] = t - Double(index + 1) * 1.0
                    }
                }
            }
        }

        return result
    }
}
