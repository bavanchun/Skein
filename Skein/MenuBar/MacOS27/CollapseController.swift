//
//  CollapseController.swift
//  Skein
//

import Cocoa
import Combine

/// Finds, verifies and maintains the honored collapse length for section dividers on macOS 27.
@MainActor
final class CollapseController: ObservableObject {
    static let shared = CollapseController()

    private static let settleDelay: Duration = .milliseconds(600)
    private static var hasLoggedAnchorUnavailable = false

    /// Reason why the anchor could not be written, published for the settings pane card.
    @Published var collapseAnchorUnavailableReason: String?

    /// Number of probes during searches that required a second observation for stability verification.
    private(set) var probesRequiringSecondObservation = 0

    /// The distance of the HItem divider in shown state, cached for quit verification.
    private(set) var shownHItemDistance: Double?

    /// Process identifiers of on-bar slots left of the divider before collapse.
    private var hiddenPIDs = Set<pid_t>()

    /// Process identifiers of visible third-party items keyed by display key.
    private var visiblePIDs: [String: Set<pid_t>] = [:]

    /// Leftmost hidden slot width recorded during snapshot.
    private var hiddenSlotMin: CGFloat = 40

    /// Observation taken before any collapse length changes.
    private var preObservation: [String: MenuBarLayoutMath.DisplayObservation]?

    /// Configuration keys where incomplete collapse has been logged.
    private var loggedIncompleteKeys = Set<String>()

    /// Whether spacers should be held at resting length.
    private var isSpacersResting = false

    /// Keys of the hidden block remembered for the current collapse.
    private var rememberedBlockKeys: [String] = []

    /// Indicates whether the hidden block was snapshotted before the collapse lengths were applied.
    private var hasPreparedSnapshot = false

    /// Refusal handler provided by the section owner to restore dividers to shown state without direct section calls.
    private var onRefusal: (() -> Void)?

    /// Honored divider lengths keyed by screen configuration key, then by display frame key.
    private var caps: [String: [String: CGFloat]] = [:]

    /// Consecutive search failure counts keyed by screen configuration key.
    private var failures: [String: Int] = [:]

    /// The earliest date a search is next allowed for each configuration key.
    private var nextAllowedSearch: [String: Date] = [:]

    /// Backoff durations in seconds keyed by screen configuration key.
    private var backoff: [String: TimeInterval] = [:]

    /// Indicates whether a search is currently in progress.
    private var isSearching = false

    /// Indicates whether a check was requested while a search was running.
    private var pendingCheck = false

    /// The divider length currently being probed during an active search.
    private var probingLength: CGFloat?

    /// Weak reference to the shared app state.
    private weak var appState: AppState?

    /// Indicates whether observers have been installed.
    private var areObserversInstalled = false

    /// Storage for Combine subscriptions.
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    /// Returns the configuration key for the given display widths.
    private func configurationKey(for widths: [CGFloat]) -> String {
        widths
            .map { Int($0) }
            .sorted()
            .map(String.init)
            .joined(separator: "+")
    }

    /// Returns the collapse divider length for the given display widths.
    func unit(for widths: [CGFloat]) -> CGFloat {
        if isSearching, let probingLength {
            return probingLength
        }
        let key = configurationKey(for: widths)
        let userOverride = (Defaults.object(forKey: .collapseUnitOverride) as? NSNumber).map {
            CGFloat(truncating: $0)
        }
        if let displayCaps = caps[key], !displayCaps.isEmpty {
            let capsList = Array(displayCaps.values)
            var divider = MenuBarLayoutMath.ladderPlan(caps: capsList, hiddenSlotMin: hiddenSlotMin).divider
            if
                let userOverride,
                userOverride > 0
            {
                divider = min(divider, userOverride)
            }
            return divider
        }
        return MenuBarLayoutMath.startUnit(screenWidths: widths, userOverride: userOverride)
    }

    /// Returns the spacer lengths for the given display widths.
    func spacerLengths(for widths: [CGFloat]) -> [CGFloat] {
        guard !isSpacersResting else {
            return []
        }
        let key = configurationKey(for: widths)
        if let displayCaps = caps[key], !displayCaps.isEmpty {
            let capsList = Array(displayCaps.values)
            let plan = MenuBarLayoutMath.ladderPlan(caps: capsList, hiddenSlotMin: hiddenSlotMin)
            return plan.spacers
        }
        return []
    }

