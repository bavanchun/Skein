//
//  MenuBarSection.swift
//  Skein
//

import Cocoa

/// A representation of a section in a menu bar.
@MainActor
final class MenuBarSection {
    /// The name of a menu bar section.
    enum Name: CaseIterable {
        case visible
        case hidden
        case alwaysHidden

        /// A string to show in the interface.
        var displayString: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            case .alwaysHidden: "Always-Hidden"
            }
        }

        /// A string to use for logging purposes.
        var logString: String {
            switch self {
            case .visible: "visible section"
            case .hidden: "hidden section"
            case .alwaysHidden: "always-hidden section"
            }
        }
    }

    /// The name of the section.
    let name: Name

    /// The control item that manages the section.
    let controlItem: ControlItem

    /// The shared app state.
    private weak var appState: AppState?

    /// A timer that manages rehiding the section.
    private var rehideTimer: Timer?

    /// An event monitor that handles starting the rehide timer when the mouse
    /// is outside of the menu bar.
    private var rehideMonitor: UniversalEventMonitor?

    /// A Boolean value that indicates whether the Skein Bar should be used.
    private var useSkeinBar: Bool {
        appState?.settingsManager.generalSettingsManager.useSkeinBar ?? false
    }

    /// A weak reference to the menu bar manager's Skein Bar panel.
    private weak var skeinBarPanel: SkeinBarPanel? {
        appState?.menuBarManager.skeinBarPanel
    }

    /// The best screen to show the Skein Bar on.
    private weak var screenForSkeinBar: NSScreen? {
        guard let appState else {
            return nil
        }
        if appState.isActiveSpaceFullscreen {
            return NSScreen.screenWithMouse ?? NSScreen.main
        } else {
            return NSScreen.main
        }
    }

    /// A Boolean value that indicates whether the section is hidden.
    var isHidden: Bool {
        if useSkeinBar {
            if controlItem.state == .showItems {
                return false
            }
            switch name {
            case .visible, .hidden:
                return skeinBarPanel?.currentSection != .hidden
            case .alwaysHidden:
                return skeinBarPanel?.currentSection != .alwaysHidden
            }
        }
        switch name {
        case .visible, .hidden:
            if skeinBarPanel?.currentSection == .hidden {
                return false
            }
            return controlItem.state == .hideItems
        case .alwaysHidden:
            if skeinBarPanel?.currentSection == .alwaysHidden {
                return false
            }
            return controlItem.state == .hideItems
        }
    }

    /// A Boolean value that indicates whether the section is enabled.
    var isEnabled: Bool {
        if case .visible = name {
            // The visible section should always be enabled.
            return true
        }
        return controlItem.isAddedToMenuBar
    }

    /// Creates a section with the given name, control item, and app state.
    init(name: Name, controlItem: ControlItem, appState: AppState) {
        self.name = name
        self.controlItem = controlItem
        self.appState = appState
    }

    /// Creates a section with the given name and app state.
    convenience init(name: Name, appState: AppState) {
        let controlItem = switch name {
        case .visible:
            ControlItem(identifier: .skeinIcon, appState: appState)
        case .hidden:
            ControlItem(identifier: .hidden, appState: appState)
        case .alwaysHidden:
            ControlItem(identifier: .alwaysHidden, appState: appState)
        }
        self.init(name: name, controlItem: controlItem, appState: appState)
    }

    /// Shows the section.
    func show() {
        guard
            let appState,
            isHidden
        else {
            return
        }
        guard controlItem.isAddedToMenuBar else {
            // The section is disabled.
            // TODO: Can we use isEnabled for this check?
            return
        }
        switch name {
        case .visible where useSkeinBar, .hidden where useSkeinBar:
            Task {
                if let screenForSkeinBar {
                    await skeinBarPanel?.show(section: .hidden, on: screenForSkeinBar)
                }
                for section in appState.menuBarManager.sections {
                    section.controlItem.state = .hideItems
                }
            }
        case .alwaysHidden where useSkeinBar:
            Task {
                if let screenForSkeinBar {
                    await skeinBarPanel?.show(section: .alwaysHidden, on: screenForSkeinBar)
                }
                for section in appState.menuBarManager.sections {
                    section.controlItem.state = .hideItems
                }
            }
        case .visible:
            skeinBarPanel?.close()
            guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
                return
            }
            controlItem.state = .showItems
            hiddenSection.controlItem.state = .showItems
        case .hidden:
            skeinBarPanel?.close()
            guard let visibleSection = appState.menuBarManager.section(withName: .visible) else {
                return
            }
            controlItem.state = .showItems
            visibleSection.controlItem.state = .showItems
        case .alwaysHidden:
            skeinBarPanel?.close()
            guard
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                let visibleSection = appState.menuBarManager.section(withName: .visible)
            else {
                return
            }
            controlItem.state = .showItems
            hiddenSection.controlItem.state = .showItems
            visibleSection.controlItem.state = .showItems
        }
        startRehideChecks()
    }

    /// Hides the section.
    func hide() {
        guard
            let appState,
            !isHidden
        else {
            return
        }
        if MenuBarPlatform.usesMenuBarAgent {
            // The hidden items' own distances have to be recorded before any
            // collapse length is applied, and without them the section stays shown.
            let dividers = [
                appState.menuBarManager.section(withName: .hidden)?.controlItem,
                appState.menuBarManager.section(withName: .alwaysHidden)?.controlItem,
            ].compactMap { $0 }
            guard CollapseController.shared.prepareForCollapse(dividers) else {
                return
            }
        }
        skeinBarPanel?.close()
        switch name {
        case _ where useSkeinBar:
            for section in appState.menuBarManager.sections {
                section.controlItem.state = .hideItems
            }
        case .visible:
            guard
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
            else {
                return
            }
            controlItem.state = .hideItems
            hiddenSection.controlItem.state = .hideItems
            alwaysHiddenSection.controlItem.state = .hideItems
        case .hidden:
            guard
                let visibleSection = appState.menuBarManager.section(withName: .visible),
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden)
            else {
                return
            }
            controlItem.state = .hideItems
            visibleSection.controlItem.state = .hideItems
            alwaysHiddenSection.controlItem.state = .hideItems
        case .alwaysHidden:
            controlItem.state = .hideItems
        }
        appState.allowShowOnHover()
        stopRehideChecks()

        if MenuBarPlatform.usesMenuBarAgent {
            let dividers = [
                appState.menuBarManager.section(withName: .hidden)?.controlItem,
                appState.menuBarManager.section(withName: .alwaysHidden)?.controlItem,
            ].compactMap { $0 }
            Task {
                await CollapseController.shared.resolve(dividers) { [weak self] in
                    self?.show()
                }
            }
        }
    }

    /// Toggles the visibility of the section.
    func toggle() {
        if isHidden {
            show()
        } else {
            hide()
        }
    }

    /// Starts running checks to determine when to rehide the section.
    private func startRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()

        guard
            let appState,
            appState.settingsManager.generalSettingsManager.autoRehide,
            case .timed = appState.settingsManager.generalSettingsManager.rehideStrategy
        else {
            return
        }

        rehideMonitor = UniversalEventMonitor(mask: .mouseMoved) { [weak self] event in
            guard
                let self,
                let screen = NSScreen.main
            else {
                return event
            }
            if NSEvent.mouseLocation.y < screen.visibleFrame.maxY {
                if rehideTimer == nil {
                    rehideTimer = .scheduledTimer(
                        withTimeInterval: appState.settingsManager.generalSettingsManager.rehideInterval,
                        repeats: false
                    ) { [weak self] _ in
                        guard
                            let self,
                            let screen = NSScreen.main
                        else {
                            return
                        }
                        if NSEvent.mouseLocation.y < screen.visibleFrame.maxY {
                            Task {
                                await self.hide()
                            }
                        } else {
                            Task {
                                await self.startRehideChecks()
                            }
                        }
                    }
                }
            } else {
                rehideTimer?.invalidate()
                rehideTimer = nil
            }
            return event
        }

        rehideMonitor?.start()
    }

    /// Stops running checks to determine when to rehide the section.
    private func stopRehideChecks() {
        rehideTimer?.invalidate()
        rehideMonitor?.stop()
        rehideTimer = nil
        rehideMonitor = nil
    }
}

// MARK: MenuBarSection: BindingExposable
extension MenuBarSection: BindingExposable { }

// MARK: - Logger
private extension Logger {
    static let menuBarSection = Logger(category: "MenuBarSection")
}
