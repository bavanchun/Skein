//
//  CollapseController.swift
//  Skein
//

import Cocoa
import Combine

/// Finds, verifies and maintains the honored collapse length for section dividers on macOS 27.
@MainActor
final class CollapseController {
    static let shared = CollapseController()

    private static let settleDelay: Duration = .milliseconds(350)

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
            var divider = MenuBarLayoutMath.ladderLengths(caps: Array(displayCaps.values)).divider
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
            return MenuBarLayoutMath.ladderLengths(caps: Array(displayCaps.values)).spacers
        }
        return []
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

        var ownIdentifiers: Set<String> = [
            ControlItem.Identifier.skeinIcon.rawValue,
            ControlItem.Identifier.hidden.rawValue,
            ControlItem.Identifier.alwaysHidden.rawValue,
        ]
        for i in 0..<MenuBarLayoutMath.maximumSpacersPerDivider {
            ownIdentifiers.insert("HItemSpacer\(i)")
            ownIdentifiers.insert("AHItemSpacer\(i)")
        }

        var ownSlotWidths: Set<CGFloat> = []
        for d in dividers where d.length > 0 {
            ownSlotWidths.insert(d.length + MenuBarLayoutMath.slotPadding)
        }
        ownSlotWidths.insert(CollapseSpacers.restingLength + MenuBarLayoutMath.slotPadding)
        let widths = NSScreen.screens.map(\.frame.width)
        for spacerLength in spacerLengths(for: widths) {
            ownSlotWidths.insert(spacerLength + MenuBarLayoutMath.slotPadding)
        }
        if let skeinItem = appState?.menuBarManager.section(withName: .visible)?.controlItem {
            let skeinWidth = skeinItem.window?.frame.width ?? skeinItem.length
            if skeinWidth > 0 {
                ownSlotWidths.insert(skeinWidth + MenuBarLayoutMath.slotPadding)
            }
        }

        let dividerSlotWidth = (probingLength ?? divider.length) + MenuBarLayoutMath.slotPadding

        var states: [String: MenuBarLayoutMath.DisplayState] = [:]
        for (displayKey, observation) in observations {
            states[displayKey] = MenuBarLayoutMath.state(
                of: observation,
                dividerIdentifier: divider.autosaveName,
                dividerSlotWidth: dividerSlotWidth,
                ownIdentifiers: ownIdentifiers,
                ownSlotWidths: ownSlotWidths
            )
        }
        return states
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
        }

        let widths = NSScreen.screens.map(\.frame.width)
        let key = configurationKey(for: widths)
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

        while probeCount < 12 {
            probeCount += 1
            probingLength = currentLength
            activeDivider.applyProbeLength(currentLength)
            try? await Task.sleep(for: Self.settleDelay)

            guard let states = await observeStates(dividers: dividers) else {
                break
            }

            for (dKey, state) in states {
                observedDisplayKeys.insert(dKey)
                let displayWidth = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
                Logger.collapse.debug(
                    "probe length=\(Int(currentLength)) display=\(displayWidth) state=\(state.rawValue)"
                )
                if state != .dividerDropped {
                    low[dKey] = max(low[dKey] ?? 0, currentLength)
                } else {
                    let prevHigh = high[dKey] ?? currentLength
                    high[dKey] = min(prevHigh, currentLength)
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

        isSearching = false
        probingLength = nil
        for divider in dividers {
            divider.reapplyCollapseLength()
        }

        try? await Task.sleep(for: Self.settleDelay)

        let finalStates = await observeStates(dividers: dividers)
        let summaryState = finalStates.flatMap { MenuBarLayoutMath.summary(Array($0.values)) }

        if summaryState == .collapsed {
            failures[key] = 0
            backoff[key] = 20
            nextAllowedSearch.removeValue(forKey: key)

            let displayCaps = caps[key].map { Array($0.values) } ?? []
            let ladder = MenuBarLayoutMath.ladderLengths(caps: displayCaps)
            let spacerString = ladder.spacers.map { "\(Int($0))" }.joined(separator: "+")
            Logger.collapse.notice(
                "collapse honored screens=\(key) divider=\(Int(ladder.divider)) spacers=\(spacerString)"
            )
        } else if summaryState == .dividerDropped {
            failures[key, default: 0] += 1
            let currentBackoff = backoff[key] ?? 20
            let nextBackoff = min(currentBackoff * 2, 300)
            backoff[key] = nextBackoff
            nextAllowedSearch[key] = Date().addingTimeInterval(nextBackoff)

            Logger.collapse.notice("collapse dropped screens=\(key)")
        } else if summaryState == .itemsVisible {
            if let finalStates {
                for (dKey, st) in finalStates where st == .itemsVisible {
                    let displayWidth = dKey.split(separator: ",").last.flatMap { Int($0) } ?? 0
                    Logger.collapse.notice("collapse incomplete screens=\(key) display=\(displayWidth)")
                }
            }
        }

        if pendingCheck {
            pendingCheck = false
            await check(dividers)
        }
    }

    /// Resolves the honored unit by applying cached caps or running a search.
    func resolve(_ dividers: [ControlItem]) async {
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
        let widths = NSScreen.screens.map(\.frame.width)
        let key = configurationKey(for: widths)
        if let displayCaps = caps[key], !displayCaps.isEmpty {
            for divider in collapsedDividers {
                divider.reapplyCollapseLength()
            }
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
                if let existingCap = caps[key]?[dKey] {
                    caps[key]?[dKey] = max(
                        existingCap - MenuBarLayoutMath.searchResolution,
                        MenuBarLayoutMath.minimumUnit
                    )
                }
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
