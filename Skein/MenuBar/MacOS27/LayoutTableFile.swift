//
//  LayoutTableFile.swift
//  Skein
//

import Foundation

/// Access to MenuBarAgent's layout table on macOS 27.
///
/// macOS 27 denies other teams' group containers by default, and a denied
/// preferences domain reads as "not found", so access is checked with `open(2)`
/// and "written" always means the bytes on disk contain the change.
enum LayoutTableFile {
    /// The key holding each item's distance from the trailing edge.
    static let positionsKey = "TrailingItemPreferredPositions"

    /// The layout table's location in Apple's group container.
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist")

    /// The preferences domain addressing the table file by path.
    static var preferencesDomain: CFString {
        (url.path as NSString).deletingPathExtension as CFString
    }

    /// The result of probing the table file with `open(2)`.
    enum Access: CustomStringConvertible {
        case granted
        case denied
        case missing
        case failed(Int32)

        var description: String {
            switch self {
            case .granted: "granted"
            case .denied: "denied"
            case .missing: "missing"
            case .failed(let code): "failed(\(code))"
            }
        }
    }

    /// Probes read access to the table file without prompting.
    static func access() -> Access {
        let descriptor = open(url.path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        switch errno {
        case EACCES, EPERM: return .denied
        case ENOENT: return .missing
        case let code: return .failed(code)
        }
    }

    /// Reads the positions by parsing the file bytes, bypassing the preferences cache.
    static func readFromDisk() -> [String: Double]? {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let positions = plist[positionsKey] as? [String: NSNumber]
        else {
            return nil
        }
        return positions.mapValues(\.doubleValue)
    }

    /// Reads the positions through CFPreferences after synchronizing the domain.
    static func readViaPreferences() -> [String: Double]? {
        CFPreferencesAppSynchronize(preferencesDomain)
        guard let positions = CFPreferencesCopyAppValue(positionsKey as CFString, preferencesDomain) as? [String: NSNumber] else {
            return nil
        }
        return positions.mapValues(\.doubleValue)
    }
}