    /// Set of own status item identifiers.
    private func ownIdentifiers() -> Set<String> {
        var ids: Set<String> = [
            ControlItem.Identifier.skeinIcon.rawValue,
            ControlItem.Identifier.hidden.rawValue,
            ControlItem.Identifier.alwaysHidden.rawValue,
        ]
        for i in 0..<MenuBarLayoutMath.maximumSpacersPerDivider {
            ids.insert("HItemSpacer\(i)")
            ids.insert("AHItemSpacer\(i)")
        }
        return ids
    }

    /// Set of own status item slot widths.
    private func ownSlotWidths(dividers: [ControlItem]) -> Set<CGFloat> {
        var widths: Set<CGFloat> = []
        for d in dividers where d.length > 0 {
            widths.insert(d.length + MenuBarLayoutMath.slotPadding)
        }
        widths.insert(CollapseSpacers.restingLength + MenuBarLayoutMath.slotPadding)
        let screenWidths = NSScreen.screens.map(\.frame.width)
        for spacerLength in spacerLengths(for: screenWidths) {
            widths.insert(spacerLength + MenuBarLayoutMath.slotPadding)
        }
        if let skeinItem = appState?.menuBarManager.section(withName: .visible)?.controlItem {
            let skeinWidth = skeinItem.window?.frame.width ?? skeinItem.length
            if skeinWidth > 0 {
                widths.insert(skeinWidth + MenuBarLayoutMath.slotPadding)
            }
        }
        return widths
    }

    /// Observes the collapse states for attached displays using the active divider.
    private func observeStates(dividers: [ControlItem]) async -> [String: MenuBarLayoutMath.DisplayState]? {
        guard let divider = dividers.first(where: {
            $0.identifier == .hidden && $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }) ?? dividers.first(where: {
            $0.identifier == .alwaysHidden && $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }) ?? dividers.first else {
            return nil
        }

        var obs = MenuBarAgentWindows.observe()
        if obs == nil {
            try? await Task.sleep(for: Self.settleDelay)
            obs = MenuBarAgentWindows.observe()
        }
        guard let observations = obs else {
            return nil
        }

        checkLeaks(observations: observations, divider: divider, dividers: dividers)

        let ownIDs = ownIdentifiers()
        let ownWidths = ownSlotWidths(dividers: dividers)
        let dividerSlotWidth = (probingLength ?? divider.length) + MenuBarLayoutMath.slotPadding
        let ownPID = NSRunningApplication.current.processIdentifier

        var states: [String: MenuBarLayoutMath.DisplayState] = [:]
        for (displayKey, observation) in observations {
            states[displayKey] = MenuBarLayoutMath.state(
                of: observation,
                dividerIdentifier: divider.autosaveName,
                dividerSlotWidth: dividerSlotWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths,
                ownPID: ownPID
            )
        }
        return states
    }

    /// Checks if any third-party items have leaked past the divider while collapsed.
    private func checkLeaks(
        observations: [String: MenuBarLayoutMath.DisplayObservation],
        divider: ControlItem,
        dividers: [ControlItem]
    ) {
        guard !hiddenPIDs.isEmpty else {
            return
        }
        let ownIDs = ownIdentifiers()
        let ownWidths = ownSlotWidths(dividers: dividers)
        let dividerSlotWidth = (probingLength ?? divider.length) + MenuBarLayoutMath.slotPadding
        let ownPID = NSRunningApplication.current.processIdentifier

        var totalLeaked = Set<pid_t>()
        for (_, observation) in observations {
            let leaked = MenuBarLayoutMath.leakedProcessIdentifiers(
                in: observation,
                dividerIdentifier: divider.autosaveName,
                dividerSlotWidth: dividerSlotWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths,
                hiddenPIDs: hiddenPIDs,
                ownPID: ownPID
            )
            totalLeaked.formUnion(leaked)
        }

        if !totalLeaked.isEmpty {
            Logger.collapse.notice("collapse leaked count=\(totalLeaked.count)")
            _ = anchorBlock()
        }
    }

    /// A Boolean value that indicates whether the divider is still collapsed in the menu bar.
    private func isCollapsed(_ divider: ControlItem) -> Bool {
        divider.isAddedToMenuBar && divider.isVisible && divider.state == .hideItems
    }

