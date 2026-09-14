//
//  MigrationManager.swift
//  Skein
//

import Cocoa

@MainActor
struct MigrationManager {
    let appState: AppState
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
}

// MARK: - Migrate All

extension MigrationManager {
    /// Performs all migrations.
    ///
    /// The import from the Frost defaults domain runs first, so the icon
    /// migration that follows sees the settings it is meant to repair.
    static func migrateAll(appState: AppState) {
        let manager = MigrationManager(appState: appState)

        do {
            try performAll(blocks: [
                manager.migrate2_0_0,
                manager.migrate1_1_0,
            ])
        } catch {
            logError(error)
        }
    }

    private static func logError(_ error: any Error) {
        Logger.migration.error("Migration failed with error: \(error)")
    }
}

// MARK: - Migrate 1.1.0

extension MigrationManager {
    /// Performs all migrations for the `1.1.0` release, catching any thrown
    /// errors and rethrowing them as a combined error.
    private func migrate1_1_0() throws {
        guard !Defaults.bool(forKey: .hasMigrated1_1_0) else {
            return
        }
        try MigrationManager.performAll(blocks: [
            migrateSkeinIcon1_1_0,
        ])
        Defaults.set(true, forKey: .hasMigrated1_1_0)
        Logger.migration.info("Successfully migrated to 1.1.0 settings")
    }

    /// Migrates a saved Skein icon that names the retired ice cube image set
    /// to the snowflake image set that replaced it.
    ///
    /// The retired name is no longer a case of `ControlItemImageSet.Name`, so a
    /// saved icon that uses it can no longer be decoded. Left alone, the decode
    /// failure is only logged and the icon quietly reverts to the default,
    /// discarding a choice the user made. Any other icon that fails to decode is
    /// past repair and would be discarded the same way, so both are rewritten.
    private func migrateSkeinIcon1_1_0() throws {
        guard
            let data = Defaults.data(forKey: .skeinIcon),
            (try? decoder.decode(ControlItemImageSet.self, from: data)) == nil
        else {
            return
        }
        Defaults.set(try encoder.encode(ControlItemImageSet.snowflakeSkeinIcon), forKey: .skeinIcon)
        Logger.migration.info("Replaced an unreadable Skein icon with the snowflake icon")
    }
}

// MARK: - Migrate 2.0.0

extension MigrationManager {
    /// The defaults domain the app used before it was renamed to Skein.
    private static let frostDefaultsDomain = "com.vchun.Frost"

    /// Defaults keys whose stored name embedded the old product name.
    ///
    /// The values are untouched; only the key each one is filed under changes.
    private static let frostRenamedKeys = [
        "ShowFrostIcon": "ShowSkeinIcon",
        "FrostIcon": "SkeinIcon",
        "CustomFrostIconIsTemplate": "CustomSkeinIconIsTemplate",
        "UseFrostBar": "UseSkeinBar",
        "FrostBarLocation": "SkeinBarLocation",
        "FrostBarPinnedLocation": "SkeinBarPinnedLocation",
    ]

    /// The hotkey action identifier that embedded the old product name.
    private static let frostHotkeyAction = (old: "EnableFrostBar", new: "EnableSkeinBar")

    /// Performs all migrations for the `2.0.0` release, catching any thrown
    /// errors and rethrowing them as a combined error.
    private func migrate2_0_0() throws {
        guard !Defaults.bool(forKey: .hasMigrated2_0_0) else {
            return
        }
        try MigrationManager.performAll(blocks: [
            migrateDefaultsDomain2_0_0,
        ])
        Defaults.set(true, forKey: .hasMigrated2_0_0)
        Logger.migration.info("Successfully migrated to 2.0.0 settings")
    }

    /// Imports the settings the app stored while it was named Frost.
    ///
    /// Renaming the app changed its bundle identifier, and macOS files
    /// preferences under that identifier. Without this import every setting,
    /// the menu bar layout, and all hotkeys would silently reset on first
    /// launch, because the new domain simply starts empty.
    ///
    /// Values are copied verbatim under their new key names. A key already
    /// present in the new domain is never overwritten, which makes the import
    /// idempotent and stops it from clobbering anything the user changed after
    /// upgrading. The old domain is left in place so downgrading still works.
    private func migrateDefaultsDomain2_0_0() throws {
        guard
            !Constants.isDevelopmentBuild,
            let frostDefaults = UserDefaults.standard
                .persistentDomain(forName: MigrationManager.frostDefaultsDomain)
        else {
            // A fresh install has nothing to import.
            return
        }

        var imported = 0
        for (key, value) in frostDefaults {
            let newKey = MigrationManager.frostRenamedKeys[key] ?? key
            guard UserDefaults.standard.object(forKey: newKey) == nil else {
                continue
            }
            UserDefaults.standard.set(value, forKey: newKey)
            imported += 1
        }

        migrateHotkeyAction2_0_0()

        Logger.migration.info("Imported \(imported) settings from the Frost defaults domain")
    }

    /// Refiles the saved hotkey whose action identifier embedded the old
    /// product name.
    ///
    /// Hotkeys are stored as a dictionary keyed by `HotkeyAction.rawValue`.
    /// That raw value is persisted data, so renaming the case without moving
    /// the stored entry would drop the user's hotkey on the floor.
    private func migrateHotkeyAction2_0_0() {
        let (old, new) = MigrationManager.frostHotkeyAction
        guard
            var hotkeys = Defaults.dictionary(forKey: .hotkeys) as? [String: Data],
            let data = hotkeys[old]
        else {
            return
        }
        if hotkeys[new] == nil {
            hotkeys[new] = data
        }
        hotkeys[old] = nil
        Defaults.set(hotkeys, forKey: .hotkeys)
        Logger.migration.info("Refiled the saved hotkey from \(old) to \(new)")
    }
}

// MARK: - Helpers

extension MigrationManager {
    /// Performs every block in the given array, catching any thrown
    /// errors and rethrowing them as a combined error.
    private static func performAll(blocks: [() throws -> Void]) throws {
        let results = blocks.map { block in
            Result(catching: block)
        }
        let errors = results.compactMap { result in
            if case .failure(let error) = result {
                return error
            }
            return nil
        }
        if !errors.isEmpty {
            throw MigrationError.combinedError(errors)
        }
    }
}

// MARK: - Errors

extension MigrationManager {
    enum MigrationError: Error, CustomStringConvertible {
        case combinedError([any Error])

        var description: String {
            switch self {
            case .combinedError(let errors):
                "The following errors occurred: \(errors)"
            }
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let migration = Logger(category: "Migration")
}
