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

    /// Keys of the hidden block remembered for the current collapse.
    private var rememberedBlockKeys: [String] = []

    /// Indicates whether the hidden block was snapshotted before the collapse lengths were applied.
    private var hasPreparedSnapshot = false

    /// Refusal handler provided by the section owner to restore dividers to shown state without direct section calls.
    private var onRefusal: (() -> Void)?

    /// Honored divider lengths keyed by screen configuration key, then by display frame key.
    private var caps: [String: [String: CGFloat]] = [:]

    /// Honored spacer lengths keyed by screen configuration key.
    private var spacerLengths: [String: CGFloat] = [:]

    /// The spacer length currently being probed during an active spacer search.
    private var probingSpacerLength: CGFloat?

    /// The most recent screen configuration key observed.
    private var lastConfigurationKey: String?

    /// Honored fill spacer lengths keyed by screen configuration key.
    private var fills: [String: [CGFloat]] = [:]

    /// The fill spacer length currently being probed.
    private var probeFill: CGFloat?

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
            let spacerLength = spacerLengths[key] ?? MenuBarLayoutMath.firstSpacerLength(caps: capsList)
            var divider = MenuBarLayoutMath.spacerPlan(caps: capsList, spacerLength: spacerLength).divider
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
        let key = configurationKey(for: widths)
        if let displayCaps = caps[key], !displayCaps.isEmpty {
            let capsList = Array(displayCaps.values)
            let spacerLength: CGFloat
            if isSearching, let probingSpacerLength {
                spacerLength = probingSpacerLength
            } else {
                spacerLength = spacerLengths[key] ?? MenuBarLayoutMath.firstSpacerLength(caps: capsList)
            }
            let plan = MenuBarLayoutMath.spacerPlan(caps: capsList, spacerLength: spacerLength)
            let currentFills = (fills[key] ?? []) + (probeFill.map { [$0] } ?? [])
            let combined = plan.spacers + currentFills
            return Array(combined.prefix(MenuBarLayoutMath.maximumSpacersPerDivider))
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

        var states: [String: MenuBarLayoutMath.DisplayState] = [:]
        for (displayKey, observation) in observations {
            states[displayKey] = MenuBarLayoutMath.state(
                of: observation,
                dividerIdentifier: divider.autosaveName,
                dividerSlotWidth: dividerSlotWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths
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

        var totalLeaked = Set<pid_t>()
        for (_, observation) in observations {
            let leaked = MenuBarLayoutMath.leakedProcessIdentifiers(
                in: observation,
                dividerIdentifier: divider.autosaveName,
                dividerSlotWidth: dividerSlotWidth,
                ownIdentifiers: ownIDs,
                ownSlotWidths: ownWidths,
                hiddenPIDs: hiddenPIDs
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
            blockKeys.append(key)
        }

        blockKeys.sort { (table[$0] ?? 0) > (table[$1] ?? 0) }
        Defaults.set(blockKeys, forKey: .collapseHiddenBlock)
        rememberedBlockKeys = blockKeys

        if let observations = MenuBarAgentWindows.observe() {
            let currentPID = NSRunningApplication.current.processIdentifier
            var pids = Set<pid_t>()
            for (_, observation) in observations {
                guard let dividerSlot = observation.slots.first(where: {
                    $0.identifier == activeDivider.autosaveName
                }) else {
                    continue
                }
                for slot in observation.slots {
                    guard
                        !slot.isChevron,
                        slot.frame.minX < dividerSlot.frame.minX,
                        let pid = slot.pid,
                        pid != currentPID
                    else {
                        continue
                    }
                    pids.insert(pid)
                }
            }
            hiddenPIDs = pids
        }

        collapseAnchorUnavailableReason = nil
        return true
    }

    /// Anchors the hidden block keys with values starting at 8192.
    @discardableResult
    private func anchorBlock() -> Bool {
        let blockKeys = rememberedBlockKeys.isEmpty
            ? (Defaults.stringArray(forKey: .collapseHiddenBlock) ?? (Defaults.array(forKey: .collapseHiddenBlock) as? [String]) ?? [])
            : rememberedBlockKeys

        guard !blockKeys.isEmpty else {
            return true
        }

        let result = LayoutTableWriter.apply { table in
            var next = table
            let count = blockKeys.count
            for (index, key) in blockKeys.enumerated() {
                guard let currentDist = next[key] else {
                    continue
                }
                if currentDist < 8192.0 {
                    let rank = count - 1 - index
                    next[key] = 8192.0 + Double(rank) * 8.0
                }
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

        guard
            let dividerKey = table.keys.first(where: {
                $0.hasPrefix("status:") && $0.hasSuffix("::\(ControlItem.Identifier.hidden.rawValue)")
            }),
            let dividerDist = table[dividerKey]
        else {
            return
        }

        let needsRepair = remembered.contains { (table[$0] ?? 0) <= dividerDist }
        guard needsRepair else {
            return
        }

        let result = LayoutTableWriter.apply { current in
            var next = current
            let count = remembered.count
            for (index, key) in remembered.enumerated() {
                let rank = count - 1 - index
                next[key] = 8192.0 + Double(rank) * 8.0
            }
            return next
        }

        if result == .written {
            Logger.collapse.notice("collapse block repaired count=\(remembered.count)")
        }
    }

    /// Determines whether a slot represents an honored spacer on a display.
    private func isHonoredSpacer(
        _ slot: MenuBarLayoutMath.Slot,
        candidate: CGFloat,
        dividerAutosaveName: String
    ) -> Bool {
        guard !slot.isChevron, slot.frame.width > 0 else {
            return false
        }
        let expectedWidth = candidate + MenuBarLayoutMath.slotPadding
        guard abs(slot.frame.width - expectedWidth) <= 1 else {
            return false
        }
        if let id = slot.identifier {
            return id.hasPrefix(dividerAutosaveName) && id.contains("Spacer")
        }
        if let pid = slot.pid {
            return pid == NSRunningApplication.current.processIdentifier
        }
        return true
    }

    /// Searches for the honored spacer length on wide displays.
    private func searchSpacers(
        dividers: [ControlItem],
        key: String,
        displayCaps: [CGFloat]
    ) async -> Bool {
        guard displayCaps.count > 1 else {
            spacerLengths[key] = MenuBarLayoutMath.firstSpacerLength(caps: displayCaps)
            return true
        }
        guard let activeDivider = dividers.first(where: {
            $0.identifier == .hidden && $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }) ?? dividers.first(where: {
            $0.identifier == .alwaysHidden && $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }) ?? dividers.first else {
            return false
        }

        var candidate = MenuBarLayoutMath.firstSpacerLength(caps: displayCaps)
        var accepted = false

        for attempt in 1...4 {
            guard dividers.allSatisfy(isCollapsed) else {
                return false
            }

            probingSpacerLength = candidate
            for divider in dividers {
                divider.reapplyCollapseLength()
            }
            try? await Task.sleep(for: Self.settleDelay)

            guard
                dividers.allSatisfy(isCollapsed),
                let states = await observeStates(dividers: dividers),
                let observations = MenuBarAgentWindows.observe()
            else {
                return false
            }

            let dividerPresentOnAll = !states.isEmpty && !states.values.contains(.dividerDropped)

            let maxWidth = observations.keys.map { dKey in
                dKey.split(separator: ",").last.flatMap { Double($0) } ?? 0
            }.max() ?? 0

            var narrowerHonorsSpacer = false
            for (dKey, observation) in observations {
                let width = dKey.split(separator: ",").last.flatMap { Double($0) } ?? 0
                let isWidest = width >= maxWidth - 1
                if !isWidest {
                    let spacerCount = observation.slots.filter {
                        isHonoredSpacer($0, candidate: candidate, dividerAutosaveName: activeDivider.autosaveName)
                    }.count
                    if spacerCount > 0 {
                        narrowerHonorsSpacer = true
                        break
                    }
                }
            }

            if dividerPresentOnAll && !narrowerHonorsSpacer {
                accepted = true
                spacerLengths[key] = candidate
                break
            }

            if attempt < 4 {
                candidate += MenuBarLayoutMath.searchResolution
            }
        }

        probingSpacerLength = nil
        for divider in dividers {
            divider.reapplyCollapseLength()
        }

        if !accepted {
            spacerLengths[key] = candidate
            Logger.collapse.notice("collapse spacer search incomplete")
        }

        return true
    }

    /// Searches for the honored divider lengths per display.
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
            probingSpacerLength = nil
            probeFill = nil
        }

        let widths = NSScreen.screens.map(\.frame.width)
        let key = configurationKey(for: widths)
        let previousCaps = caps[key]
        let previousSpacerLength = spacerLengths[key]
        let previousFills = fills[key]
        fills[key] = nil
        spacerLengths[key] = nil
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
                    // The anchor is what keeps the user's order intact, so a refused
                    // write stops the search with the previous lengths restored.
                    caps[key] = previousCaps
                    spacerLengths[key] = previousSpacerLength
                    fills[key] = previousFills
                    probingLength = nil
                    probingSpacerLength = nil
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
            spacerLengths[key] = previousSpacerLength
            fills[key] = previousFills
            probingLength = nil
            probingSpacerLength = nil
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
        let displayCaps = caps[key].map { Array($0.values) } ?? []
        let spacerSearchCompleted = await searchSpacers(
            dividers: dividers,
            key: key,
            displayCaps: displayCaps
        )
        guard spacerSearchCompleted else {
            caps[key] = previousCaps
            spacerLengths[key] = previousSpacerLength
            fills[key] = previousFills
            probingLength = nil
            probingSpacerLength = nil
            for divider in dividers {
                divider.reapplyCollapseLength()
            }
            Logger.collapse.debug("collapse search interrupted screens=\(key)")
            return
        }

        for divider in dividers {
            divider.reapplyCollapseLength()
        }

        try? await Task.sleep(for: Self.settleDelay)

        let postSearchStates = await observeStates(dividers: dividers)
        let postSearchSummary = postSearchStates.flatMap { MenuBarLayoutMath.summary(Array($0.values)) }

        anchorBlock()

        let spacerLength = spacerLengths[key] ?? MenuBarLayoutMath.firstSpacerLength(caps: displayCaps)
        let plan = MenuBarLayoutMath.spacerPlan(caps: displayCaps, spacerLength: spacerLength)
        let spacerString = plan.spacers.map { "\(Int($0))" }.joined(separator: "+")

        let hasAnyVisible = postSearchStates?.values.contains(.itemsVisible) ?? false

        if postSearchSummary == .collapsed && !hasAnyVisible {
            failures[key] = 0
            backoff[key] = 20
            nextAllowedSearch.removeValue(forKey: key)

            if hiddenPIDs.isEmpty {
                Logger.collapse.notice(
                    "collapse nothing to hide screens=\(key) divider=\(Int(plan.divider)) spacers=\(spacerString)"
                )
            } else {
                Logger.collapse.notice(
                    "collapse honored screens=\(key) divider=\(Int(plan.divider)) spacers=\(spacerString)"
                )
            }
        } else if postSearchSummary == .dividerDropped {
            failures[key, default: 0] += 1
            let currentBackoff = backoff[key] ?? 20
            let nextBackoff = min(currentBackoff * 2, 300)
            backoff[key] = nextBackoff
            nextAllowedSearch[key] = Date().addingTimeInterval(nextBackoff)

            Logger.collapse.notice("collapse dropped screens=\(key)")
        } else {
            await fill(dividers: dividers, key: key)
        }

        if pendingCheck {
            pendingCheck = false
            await check(dividers)
        }
    }

    /// Probes and adds fill spacers for wide displays where items remain visible.
    private func fill(dividers: [ControlItem], key: String) async {
        let displayCaps = caps[key].map { Array($0.values) } ?? []
        let spacerLength = spacerLengths[key] ?? MenuBarLayoutMath.firstSpacerLength(caps: displayCaps)
        let plan = MenuBarLayoutMath.spacerPlan(caps: displayCaps, spacerLength: spacerLength)
        guard let bounds = MenuBarLayoutMath.fillBounds(caps: displayCaps, plan: plan) else {
            let finalStates = await observeStates(dividers: dividers)
            if let finalStates {
                for (dKey, st) in finalStates where st == .itemsVisible {
                    let displayWidth = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
                    Logger.collapse.notice("collapse incomplete screens=\(key) display=\(displayWidth)")
                }
            }
            return
        }

        var candidate = bounds.upper
        var probeCount = 0
        let previousFills = fills[key]

        while
            (plan.spacers.count + (fills[key]?.count ?? 0)) < MenuBarLayoutMath.maximumSpacersPerDivider,
            probeCount < 12
        {
            probeCount += 1
            probeFill = candidate
            for divider in dividers {
                divider.reapplyCollapseLength()
            }
            try? await Task.sleep(for: Self.settleDelay)

            guard
                dividers.allSatisfy(isCollapsed),
                let states = await observeStates(dividers: dividers)
            else {
                fills[key] = previousFills
                probeFill = nil
                for divider in dividers {
                    divider.reapplyCollapseLength()
                }
                Logger.collapse.debug("collapse fill interrupted screens=\(key)")
                return
            }

            for (dKey, state) in states {
                let displayWidth = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
                Logger.collapse.debug(
                    "probe length=\(Int(candidate)) display=\(displayWidth) state=\(state.rawValue) attempts=1"
                )
            }

            let hasDropped = states.values.contains(.dividerDropped)
            if hasDropped {
                let mid = (candidate + bounds.lower) / 2
                let next = (mid / MenuBarLayoutMath.searchResolution).rounded(.down) * MenuBarLayoutMath.searchResolution
                if next < bounds.lower {
                    break
                }
                candidate = next
            } else {
                fills[key, default: []].append(candidate)
                let stillVisible = states.values.contains(.itemsVisible)
                if !stillVisible {
                    break
                }
            }
        }

        probeFill = nil
        for divider in dividers {
            divider.reapplyCollapseLength()
        }
        try? await Task.sleep(for: Self.settleDelay)

        let finalStates = await observeStates(dividers: dividers)
        let summaryState = finalStates.flatMap { MenuBarLayoutMath.summary(Array($0.values)) }

        anchorBlock()

        let allSpacers = plan.spacers + (fills[key] ?? [])
        let spacerString = allSpacers.map { "\(Int($0))" }.joined(separator: "+")

        let hasAnyVisible = finalStates?.values.contains(.itemsVisible) ?? false

        if summaryState == .collapsed && !hasAnyVisible {
            failures[key] = 0
            backoff[key] = 20
            nextAllowedSearch.removeValue(forKey: key)

            if hiddenPIDs.isEmpty {
                Logger.collapse.notice(
                    "collapse nothing to hide screens=\(key) divider=\(Int(plan.divider)) spacers=\(spacerString)"
                )
            } else {
                Logger.collapse.notice(
                    "collapse honored screens=\(key) divider=\(Int(plan.divider)) spacers=\(spacerString)"
                )
            }
        } else if summaryState == .dividerDropped {
            failures[key, default: 0] += 1
            let currentBackoff = backoff[key] ?? 20
            let nextBackoff = min(currentBackoff * 2, 300)
            backoff[key] = nextBackoff
            nextAllowedSearch[key] = Date().addingTimeInterval(nextBackoff)

            Logger.collapse.notice("collapse dropped screens=\(key)")
        } else if summaryState == .itemsVisible || hasAnyVisible {
            if let finalStates {
                for (dKey, st) in finalStates where st == .itemsVisible {
                    let displayWidth = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
                    Logger.collapse.notice("collapse incomplete screens=\(key) display=\(displayWidth)")
                }
            }
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
        if let last = lastConfigurationKey, last != key {
            spacerLengths.removeValue(forKey: last)
        }
        lastConfigurationKey = key
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