    /// Probes display states with the two-observation stability rule for dropped dividers.
    private func probeDisplayStates(
        dividers: [ControlItem]
    ) async -> [String: (state: MenuBarLayoutMath.DisplayState?, attempts: Int)]? {
        guard let firstObs = await observeStates(dividers: dividers) else {
            return nil
        }

        let hasAnyDropped = firstObs.values.contains(.dividerDropped)
        var secondObs: [String: MenuBarLayoutMath.DisplayState]?
        if hasAnyDropped {
            probesRequiringSecondObservation += 1
            try? await Task.sleep(for: .milliseconds(200))
            secondObs = await observeStates(dividers: dividers)
        }

        var results: [String: (state: MenuBarLayoutMath.DisplayState?, attempts: Int)] = [:]
        for (dKey, state1) in firstObs {
            if state1 == .dividerDropped {
                if let state2 = secondObs?[dKey], state2 == .dividerDropped {
                    results[dKey] = (state: .dividerDropped, attempts: 2)
                } else {
                    results[dKey] = (state: nil, attempts: 2)
                }
            } else {
                results[dKey] = (state: state1, attempts: 1)
            }
        }
        return results
    }

    /// Handles refusal when Full Disk Access is missing or writing/reading the table fails.
    private func handleAnchorUnavailable(reason: String) {
        if !Self.hasLoggedAnchorUnavailable {
            Self.hasLoggedAnchorUnavailable = true
            Logger.collapse.notice("collapse anchor unavailable reason=\(reason)")
        }
        collapseAnchorUnavailableReason = reason
        onRefusal?()
    }

    /// Snapshots the hidden block before the section's collapse lengths are applied.
    ///
    /// The snapshot has to happen while the hidden items still hold their own
    /// distances, so the section calls this before changing any state.
    /// Returns `false` when the table cannot be read or written, which means the
    /// section must stay shown.
    @discardableResult
    func prepareForCollapse(_ dividers: [ControlItem]) -> Bool {
        guard MenuBarPlatform.usesMenuBarAgent else {
            return true
        }
        isSpacersResting = false
        preObservation = MenuBarAgentWindows.observe()
        hasPreparedSnapshot = snapshotHiddenBlock(dividers: dividers, requireCollapsed: false)
        return hasPreparedSnapshot
    }

    /// Reads the layout table and records the hidden block keys and PIDs before collapse begins.
    private func snapshotHiddenBlock(dividers: [ControlItem], requireCollapsed: Bool = true) -> Bool {
        guard case .granted = LayoutTableFile.access() else {
            handleAnchorUnavailable(reason: "denied")
            return false
        }
        guard let table = LayoutTableFile.readFromDisk() else {
            handleAnchorUnavailable(reason: "unreadable")
            return false
        }

        func isEligible(_ divider: ControlItem, _ identifier: ControlItem.Identifier) -> Bool {
            divider.identifier == identifier
                && divider.isAddedToMenuBar
                && divider.isVisible
                && (!requireCollapsed || divider.state == .hideItems)
        }
        guard let activeDivider = dividers.first(where: { isEligible($0, .hidden) })
            ?? dividers.first(where: { isEligible($0, .alwaysHidden) })
            ?? dividers.first
        else {
            return false
        }

        let dividerName = activeDivider.autosaveName
        guard let dividerKey = table.keys.first(where: {
            $0.hasPrefix("status:") && $0.hasSuffix("::\(dividerName)")
        }), let dividerDistance = table[dividerKey] else {
            handleAnchorUnavailable(reason: "unreadable")
            return false
        }

        if dividerName == ControlItem.Identifier.hidden.rawValue {
            shownHItemDistance = dividerDistance
        }

        var blockKeys: [String] = []
        for (key, distance) in table {
            guard
                key.hasPrefix("status:"),
                !key.hasPrefix("module:"),
                distance > dividerDistance
            else {
                continue
            }
            if key.contains("Spacer") {
                continue
            }
            blockKeys.append(key)
        }

        blockKeys.sort { (table[$0] ?? 0) < (table[$1] ?? 0) }
        Defaults.set(blockKeys, forKey: .collapseHiddenBlock)
        rememberedBlockKeys = blockKeys

        if let observations = preObservation ?? MenuBarAgentWindows.observe() {
            let currentPID = NSRunningApplication.current.processIdentifier
            var pids = Set<pid_t>()
            var visibleMap: [String: Set<pid_t>] = [:]
            var minHiddenWidth: CGFloat?

            for (dKey, observation) in observations {
                guard let dividerSlot = observation.slots.first(where: {
                    $0.identifier == activeDivider.autosaveName
                        || abs($0.frame.width - (activeDivider.length + MenuBarLayoutMath.slotPadding)) <= 1
                }) else {
                    continue
                }

                var visPIDs = Set<pid_t>()
                var leftmostHiddenSlot: MenuBarLayoutMath.Slot?

                for slot in observation.slots {
                    guard
                        !slot.isChevron,
                        slot.frame.width > 0
                    else {
                        continue
                    }
                    if let pid = slot.pid, pid == currentPID {
                        continue
                    }

                    if slot.frame.minX > dividerSlot.frame.minX {
                        if let pid = slot.pid {
                            visPIDs.insert(pid)
                        }
                    } else if slot.frame.minX < dividerSlot.frame.minX {
                        if let pid = slot.pid {
                            pids.insert(pid)
                        }
                        if let currentLeft = leftmostHiddenSlot {
                            if slot.frame.minX < currentLeft.frame.minX {
                                leftmostHiddenSlot = slot
                            }
                        } else {
                            leftmostHiddenSlot = slot
                        }
                    }
                }

                visibleMap[dKey] = visPIDs
                if let leftmost = leftmostHiddenSlot {
                    let w = leftmost.frame.width
                    if let cur = minHiddenWidth {
                        minHiddenWidth = min(cur, w)
                    } else {
                        minHiddenWidth = w
                    }
                }
            }

            hiddenPIDs = pids
            visiblePIDs = visibleMap
            if let w = minHiddenWidth {
                hiddenSlotMin = w
            }
        }

        collapseAnchorUnavailableReason = nil
        return true
    }

