//
//  MenuBarPlatform.swift
//  Skein
//

import Foundation

/// Decides which menu bar implementation Skein uses at runtime.
///
/// macOS 27 composites every status item into MenuBarAgent's single window,
/// so window-based enumeration and length-based hiding no longer work there.
enum MenuBarPlatform {
    /// A Boolean value that indicates whether the menu bar is hosted by MenuBarAgent.
    ///
    /// The `ForceLegacyMenuBar` default exists for diagnosis and needs a relaunch.
    static let usesMenuBarAgent: Bool = {
        guard #available(macOS 27, *) else {
            return false
        }
        return !Defaults.bool(forKey: .forceLegacyMenuBar)
    }()
}
