import Foundation

enum AppBackupService {
    private enum DefaultsKey {
        static let appAppearance = "ui.appAppearance"
        static let comicBrowseMode = "ui.comicBrowseMode"
        static let debugLogsEnabled = RuntimeDebugConsole.enabledKey
        static let favoritesSelectedSourceKey = "favorites.selectedSourceKey"
        static let readerMode = "reader_mode"
        static let readerInvertTapZones = "reader_invert_tap_zones"
        static let readerPreloadDistance = "reader_preload_distance"
        static let readerTapZones = "Reader.tapZones"
        static let readerAnimatePageTransitions = "Reader.animatePageTransitions"
        static let readerBackgroundColor = "Reader.backgroundColor"
        static let readerKeepScreenOn = "Reader.keepScreenOn"
        static let sourceIndexURL = "source.runtime.index.url"
        static let selectedSourceKey = "source.runtime.selected.source.key"
        static let autoLoadRemoteSources = "source.runtime.remote.autoload"
        static let cookieFormValues = "source.runtime.cookieFormValues"
        static let sourceStorePrefix = "source.runtime.store."
    }

    static func makePayload(
        favorites: [FavoriteComic],
        categories: [LibraryCategory],
        categoryMemberships: [Int64: Set<String>],
        history: [ReadingHistoryItem]
    ) -> AppBackupPayload {
        let defaults = UserDefaults.standard
        let sourceSettings = defaults.dictionaryRepresentation()
            .filter { $0.key.hasPrefix(DefaultsKey.sourceStorePrefix) }
            .compactMapValues(BackupJSONValue.init(propertyListValue:))

        let preferences = AppPreferencesBackup(
            appAppearance: defaults.string(forKey: DefaultsKey.appAppearance),
            comicBrowseMode: defaults.string(forKey: DefaultsKey.comicBrowseMode),
            debugLogsEnabled: defaults.object(forKey: DefaultsKey.debugLogsEnabled) as? Bool,
            favoritesSelectedSourceKey: defaults.string(forKey: DefaultsKey.favoritesSelectedSourceKey),
            readerMode: defaults.string(forKey: DefaultsKey.readerMode),
            readerInvertTapZones: defaults.object(forKey: DefaultsKey.readerInvertTapZones) as? Bool,
            readerPreloadDistance: defaults.object(forKey: DefaultsKey.readerPreloadDistance) as? Int,
            readerTapZones: defaults.string(forKey: DefaultsKey.readerTapZones),
            readerAnimatePageTransitions: defaults.object(forKey: DefaultsKey.readerAnimatePageTransitions) as? Bool,
            readerBackgroundColor: defaults.string(forKey: DefaultsKey.readerBackgroundColor),
            readerKeepScreenOn: defaults.object(forKey: DefaultsKey.readerKeepScreenOn) as? Bool
        )

        let sourceRuntime = SourceRuntimeBackupData(
            indexURL: defaults.string(forKey: DefaultsKey.sourceIndexURL),
            selectedSourceKey: defaults.string(forKey: DefaultsKey.selectedSourceKey),
            autoLoadRemoteSources: defaults.object(forKey: DefaultsKey.autoLoadRemoteSources) as? Bool,
            cookieFormValues: defaults.dictionary(forKey: DefaultsKey.cookieFormValues) as? [String: [String: String]] ?? [:],
            sourceSettings: sourceSettings
        )

        return AppBackupPayload(
            schemaVersion: AppBackupPayload.currentSchemaVersion,
            exportedAt: Date(),
            library: LibraryBackupData(
                favorites: favorites,
                categories: categories,
                categoryMemberships: categoryMemberships.mapKeys { String($0) }.mapValues { Array($0).sorted() },
                history: history
            ),
            preferences: preferences,
            sourceRuntime: sourceRuntime
        )
    }

    static func writePayload(_ payload: AppBackupPayload) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let backupsDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let fileName = snapshotFileName(for: payload)
        let url = backupsDirectory.appendingPathComponent(fileName, isDirectory: false)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encodePayload(payload)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func snapshotFileName(for payload: AppBackupPayload) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: payload.exportedAt).replacingOccurrences(of: ":", with: "-")
        return "comicdeck-backup-\(timestamp).json"
    }

    static func readPayload(from url: URL) throws -> AppBackupPayload {
        let data = try Data(contentsOf: url)
        return try decodePayload(data: data)
    }

    static func encodePayload(_ payload: AppBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func decodePayload(data: Data) throws -> AppBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(AppBackupPayload.self, from: data)
        guard payload.schemaVersion == AppBackupPayload.currentSchemaVersion else {
            throw BackupServiceError.unsupportedSchema(payload.schemaVersion)
        }
        return payload
    }

    static func applyPreferences(_ preferences: AppPreferencesBackup) {
        let defaults = UserDefaults.standard

        set(preferences.appAppearance, forKey: DefaultsKey.appAppearance, in: defaults)
        set(preferences.comicBrowseMode, forKey: DefaultsKey.comicBrowseMode, in: defaults)
        set(preferences.debugLogsEnabled, forKey: DefaultsKey.debugLogsEnabled, in: defaults)
        set(preferences.favoritesSelectedSourceKey, forKey: DefaultsKey.favoritesSelectedSourceKey, in: defaults)
        set(preferences.readerMode, forKey: DefaultsKey.readerMode, in: defaults)
        set(preferences.readerInvertTapZones, forKey: DefaultsKey.readerInvertTapZones, in: defaults)
        set(preferences.readerPreloadDistance, forKey: DefaultsKey.readerPreloadDistance, in: defaults)
        set(preferences.readerTapZones, forKey: DefaultsKey.readerTapZones, in: defaults)
        set(preferences.readerAnimatePageTransitions, forKey: DefaultsKey.readerAnimatePageTransitions, in: defaults)
        set(preferences.readerBackgroundColor, forKey: DefaultsKey.readerBackgroundColor, in: defaults)
        set(preferences.readerKeepScreenOn, forKey: DefaultsKey.readerKeepScreenOn, in: defaults)
    }

    static func applySourceRuntime(_ sourceRuntime: SourceRuntimeBackupData, to sourceManager: SourceManagerViewModel) {
        let defaults = UserDefaults.standard
        set(sourceRuntime.indexURL, forKey: DefaultsKey.sourceIndexURL, in: defaults)
        set(sourceRuntime.selectedSourceKey, forKey: DefaultsKey.selectedSourceKey, in: defaults)
        set(sourceRuntime.autoLoadRemoteSources, forKey: DefaultsKey.autoLoadRemoteSources, in: defaults)
        defaults.set(sourceRuntime.cookieFormValues, forKey: DefaultsKey.cookieFormValues)

        for (key, value) in sourceRuntime.sourceSettings {
            defaults.set(value.propertyListValue, forKey: key)
        }

        if let indexURL = sourceRuntime.indexURL {
            sourceManager.indexURL = indexURL
        }
        if let autoLoadRemoteSources = sourceRuntime.autoLoadRemoteSources {
            sourceManager.autoLoadRemoteSources = autoLoadRemoteSources
        }
        if let selectedSourceKey = sourceRuntime.selectedSourceKey {
            sourceManager.selectedSourceKey = selectedSourceKey
        }
    }

    private static func set(_ value: String?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        }
    }

    private static func set(_ value: Bool?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        }
    }

    private static func set(_ value: Int?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        }
    }
}

private extension Dictionary {
    func mapKeys<T: Hashable>(_ transform: (Key) -> T) -> [T: Value] {
        Dictionary<T, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

enum BackupServiceError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported backup schema version \(version)"
        }
    }
}