    /// Anchors the hidden block and spacers above the collapsing divider.
    @discardableResult
    private func anchorBlock() -> Bool {
        let blockKeys = rememberedBlockKeys.isEmpty
            ? (Defaults.stringArray(forKey: .collapseHiddenBlock) ?? (Defaults.array(forKey: .collapseHiddenBlock) as? [String]) ?? [])
            : rememberedBlockKeys

        guard case .granted = LayoutTableFile.access() else {
            handleAnchorUnavailable(reason: "denied")
            return false
        }
        guard let table = LayoutTableFile.readFromDisk() else {
            handleAnchorUnavailable(reason: "unreadable")
            return false
        }

        let dividerName = ControlItem.Identifier.hidden.rawValue
        guard let dividerKey = table.keys.first(where: {
            $0.hasPrefix("status:") && $0.hasSuffix("::\(dividerName)")
        }), let dividerDistance = table[dividerKey] else {
            handleAnchorUnavailable(reason: "unreadable")
            return false
        }

        let base = max(8192.0, floor(dividerDistance) + 8.0)
        let prefix = String(dividerKey.dropLast(dividerName.count))

        let result = LayoutTableWriter.apply { current in
            var next = current
            for i in 0..<MenuBarLayoutMath.maximumSpacersPerDivider {
                let spacerKey = "\(prefix)\(dividerName)Spacer\(i)"
                next[spacerKey] = base + Double(8 * i)
            }
            for (r, key) in blockKeys.enumerated() {
                next[key] = base + 48.0 + Double(8 * r)
            }
            return next
        }

        switch result {
        case .written:
            Logger.collapse.notice("collapse anchored count=\(blockKeys.count)")
            return true
        case .noChange:
            return true
        case .denied, .unreadable, .verifyFailed, .backupFailed:
            handleAnchorUnavailable(reason: "\(result)")
            return false
        }
    }

    /// Re-anchors the remembered block on launch if MenuBarAgent rewrote distances while collapsed.
    func repairIfNeeded() {
        guard MenuBarPlatform.usesMenuBarAgent else {
            return
        }
        guard
            case .granted = LayoutTableFile.access(),
            let table = LayoutTableFile.readFromDisk(),
            let remembered = Defaults.stringArray(forKey: .collapseHiddenBlock) ?? (Defaults.array(forKey: .collapseHiddenBlock) as? [String]),
            !remembered.isEmpty
        else {
            return
        }

        let dividerName = ControlItem.Identifier.hidden.rawValue
        guard
            let dividerKey = table.keys.first(where: {
                $0.hasPrefix("status:") && $0.hasSuffix("::\(dividerName)")
            }),
            let dividerDist = table[dividerKey]
        else {
            return
        }

        let needsRepair = remembered.contains { (table[$0] ?? 0) <= dividerDist }
        guard needsRepair else {
            return
        }

        let base = max(8192.0, floor(dividerDist) + 8.0)
        let prefix = String(dividerKey.dropLast(dividerName.count))

        let result = LayoutTableWriter.apply { current in
            var next = current
            for i in 0..<MenuBarLayoutMath.maximumSpacersPerDivider {
                let spacerKey = "\(prefix)\(dividerName)Spacer\(i)"
                next[spacerKey] = base + Double(8 * i)
            }
            for (r, key) in remembered.enumerated() {
                next[key] = base + 48.0 + Double(8 * r)
            }
            return next
        }

        if result == .written {
            Logger.collapse.notice("collapse block repaired count=\(remembered.count)")
        }
    }

