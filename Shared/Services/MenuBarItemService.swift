//
//  MenuBarItemService.swift
//  Shared
//

import CoreGraphics
import Foundation

enum MenuBarItemService {
    #if DEBUG
    static let name = "com.ariadnev.Skein.dev.MenuBarItemService"
    #else
    static let name = "com.ariadnev.Skein.MenuBarItemService"
    #endif
}

extension MenuBarItemService {
    /// The window information the service needs to resolve a source pid.
    ///
    /// This carries only the two fields the service reads. The app's full
    /// `WindowInfo` stays out of the shared folder and out of the wire format.
    struct ItemWindow: Codable {
        let windowID: CGWindowID
        let bounds: CGRect
    }

    enum Request: Codable {
        case start
        case sourcePID(ItemWindow)
    }

    enum Response: Codable {
        case start
        case sourcePID(pid_t?)
    }
}
