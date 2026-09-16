//
//  LayoutBackups.swift
//  Skein
//

import Foundation

/// Manages timestamped backups of MenuBarAgent's layout table on macOS 27.
enum LayoutBackups {
    private static let directoryName = "LayoutBackups"
    private static let maxBackups = 10

    /// The directory where layout backups are stored.
    static var directoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent(Constants.bundleIdentifier)
            .appendingPathComponent(directoryName)
    }

    /// An ISO8601 formatter producing safe filenames.
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]
        return formatter
    }()

    /// Saves a snapshot of the layout table as a binary property list.
    ///
    /// Prunes older backups so that at most the newest 10 are retained.
    @discardableResult
    static func save(_ table: [String: Double]) throws -> URL {
        let fileManager = FileManager.default
        let directory = directoryURL
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let timestamp = dateFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = directory.appendingPathComponent("layout-\(timestamp).plist")

        let plist: [String: Any] = [LayoutTableFile.positionsKey: table]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(to: fileURL, options: .atomic)

        pruneOldBackups()
        return fileURL
    }

    /// Lists existing backup files sorted newest first.
    static func list() -> [(date: Date, url: URL)] {
        let fileManager = FileManager.default
        let directory = directoryURL
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        var backups: [(date: Date, url: URL)] = []
        for url in fileURLs where url.pathExtension == "plist" {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
            backups.append((date: date, url: url))
        }

        return backups.sorted { $0.date > $1.date }
    }

    /// Loads a layout table from a backup file.
    static func load(_ url: URL) -> [String: Double]? {
        guard
            let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return nil
        }
        if let positions = plist[LayoutTableFile.positionsKey] as? [String: NSNumber] {
            return positions.mapValues(\.doubleValue)
        }
        if let positions = plist as? [String: NSNumber] {
            return positions.mapValues(\.doubleValue)
        }
        return nil
    }

    /// Prunes backup files in the directory to keep only the newest 10.
    private static func pruneOldBackups() {
        let existing = list()
        guard existing.count > maxBackups else {
            return
        }
        let fileManager = FileManager.default
        for backup in existing.dropFirst(maxBackups) {
            try? fileManager.removeItem(at: backup.url)
        }
    }
}
