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

    /// The outcome of applying relative moves or restoring a layout backup.
    enum ApplyResult: Equatable {
        case applied
        case refused(String)
        case unreadable
        case noChange
        case writeFailed
        case backupFailed
        case restartFailedRolledBack
        case restartFailedRollbackFailed
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
            if
                let fresh = LayoutTableFile.readFromDisk(),
                fresh == table
            {
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

    /// Applies a list of relative moves to the layout table with preflight, backup, disk verification,
    /// and either live-resort or restart with rollback.
    @MainActor
    static func apply(_ moves: [MenuBarLayoutMath.Move]) async -> ApplyResult {
        if let reason = MenuBarAgentRestarter.preflight() {
            Logger.layoutTableWriter.notice("layout table apply result=refused: \(reason)")
            return .refused(reason)
        }

        guard
            case .granted = LayoutTableFile.access(),
            let fresh = LayoutTableFile.readFromDisk()
        else {
            Logger.layoutTableWriter.notice("layout table apply result=unreadable")
            return .unreadable
        }

        guard
            let next = MenuBarLayoutMath.applyMoves(moves, to: fresh),
            next.count == fresh.count
        else {
            Logger.layoutTableWriter.notice("layout table apply result=noChange")
            return .noChange
        }

        guard next != fresh else {
            Logger.layoutTableWriter.notice("layout table apply result=noChange")
            return .noChange
        }

        do {
            _ = try LayoutBackups.save(fresh)
        } catch {
            Logger.layoutTableWriter.error("layout table apply result=backupFailed")
            return .backupFailed
        }

        guard write(next) else {
            Logger.layoutTableWriter.error("layout table apply result=writeFailed")
            return .writeFailed
        }

        if MenuBarAgentRestarter.liveResortApplies {
            try? await Task.sleep(for: .seconds(1))
            Logger.layoutTableWriter.notice("layout table apply result=applied")
            return .applied
        }

        if await MenuBarAgentRestarter.restart() {
            Logger.layoutTableWriter.notice("layout table apply result=applied")
            return .applied
        } else {
            let rolledBack = write(fresh)
            if rolledBack {
                Logger.layoutTableWriter.error("layout table apply result=restartFailedRolledBack")
                return .restartFailedRolledBack
            } else {
                Logger.layoutTableWriter.error("layout table apply result=restartFailedRollbackFailed")
                return .restartFailedRollbackFailed
            }
        }
    }

    /// Restores a layout table snapshot from a backup file with preflight, backup of current state,
    /// disk verification, and MenuBarAgent restart with rollback.
    @MainActor
    static func restore(_ url: URL) async -> ApplyResult {
        guard let table = LayoutBackups.load(url) else {
            Logger.layoutTableWriter.notice("layout table apply result=unreadable")
            return .unreadable
        }

        if let reason = MenuBarAgentRestarter.preflight() {
            Logger.layoutTableWriter.notice("layout table apply result=refused: \(reason)")
            return .refused(reason)
        }

        guard
            case .granted = LayoutTableFile.access(),
            let fresh = LayoutTableFile.readFromDisk()
        else {
            Logger.layoutTableWriter.notice("layout table apply result=unreadable")
            return .unreadable
        }

        guard table.count == fresh.count else {
            Logger.layoutTableWriter.notice("layout table apply result=refused: key count differs")
            return .refused("key count differs")
        }

        guard table != fresh else {
            Logger.layoutTableWriter.notice("layout table apply result=noChange")
            return .noChange
        }

        do {
            _ = try LayoutBackups.save(fresh)
        } catch {
            Logger.layoutTableWriter.error("layout table apply result=backupFailed")
            return .backupFailed
        }

        guard write(table) else {
            Logger.layoutTableWriter.error("layout table apply result=writeFailed")
            return .writeFailed
        }

        if await MenuBarAgentRestarter.restart() {
            Logger.layoutTableWriter.notice("layout table apply result=applied")
            return .applied
        } else {
            let rolledBack = write(fresh)
            if rolledBack {
                Logger.layoutTableWriter.error("layout table apply result=restartFailedRolledBack")
                return .restartFailedRolledBack
            } else {
                Logger.layoutTableWriter.error("layout table apply result=restartFailedRollbackFailed")
                return .restartFailedRollbackFailed
            }
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let layoutTableWriter = Logger(category: "LayoutTableWriter")
}