    /// Structure representing the per-display collapse verdict.
    private struct DisplayVerdict {
        var dividerLost: Bool
        var visiblePushed: Bool
        var hiddenOnBar: Int
        var remainder: CGFloat
        var spacersOnBar: Int
    }

    /// Takes two observations 200ms apart that must agree, retrying once on mismatch.
    private func observePost() async -> [String: MenuBarLayoutMath.DisplayObservation]? {
        var obs1 = MenuBarAgentWindows.observe()
        try? await Task.sleep(for: .milliseconds(200))
        var obs2 = MenuBarAgentWindows.observe()

        if obs1 != obs2 || obs2 == nil {
            try? await Task.sleep(for: .milliseconds(200))
            obs1 = MenuBarAgentWindows.observe()
            try? await Task.sleep(for: .milliseconds(200))
            obs2 = MenuBarAgentWindows.observe()
            if obs1 != obs2 || obs2 == nil {
                Logger.collapse.notice("collapse verdict unknown")
                return nil
            }
        }
        return obs2
    }

    /// Evaluates display observations against pre-collapse state.
    private func judge(
        post: [String: MenuBarLayoutMath.DisplayObservation],
        pre: [String: MenuBarLayoutMath.DisplayObservation],
        activeDivider: ControlItem,
        ladderPlan: (divider: CGFloat, spacers: [CGFloat])
    ) -> [String: DisplayVerdict] {
        let ownIDs = ownIdentifiers()
        let ownWidths = ownSlotWidths(dividers: [activeDivider])
        let ownPID = NSRunningApplication.current.processIdentifier
        let dividerSlotWidth = activeDivider.length + MenuBarLayoutMath.slotPadding
        let spacerSlotWidths = Set(ladderPlan.spacers.map { $0 + MenuBarLayoutMath.slotPadding })

        func isOurs(_ slot: MenuBarLayoutMath.Slot) -> Bool {
            if let pid = slot.pid {
                return pid == ownPID
            }
            if let id = slot.identifier {
                return ownIDs.contains(id)
            }
            return ownWidths.contains { abs(slot.frame.width - $0) <= 1 }
        }

        func isDividerSlot(_ slot: MenuBarLayoutMath.Slot) -> Bool {
            if let id = slot.identifier {
                return id == activeDivider.autosaveName
            }
            return abs(slot.frame.width - dividerSlotWidth) <= 1
        }

        var verdicts: [String: DisplayVerdict] = [:]

        for (dKey, postDisplay) in post {
            let preDisplay = pre[dKey]
            let postSlots = postDisplay.slots
            let bar = postDisplay.bar

            let hadDividerInPre = preDisplay?.slots.contains(where: isDividerSlot) ?? false
            let hasDividerInPost = postSlots.contains(where: isDividerSlot)
            let dividerLost = hadDividerInPre && !hasDividerInPost

            let visPIDsForDisplay = visiblePIDs[dKey] ?? []
            var visiblePushed = false
            for pid in visPIDsForDisplay {
                let hasUnoverflowedInPost = postSlots.contains { slot in
                    slot.pid == pid && !MenuBarLayoutMath.isOverflowed(slot, among: postSlots, bar: bar)
                }
                if !hasUnoverflowedInPost {
                    visiblePushed = true
                    break
                }
            }

            let oursUnoverflowed = postSlots.filter {
                isOurs($0) && !MenuBarLayoutMath.isOverflowed($0, among: postSlots, bar: bar)
            }
            let leftmostOwnMinX = oursUnoverflowed.map(\.frame.minX).min() ?? CGFloat.infinity

            var hiddenCount = 0
            var rightmostHiddenMaxX: CGFloat = 0
            for slot in postSlots {
                guard !MenuBarLayoutMath.isOverflowed(slot, among: postSlots, bar: bar) else {
                    continue
                }
                let isHidden: Bool
                if let pid = slot.pid {
                    isHidden = hiddenPIDs.contains(pid)
                } else {
                    isHidden = !isOurs(slot) && slot.frame.minX < leftmostOwnMinX
                }
                if isHidden {
                    hiddenCount += 1
                    rightmostHiddenMaxX = max(rightmostHiddenMaxX, slot.frame.maxX)
                }
            }

            var onBarSpacers = 0
            var leftmostSpacerMinX: CGFloat = CGFloat.infinity
            for slot in postSlots {
                guard !MenuBarLayoutMath.isOverflowed(slot, among: postSlots, bar: bar) else {
                    continue
                }
                let isSpacer: Bool
                if let id = slot.identifier {
                    isSpacer = id.contains("Spacer")
                } else if slot.pid == ownPID {
                    isSpacer = spacerSlotWidths.contains { abs(slot.frame.width - $0) <= 1 }
                } else {
                    isSpacer = false
                }
                if isSpacer {
                    onBarSpacers += 1
                    leftmostSpacerMinX = min(leftmostSpacerMinX, slot.frame.minX)
                }
            }

            let remainder: CGFloat
            if hiddenCount > 0, leftmostSpacerMinX < CGFloat.infinity, rightmostHiddenMaxX > 0 {
                remainder = max(0, leftmostSpacerMinX - rightmostHiddenMaxX)
            } else {
                remainder = 0
            }

            verdicts[dKey] = DisplayVerdict(
                dividerLost: dividerLost,
                visiblePushed: visiblePushed,
                hiddenOnBar: hiddenCount,
                remainder: remainder,
                spacersOnBar: onBarSpacers
            )
        }

        return verdicts
    }

