//
//  LayoutTableWriter.swift
//  Skein
//

import Foundation

/// Safely applies read-modify-write changes to MenuBarAgent's layout table on macOS 27.
enum LayoutTableWriter {
    /// The outcome of an attempt to apply changes to the layout table.
    enum WriteResult: Equatable {
        case written
        case unreadable
        case denied
        case noChange
        case verifyFailed
        case backupFailed
    }

    /// Tracks whether a backup has already been performed during this application session.
    private static var hasBackedUpThisSession = false

    /// Writes the table through CFPreferences and verifies the written bytes on disk.
    static func write(_ table: [String: Double]) -> Bool {
        let domain = LayoutTableFile.preferencesDomain
        let positionsKey = LayoutTableFile.positionsKey as CFString

        CFPreferencesSetAppValue(positionsKey, table as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            Logger.layoutTableWriter.error("CFPreferencesAppSynchronize failed")
            return false
        }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            if let fresh = LayoutTableFile.readFromDisk(), fresh == table {
                return true
            }
        }

        Logger.layoutTableWriter.error("layout table write failed")
        return false
    }

    /// Reads the layout table fresh from disk, applies the modification closure,
    /// performs a backup before the first write of the session, and writes the verified result.
    static func apply(_ change: ([String: Double]) -> [String: Double]?) -> WriteResult {
        guard case .granted = LayoutTableFile.access() else {
            Logger.layoutTableWriter.notice("layout table apply refused: denied")
            return .denied
        }

        guard let fresh = LayoutTableFile.readFromDisk() else {
            Logger.layoutTableWriter.notice("layout table apply refused: unreadable")
            return .unreadable
        }

        guard
            let next = change(fresh),
            next.count == fresh.count
        else {
            Logger.layoutTableWriter.notice("layout table apply refused: noChange")
            return .noChange
        }

        guard next != fresh else {
            return .noChange
        }

        if !hasBackedUpThisSession {
            do {
                _ = try LayoutBackups.save(fresh)
                hasBackedUpThisSession = true
            } catch {
                Logger.layoutTableWriter.error("layout table apply refused: backupFailed")
                return .backupFailed
            }
        }

        guard write(next) else {
            Logger.layoutTableWriter.error("layout table apply failed: verifyFailed")
            return .verifyFailed
        }

        Logger.layoutTableWriter.notice("layout table apply succeeded: written count=\(next.count)")
        return .written
    }
}

// MARK: - Logger
private extension Logger {
    static let layoutTableWriter = Logger(category: "LayoutTableWriter")
}
