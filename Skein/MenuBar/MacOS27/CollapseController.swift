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

    private var honoredUnit: [String: CGFloat] = [:]
    private(set) var currentUnit: CGFloat
    private var isResolving = false
    private var pendingResolve = false
    private var resolvingKey: String?
    private var areObserversInstalled = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let widths = NSScreen.screens.map(\.frame.width)
        self.currentUnit = MenuBarLayoutMath.startUnit(screenWidths: widths)
    }

    /// Returns the configuration key for the given display widths.
    private func configurationKey(for widths: [CGFloat]) -> String {
        widths
            .map { Int($0) }
            .sorted()
            .map(String.init)
            .joined(separator: "+")
    }

    /// Returns the collapse unit for the given display widths.
    func unit(for widths: [CGFloat]) -> CGFloat {
        let key = configurationKey(for: widths)
        if
            isResolving,
            resolvingKey == key
        {
            return honoredUnit[key] ?? currentUnit
        }
        let userOverride = (Defaults.object(forKey: .collapseUnitOverride) as? NSNumber).map {
            CGFloat(truncating: $0)
        }
        return honoredUnit[key] ?? MenuBarLayoutMath.startUnit(screenWidths: widths, userOverride: userOverride)
    }

    /// Resolves the honored unit by searching across attached displays.
    func resolve(_ dividers: [ControlItem]) async {
        let activeDividers = dividers.filter {
            $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }
        guard !activeDividers.isEmpty else {
            return
        }
        if isResolving {
            pendingResolve = true
            return
        }
        isResolving = true
        defer {
            isResolving = false
        }

        var shouldRun = true
        while shouldRun {
            pendingResolve = false
            let currentActive = dividers.filter {
                $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
            }
            guard !currentActive.isEmpty else {
                break
            }
            await runSearch(for: currentActive, initialHigh: nil)
            shouldRun = pendingResolve
        }
    }

    /// Probes a single divider length across all displays.
    private func probe(_ length: CGFloat, dividers: [ControlItem]) async -> Bool {
        let slotWidth = length + MenuBarLayoutMath.slotPadding
        let before = MenuBarAgentWindows.observe(slotWidth: slotWidth)
        currentUnit = length
        for divider in dividers {
            divider.reapplyCollapseLength()
        }
        try? await Task.sleep(for: Self.settleDelay)
        let after = MenuBarAgentWindows.observe(slotWidth: slotWidth)
        return MenuBarLayoutMath.isHonored(
            before: before,
            after: after,
            expectedIncrease: dividers.count
        )
    }

    /// Executes the binary search for an honored collapse unit.
    private func runSearch(for dividers: [ControlItem], initialHigh: CGFloat?) async {
        let widths = NSScreen.screens.map(\.frame.width)
        let key = configurationKey(for: widths)

        // Computed before this key is marked as resolving, so a new screen
        // configuration starts from its own cached or start unit rather than
        // the unit last probed for the previous configuration.
        var nextLength: CGFloat?
        if let initialHigh {
            nextLength = MenuBarLayoutMath.nextProbe(
                honored: MenuBarLayoutMath.minimumUnit,
                dropped: initialHigh
            )
        } else {
            nextLength = unit(for: widths)
        }

        resolvingKey = key
        defer {
            resolvingKey = nil
        }

        var low: CGFloat?
        var high: CGFloat? = initialHigh
        var probeCount = 0

        while
            let length = nextLength,
            probeCount < 8
        {
            probeCount += 1
            let honored = await probe(length, dividers: dividers)
            if honored {
                low = length
                if high == nil {
                    break
                }
            } else {
                high = length
            }
            guard let currentHigh = high else {
                break
            }
            nextLength = MenuBarLayoutMath.nextProbe(
                honored: low ?? MenuBarLayoutMath.minimumUnit,
                dropped: currentHigh
            )
        }

        if low == nil {
            probeCount += 1
            let honored = await probe(MenuBarLayoutMath.minimumUnit, dividers: dividers)
            if honored {
                low = MenuBarLayoutMath.minimumUnit
            }
        }

        if let low {
            honoredUnit[key] = low
            currentUnit = low
            for divider in dividers {
                divider.reapplyCollapseLength()
            }
            Logger.collapse.notice("collapse self-test honored screens=\(key) unit=\(Int(low)) probes=\(probeCount)")
            let widest = widths.max() ?? 0
            let spacers = MenuBarLayoutMath.spacerCount(widestWidth: widest, unit: low)
            if !MenuBarLayoutMath.coversWidest(widestWidth: widest, unit: low, spacers: spacers) {
                Logger.collapse.notice("collapse incomplete widest=\(Int(widest)) unit=\(Int(low)) spacers=\(spacers)")
            }
        } else {
            currentUnit = MenuBarLayoutMath.minimumUnit
            for divider in dividers {
                divider.reapplyCollapseLength()
            }
            Logger.collapse.notice("collapse self-test failed screens=\(key)")
        }
    }

    /// Verifies the current collapse unit and re-searches downwards if dropped.
    func verifyCurrent(_ dividers: [ControlItem]) async {
        let activeDividers = dividers.filter {
            $0.isAddedToMenuBar && $0.isVisible && $0.state == .hideItems
        }
        guard !activeDividers.isEmpty else {
            return
        }
        if isResolving {
            pendingResolve = true
            return
        }
        let widths = NSScreen.screens.map(\.frame.width)
        let key = configurationKey(for: widths)
        // Hold the resolving flag across the probe too, so a resolution requested
        // while the probe settles waits instead of changing lengths concurrently.
        isResolving = true
        resolvingKey = key
        let honored = await probe(currentUnit, dividers: activeDividers)
        if !honored {
            honoredUnit.removeValue(forKey: key)
            await runSearch(for: activeDividers, initialHigh: currentUnit)
        }
        resolvingKey = nil
        isResolving = false
        if pendingResolve {
            await resolve(dividers)
        }
    }

    /// Installs observers for app activation and display configuration changes.
    func installObservers(appState: AppState) {
        guard !areObserversInstalled else {
            return
        }
        areObserversInstalled = true

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
                    await self.verifyCurrent(dividers)
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