    /// Searches for the honored divider lengths per display and applies the ladder.
    private func search(
        dividers: [ControlItem],
        initialHigh: [String: CGFloat] = [:]
    ) async {
        guard !dividers.isEmpty else {
            return
        }
        guard let activeDivider = dividers.first(where: {
            $0.identifier == .hidden && $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }) ?? dividers.first(where: {
            $0.identifier == .alwaysHidden && $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }) ?? dividers.first else {
            return
        }
        isSearching = true
        defer {
            isSearching = false
            probingLength = nil
        }

        let widths = NSScreen.screens.map(\.frame.width)
        let key = configurationKey(for: widths)
        let previousCaps = caps[key]
        let userOverride = (Defaults.object(forKey: .collapseUnitOverride) as? NSNumber).map {
            CGFloat(truncating: $0)
        }
        let start = MenuBarLayoutMath.startUnit(screenWidths: widths, userOverride: userOverride)

        var low: [String: CGFloat] = [:]
        var high: [String: CGFloat] = initialHigh
        var upwardProbesRemaining: [String: Int] = [:]
        var observedDisplayKeys = Set<String>()

        var currentLength = start
        var probeCount = 0
        var isInterrupted = false

        while probeCount < 12 {
            probeCount += 1
            probingLength = currentLength
            activeDivider.applyProbeLength(currentLength)
            try? await Task.sleep(for: Self.settleDelay)

            guard isCollapsed(activeDivider) else {
                isInterrupted = true
                break
            }

            guard let probeResults = await probeDisplayStates(dividers: dividers) else {
                isInterrupted = true
                break
            }

            if probeCount == 1 {
                guard anchorBlock() else {
                    caps[key] = previousCaps
                    probingLength = nil
                    for divider in dividers {
                        divider.reapplyCollapseLength()
                    }
                    return
                }
            }

            for (dKey, probeResult) in probeResults {
                observedDisplayKeys.insert(dKey)
                let displayWidth = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
                if let st = probeResult.state {
                    Logger.collapse.debug(
                        "probe length=\(Int(currentLength)) display=\(displayWidth) state=\(st.rawValue) attempts=\(probeResult.attempts)"
                    )
                    if st != .dividerDropped {
                        low[dKey] = max(low[dKey] ?? 0, currentLength)
                    } else {
                        let prevHigh = high[dKey] ?? currentLength
                        high[dKey] = min(prevHigh, currentLength)
                    }
                } else {
                    Logger.collapse.debug(
                        "probe length=\(Int(currentLength)) display=\(displayWidth) state=unknown attempts=\(probeResult.attempts)"
                    )
                }
            }

            var bestBracketWidth: CGFloat = 0
            var candidateLength: CGFloat?

            for dKey in observedDisplayKeys {
                let remainingUpward = upwardProbesRemaining[dKey] ?? 2
                if
                    high[dKey] == nil,
                    let currentLow = low[dKey],
                    currentLow == currentLength,
                    remainingUpward > 0
                {
                    let nextUpward = min(currentLow * 2, MenuBarLayoutMath.maximumUnit)
                    let bracket = nextUpward - currentLow
                    if bracket > bestBracketWidth {
                        bestBracketWidth = bracket
                        candidateLength = nextUpward
                    }
                } else if let currentHigh = high[dKey] {
                    let currentLow = low[dKey] ?? MenuBarLayoutMath.minimumUnit
                    if let nextMid = MenuBarLayoutMath.nextProbe(honored: currentLow, dropped: currentHigh) {
                        let bracket = currentHigh - currentLow
                        if bracket > bestBracketWidth {
                            bestBracketWidth = bracket
                            candidateLength = nextMid
                        }
                    }
                }
            }

            guard let next = candidateLength else {
                break
            }

            for dKey in observedDisplayKeys {
                let remainingUpward = upwardProbesRemaining[dKey] ?? 2
                if
                    high[dKey] == nil,
                    let currentLow = low[dKey],
                    currentLow == currentLength,
                    remainingUpward > 0,
                    min(currentLow * 2, MenuBarLayoutMath.maximumUnit) == next
                {
                    upwardProbesRemaining[dKey] = remainingUpward - 1
                    break
                }
            }

            currentLength = next
        }

        if isInterrupted {
            caps[key] = previousCaps
            probingLength = nil
            for divider in dividers {
                divider.reapplyCollapseLength()
            }
            Logger.collapse.debug("collapse search interrupted screens=\(key)")
            return
        }

        if caps[key] == nil {
            caps[key] = [:]
        }
        for dKey in observedDisplayKeys {
            let displayWidth = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
            if let lowVal = low[dKey] {
                caps[key]?[dKey] = lowVal
            } else {
                Logger.collapse.notice("collapse gave up screens=\(key) display=\(displayWidth)")
            }
        }

        probingLength = nil
        isSpacersResting = false
        let displayCaps = caps[key].map { Array($0.values) } ?? []
        let tMin = min(max(hiddenSlotMin, 32), 48)
        let plan = MenuBarLayoutMath.ladderPlan(caps: displayCaps, hiddenSlotMin: hiddenSlotMin)

        for divider in dividers {
            divider.reapplyCollapseLength()
        }

        anchorBlock()

        try? await Task.sleep(for: Self.settleDelay)

        guard let pre = preObservation else {
            return
        }

        guard let post = await observePost() else {
            return
        }

        let verdicts = judge(
            post: post,
            pre: pre,
            activeDivider: activeDivider,
            ladderPlan: plan
        )

        let isSafe = !verdicts.values.contains { $0.dividerLost || $0.visiblePushed }
        let isComplete = isSafe && verdicts.values.allSatisfy { $0.hiddenOnBar == 0 }

        if isComplete {
            failures[key] = 0
            backoff[key] = 20
            nextAllowedSearch.removeValue(forKey: key)
            let totalSpacersOnBar = verdicts.values.map(\.spacersOnBar).reduce(0, +)
            Logger.collapse.notice(
                "collapse honored screens=\(key) divider=\(Int(plan.divider)) ladder=\(Int(tMin)) spacersOnBar=\(totalSpacersOnBar)"
            )
        } else if isSafe {
            if !loggedIncompleteKeys.contains(key) {
                loggedIncompleteKeys.insert(key)
                for (dKey, verdict) in verdicts where verdict.hiddenOnBar > 0 {
                    let displayWidth = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
                    Logger.collapse.notice(
                        "collapse incomplete screens=\(key) display=\(displayWidth) hiddenOnBar=\(verdict.hiddenOnBar) remainder=\(Int(verdict.remainder))"
                    )
                }
            }
        } else {
            isSpacersResting = true
            for divider in dividers {
                divider.reapplyCollapseLength()
            }
            try? await Task.sleep(for: Self.settleDelay)
            if let secondPost = await observePost() {
                let secondVerdicts = judge(
                    post: secondPost,
                    pre: pre,
                    activeDivider: activeDivider,
                    ladderPlan: (plan.divider, [])
                )
                let secondSafe = !secondVerdicts.values.contains { $0.dividerLost || $0.visiblePushed }
                if secondSafe {
                    anchorBlock()
                } else {
                    var failedReason = "dividerLost"
                    var failedDisplayWidth = 0
                    for (dKey, v) in secondVerdicts {
                        let w = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
                        if v.dividerLost {
                            failedReason = "dividerLost"
                            failedDisplayWidth = w
                            break
                        } else if v.visiblePushed {
                            failedReason = "visiblePushed"
                            failedDisplayWidth = w
                            break
                        }
                    }
                    Logger.collapse.notice("collapse refused reason=\(failedReason) display=\(failedDisplayWidth)")
                    onRefusal?()
                }
            } else {
                Logger.collapse.notice("collapse refused reason=unknown display=0")
                onRefusal?()
            }
        }

        if pendingCheck {
            pendingCheck = false
            await check(dividers)
        }
    }

