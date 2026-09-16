//
//  AdvancedSettingsPane.swift
//  Skein
//

import SwiftUI

struct AdvancedSettingsPane: View {
    @EnvironmentObject var appState: AppState
    @State private var maxSliderLabelWidth: CGFloat = 0

    private var menuBarManager: MenuBarManager {
        appState.menuBarManager
    }

    private var manager: AdvancedSettingsManager {
        appState.settingsManager.advancedSettingsManager
    }

    private func formattedToSeconds(_ interval: TimeInterval) -> LocalizedStringKey {
        let formatted = interval.formatted()
        return if interval == 1 {
            LocalizedStringKey(formatted + " second")
        } else {
            LocalizedStringKey(formatted + " seconds")
        }
    }

    @ObservedObject private var collapseController = CollapseController.shared

    var body: some View {
        SkeinForm {
            if MenuBarPlatform.usesMenuBarAgent, collapseController.collapseAnchorUnavailableReason != nil {
                fullDiskAccessCard
            }
            SkeinSection {
                hideApplicationMenus
                showSectionDividers
                showAllSectionsOnUserDrag
                showContextMenuOnRightClick
            }
            SkeinSection {
                enableAlwaysHiddenSection
                canToggleAlwaysHiddenSection
            }
            SkeinSection {
                showOnHoverDelaySlider
                tempShowIntervalSlider
            }
            SkeinSection("Permissions") {
                allPermissions
            }
        }
    }

    @ViewBuilder
    private var hideApplicationMenus: some View {
        Toggle("Hide application menus when showing menu bar items", isOn: manager.bindings.hideApplicationMenus)
            .annotation("Make more room in the menu bar by hiding the left application menus if needed")
    }

    @ViewBuilder
    private var showSectionDividers: some View {
        Toggle("Show section dividers", isOn: manager.bindings.showSectionDividers)
            .annotation {
                HStack(spacing: 2) {
                    Text("Insert divider items")
                    if let nsImage = ControlItemImage.builtin(.chevronLarge).nsImage(for: appState) {
                        HStack(spacing: 0) {
                            Text("(")
                                .font(.body.monospaced().bold())
                            Image(nsImage: nsImage)
                                .padding(.horizontal, -2)
                            Text(")")
                                .font(.body.monospaced().bold())
                        }
                    }
                    Text("between sections")
                }
            }
    }

    @ViewBuilder
    private var enableAlwaysHiddenSection: some View {
        Toggle("Enable always-hidden section", isOn: manager.bindings.enableAlwaysHiddenSection)
    }

    @ViewBuilder
    private var canToggleAlwaysHiddenSection: some View {
        if manager.enableAlwaysHiddenSection {
            Toggle("Always-hidden section can be shown", isOn: manager.bindings.canToggleAlwaysHiddenSection)
                .annotation {
                    if appState.settingsManager.generalSettingsManager.showOnClick {
                        Text("Option + click one of Skein's menu bar items, or inside an empty area of the menu bar to show the section")
                    } else {
                        Text("Option + click one of Skein's menu bar items to show the section")
                    }
                }
        }
    }

    @ViewBuilder
    private var showOnHoverDelaySlider: some View {
        SkeinLabeledContent {
            SkeinSlider(
                formattedToSeconds(manager.showOnHoverDelay),
                value: manager.bindings.showOnHoverDelay,
                in: 0...1,
                step: 0.1
            )
        } label: {
            Text("Show on hover delay")
                .frame(minHeight: .compactSliderMinHeight)
                .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                .onFrameChange { frame in
                    maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                }
        }
        .annotation("The amount of time to wait before showing on hover")
    }

    @ViewBuilder
    private var tempShowIntervalSlider: some View {
        SkeinLabeledContent {
            SkeinSlider(
                formattedToSeconds(manager.tempShowInterval),
                value: manager.bindings.tempShowInterval,
                in: 0...30,
                step: 1
            )
        } label: {
            Text("Temporarily shown item delay")
                .frame(minHeight: .compactSliderMinHeight)
                .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                .onFrameChange { frame in
                    maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                }
        }
        .annotation("The amount of time to wait before hiding temporarily shown menu bar items")
    }

    @ViewBuilder
    private var showAllSectionsOnUserDrag: some View {
        Toggle("Show all sections when Command + dragging menu bar items", isOn: manager.bindings.showAllSectionsOnUserDrag)
    }

    @ViewBuilder
    private var showContextMenuOnRightClick: some View {
        Toggle("Show context menu on right click", isOn: manager.bindings.showContextMenuOnRightClick)
    }

    @ViewBuilder
    private var allPermissions: some View {
        ForEach(appState.permissionsManager.allPermissions) { permission in
            SkeinLabeledContent {
                if permission.hasPermission {
                    Label {
                        Text("Permission Granted")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                } else {
                    Button("Grant Permission") {
                        permission.performRequest()
                    }
                }
            } label: {
                Text(permission.title)
            }
            .frame(height: 22)
        }
    }

    @ViewBuilder
    private var fullDiskAccessCard: some View {
        SkeinSection("Menu Bar Hiding") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hiding menu bar items requires Full Disk Access on macOS 27 because macOS rewrites the menu bar order while items are hidden.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    AdvancedSettingsPane()
        .fixedSize()
        .environmentObject(AppState())
}
