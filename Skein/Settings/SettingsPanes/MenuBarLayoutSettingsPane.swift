//
//  MenuBarLayoutSettingsPane.swift
//  Skein
//

import SwiftUI

struct MenuBarLayoutSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var tableAccess: LayoutTableFile.Access = .granted
    @State private var isApplying = false

    private var layoutBarsDisabled: Bool {
        if MenuBarPlatform.usesMenuBarAgent {
            switch tableAccess {
            case .denied, .missing:
                return true
            case .granted, .failed:
                return false
            }
        }
        return false
    }

    var body: some View {
        Group {
            if !ScreenCapture.cachedCheckPermissions() {
                missingScreenRecordingPermission
            } else if appState.menuBarManager.isMenuBarHiddenBySystemUserDefaults {
                cannotArrange
            } else {
                SkeinForm(alignment: .leading, spacing: 20) {
                    header
                    if MenuBarPlatform.usesMenuBarAgent {
                        tableAccessBanner
                        repairBanner
                    }
                    layoutBars
                        .disabled(layoutBarsDisabled)
                    if
                        MenuBarPlatform.usesMenuBarAgent,
                        appState.itemManager.pendingLayout.hasChanges
                    {
                        pendingChangesBar
                    }
                }
            }
        }
        .onAppear {
            refreshTableAccess()
        }
        .onDisappear {
            handleDisappear()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            refreshTableAccess()
        }
    }

    @ViewBuilder
    private var header: some View {
        Text("Drag to arrange your menu bar items")
            .font(.title2)

        SkeinGroupBox {
            AnnotationView(
                alignment: .center,
                font: .callout.bold()
            ) {
                Label {
                    Text("Tip: you can also arrange menu bar items by Command + dragging them in the menu bar")
                } icon: {
                    Image(systemName: "lightbulb")
                }
            }
        }
    }

    @ViewBuilder
    private var tableAccessBanner: some View {
        switch tableAccess {
        case .denied:
            SkeinGroupBox {
                HStack {
                    Label {
                        Text("Rearranging menu bar items on macOS 27 needs Full Disk Access")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Spacer()
                    Button("Open Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        case .missing:
            SkeinGroupBox {
                Label {
                    Text("Rearrange an item once with Command-drag, then reopen this pane.")
                } icon: {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
        case .granted, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private var repairBanner: some View {
        if
            appState.itemManager.alwaysHiddenOrderNeedsRepair,
            !appState.itemManager.pendingLayout.hasChanges
        {
            SkeinGroupBox {
                HStack {
                    Label {
                        Text("The always-hidden divider is to the right of the hidden divider.")
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Fix…") {
                        fixAlwaysHiddenOrder()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pendingChangesBar: some View {
        SkeinGroupBox {
            HStack {
                Text("The menu bar reloads once to apply your changes")
                    .font(.callout)
                Spacer()
                Button("Discard") {
                    discardChanges()
                }
                Button("Apply") {
                    applyChanges()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private var layoutBars: some View {
        VStack(spacing: 25) {
            ForEach(MenuBarSection.Name.allCases, id: \.self) { section in
                layoutBar(for: section)
            }
        }
    }

    @ViewBuilder
    private var cannotArrange: some View {
        Text("Skein cannot arrange menu bar items in automatically hidden menu bars")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private var missingScreenRecordingPermission: some View {
        VStack {
            if MenuBarPlatform.usesMenuBarAgent {
                Text("Menu Bar Layout requires Screen Recording on macOS 27")
                    .font(.title2)
            } else {
                Text("Menu bar layout requires screen recording permissions")
                    .font(.title2)
            }

            Button {
                appState.navigationState.settingsNavigationIdentifier = .advanced
            } label: {
                Text("Go to Advanced Settings")
            }
            .buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func layoutBar(for section: MenuBarSection.Name) -> some View {
        if
            let section = appState.menuBarManager.section(withName: section),
            section.isEnabled
        {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(section.name.displayString) Section")
                    .font(.system(size: 14))
                    .padding(.leading, 2)

                LayoutBar(section: section)
                    .environmentObject(appState.imageCache)

                if
                    MenuBarPlatform.usesMenuBarAgent,
                    section.name == .alwaysHidden
                {
                    Text("Show the always-hidden section once to load its images.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
        }
    }

    private func refreshTableAccess() {
        if MenuBarPlatform.usesMenuBarAgent {
            tableAccess = LayoutTableFile.access()
        }
    }

    private func fixAlwaysHiddenOrder() {
        let alert = NSAlert()
        alert.messageText = "Move the always-hidden divider? The menu bar reloads once."
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        Task {
            let hKey = "status:\(Constants.bundleIdentifier)::\(ControlItem.Identifier.hidden.rawValue)"
            let ahKey = "status:\(Constants.bundleIdentifier)::\(ControlItem.Identifier.alwaysHidden.rawValue)"
            let result = await LayoutTableWriter.apply([.leftOf(key: ahKey, target: hKey)])
            if result != .applied {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Could not move divider: \(result)"
                errorAlert.runModal()
            }
        }
    }

    private func applyChanges() {
        let alert = NSAlert()
        alert.messageText = "Apply menu bar layout changes? The menu bar reloads once."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isApplying = true
        Task {
            defer {
                isApplying = false
            }
            let result = await appState.itemManager.pendingLayout.apply()
            if result != .applied {
                let errorAlert = NSAlert()
                switch result {
                case .refused(let reason):
                    errorAlert.messageText = reason
                default:
                    errorAlert.messageText = "Failed to apply changes: \(result)"
                }
                errorAlert.runModal()
            }
        }
    }

    private func discardChanges() {
        appState.itemManager.pendingLayout.discard()
        Task {
            await appState.itemManager.cacheItemsFromAccessibility()
        }
    }

    private func handleDisappear() {
        guard
            MenuBarPlatform.usesMenuBarAgent,
            !isApplying,
            appState.itemManager.pendingLayout.hasChanges
        else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Apply your menu bar changes?"
        alert.informativeText = "The menu bar reloads once to apply your changes."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Editing")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            isApplying = true
            Task {
                defer {
                    isApplying = false
                }
                let result = await appState.itemManager.pendingLayout.apply()
                if result != .applied {
                    let errorAlert = NSAlert()
                    switch result {
                    case .refused(let reason):
                        errorAlert.messageText = reason
                    default:
                        errorAlert.messageText = "Failed to apply changes: \(result)"
                    }
                    errorAlert.runModal()
                }
            }
        case .alertSecondButtonReturn:
            discardChanges()
        case .alertThirdButtonReturn:
            appState.navigationState.settingsNavigationIdentifier = .menuBarLayout
            appState.openSettingsWindow()
            appState.activate(withPolicy: .regular)
        default:
            break
        }
    }
}