    /// Resolves the honored unit by applying cached caps or running a search.
    func resolve(_ dividers: [ControlItem], onRefusal: (() -> Void)? = nil) async {
        if let onRefusal {
            self.onRefusal = onRefusal
        }

        let collapsedDividers = dividers.filter {
            $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }
        guard !collapsedDividers.isEmpty else {
            return
        }

        if hasPreparedSnapshot {
            hasPreparedSnapshot = false
        } else {
            isSpacersResting = false
            preObservation = MenuBarAgentWindows.observe()
            guard snapshotHiddenBlock(dividers: collapsedDividers) else {
                return
            }
        }

        if isSearching {
            pendingCheck = true
            return
        }

        let widths = NSScreen.screens.map(\.frame.width)
        let key = configurationKey(for: widths)
        if let displayCaps = caps[key], !displayCaps.isEmpty {
            for divider in collapsedDividers {
                divider.reapplyCollapseLength()
            }
            anchorBlock()
            try? await Task.sleep(for: Self.settleDelay)
            await check(collapsedDividers)
        } else {
            let now = Date()
            let allowedDate = nextAllowedSearch[key] ?? now
            if now >= allowedDate {
                await search(dividers: collapsedDividers)
            }
        }
    }

    /// Read-only check to verify whether any display dropped its divider.
    func check(_ dividers: [ControlItem]) async {
        let collapsedDividers = dividers.filter {
            $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }
        guard !collapsedDividers.isEmpty else {
            return
        }
        if isSearching {
            pendingCheck = true
            return
        }
        guard let states = await observeStates(dividers: collapsedDividers) else {
            return
        }
        let widths = NSScreen.screens.map(\.frame.width)
        let key = configurationKey(for: widths)
        let currentFailures = failures[key] ?? 0
        let now = Date()
        let allowedDate = nextAllowedSearch[key] ?? now
        let hasDropped = states.values.contains(.dividerDropped)
        if
            hasDropped,
            currentFailures < 3,
            now >= allowedDate
        {
            let currentDividerLength = unit(for: widths)
            var initialHigh: [String: CGFloat] = [:]
            for (dKey, state) in states where state == .dividerDropped {
                initialHigh[dKey] = currentDividerLength
            }
            await search(dividers: collapsedDividers, initialHigh: initialHigh)
        }
    }

    /// Installs observers for app activation and display configuration changes.
    func installObservers(appState: AppState) {
        guard !areObserversInstalled else {
            return
        }
        areObserversInstalled = true
        self.appState = appState

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self, weak appState] _ in
                guard
                    let self,
                    let appState
                else {
                    return
                }
                let dividers = [
                    appState.menuBarManager.section(withName: .hidden)?.controlItem,
                    appState.menuBarManager.section(withName: .alwaysHidden)?.controlItem,
                ].compactMap { $0 }
                Task {
                    await self.check(dividers)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self, weak appState] _ in
                guard
                    let self,
                    let appState
                else {
                    return
                }
                let dividers = [
                    appState.menuBarManager.section(withName: .hidden)?.controlItem,
                    appState.menuBarManager.section(withName: .alwaysHidden)?.controlItem,
                ].compactMap { $0 }
                Task {
                    await self.resolve(dividers)
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Logger
private extension Logger {
    static let collapse = Logger(category: "Collapse")
}
