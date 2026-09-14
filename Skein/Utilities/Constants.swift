//
//  Constants.swift
//  Skein
//

import Foundation

enum Constants {
    #if DEBUG
    static let isDevelopmentBuild = true
    #else
    static let isDevelopmentBuild = false
    #endif

    static let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Skein"

    // swiftlint:disable force_unwrapping
    /// The version string in the app's bundle.
    static let versionString = Bundle.main.versionString!

    /// The build string in the app's bundle.
    static let buildString = Bundle.main.buildString!

    /// The user-readable copyright string in the app's bundle.
    static let copyrightString = Bundle.main.copyrightString!

    /// The bundle identifier of the app.
    static let bundleIdentifier = Bundle.main.bundleIdentifier!
    // swiftlint:enable force_unwrapping

    /// The identifier for the settings window.
    static let settingsWindowID = "SettingsWindow"

    /// The identifier for the permissions window.
    static let permissionsWindowID = "PermissionsWindow"

    /// The title for the settings window.
    static let settingsWindowTitle = displayName

    /// The title for the permissions window.
    static let permissionsWindowTitle = isDevelopmentBuild ? "Skein Dev Permissions" : "Permissions"
}
