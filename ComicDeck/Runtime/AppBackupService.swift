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
        static let readerTapTurnMargin = "Reader.tapTurnMargin"
        static let readerAnimatePageTransitions = "Reader.animatePageTransitions"
        static let readerBackgroundColor = "Reader.backgroundColor"
        static let readerKeepScreenOn = "Reader.keepScreenOn"
        static let sourceIndexURL = "source.runtime.index.url"
        static let selectedSourceKey = "source.runtime.selected.source.key"
        static let autoLoadRemoteSources = "source.runtime.remote.autoload"
        static let cookieFormValues = "source.runtime.cookieFormValues"
        static let sourceAuthProfiles = "source.runtime.authProfiles"
        static let sourceActiveAuthProfiles = "source.runtime.activeAuthProfiles"
        static let sourceStorePrefix = "source.runtime.store."
        static let trackerTokenService = "boa.ComicDeck.Tracker"
        static let trackerAutomaticSyncEnabled = "tracking.sync.automatic.enabled"
        static let trackerAutomaticSyncDirection = "tracking.sync.automatic.direction"
        static let trackerManualSyncDefaultDirection = "tracking.sync.manual.defaultDirection"

        static func trackerAutomaticProviderSyncEnabled(_ provider: TrackerProvider) -> String {
            "tracking.sync.automatic.provider.\(provider.rawValue).enabled"
        }
    }

    static func makePayload(
        favorites: [FavoriteComic],
        categories: [LibraryCategory],
        categoryMemberships: [Int64: Set<String>],
        history: [ReadingHistoryItem],
        trackerAccounts: [TrackerAccount] = [],
        trackerBindings: [TrackerBinding] = []
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
            readerTapTurnMargin: defaults.object(forKey: DefaultsKey.readerTapTurnMargin) as? Double,
            readerAnimatePageTransitions: defaults.object(forKey: DefaultsKey.readerAnimatePageTransitions) as? Bool,
            readerBackgroundColor: defaults.string(forKey: DefaultsKey.readerBackgroundColor),
            readerKeepScreenOn: defaults.object(forKey: DefaultsKey.readerKeepScreenOn) as? Bool
        )

        let sourceRuntime = SourceRuntimeBackupData(
            indexURL: defaults.string(forKey: DefaultsKey.sourceIndexURL),
            selectedSourceKey: defaults.string(forKey: DefaultsKey.selectedSourceKey),
            autoLoadRemoteSources: defaults.object(forKey: DefaultsKey.autoLoadRemoteSources) as? Bool,
            cookieFormValues: defaults.dictionary(forKey: DefaultsKey.cookieFormValues) as? [String: [String: String]] ?? [:],
            authProfiles: defaults.data(forKey: DefaultsKey.sourceAuthProfiles).flatMap { data in
                BackupJSONValue.string(data.base64EncodedString())
            },
            activeAuthProfiles: defaults.dictionary(forKey: DefaultsKey.sourceActiveAuthProfiles) as? [String: String] ?? [:],
            sourceSettings: sourceSettings
        )
        let tracker = makeTrackerBackupData(accounts: trackerAccounts, bindings: trackerBindings, defaults: defaults)

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
            sourceRuntime: sourceRuntime,
            tracker: tracker
        )
    }

    nonisolated static func writePayload(_ payload: AppBackupPayload) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let backupsDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let fileName = snapshotFileName(for: payload)
        let url = backupsDirectory.appendingPathComponent(fileName, isDirectory: false)

        let data = try encodePayload(payload)
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated static func snapshotFileName(for payload: AppBackupPayload) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: payload.exportedAt).replacingOccurrences(of: ":", with: "-")
        return "comicdeck-backup-\(timestamp).json"
    }

    nonisolated static func readPayload(from url: URL) throws -> AppBackupPayload {
        let data = try Data(contentsOf: url)
        return try decodePayload(data: data)
    }

    nonisolated static func encodePayload(_ payload: AppBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    nonisolated static func decodePayload(data: Data) throws -> AppBackupPayload {
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
        set(preferences.readerTapTurnMargin, forKey: DefaultsKey.readerTapTurnMargin, in: defaults)
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
        if case let .string(encoded)? = sourceRuntime.authProfiles,
           let data = Data(base64Encoded: encoded) {
            defaults.set(data, forKey: DefaultsKey.sourceAuthProfiles)
        }
        defaults.set(sourceRuntime.activeAuthProfiles, forKey: DefaultsKey.sourceActiveAuthProfiles)

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

    static func applyTracker(_ tracker: TrackerBackupData?, to database: SQLiteStore) async throws {
        guard let tracker else { return }

        try await database.clearTrackerSyncEvents()
        for binding in try await database.listTrackerBindings() {
            try await database.deleteTrackerBinding(provider: binding.provider, sourceKey: binding.sourceKey, comicID: binding.comicID)
        }
        for account in try await database.listTrackerAccounts() {
            try await database.deleteTrackerAccount(provider: account.provider)
        }

        for account in tracker.accounts {
            try await database.upsertTrackerAccount(account)
        }
        for binding in tracker.bindings {
            _ = try await database.upsertTrackerBinding(
                provider: binding.provider,
                sourceKey: binding.sourceKey,
                comicID: binding.comicID,
                remoteMediaID: binding.remoteMediaID,
                remoteTitle: binding.remoteTitle,
                remoteCoverURL: binding.remoteCoverURL,
                sourceTitle: binding.sourceTitle,
                sourceCoverURL: binding.sourceCoverURL,
                lastSyncedProgress: binding.lastSyncedProgress,
                lastSyncedStatus: binding.lastSyncedStatus
            )
        }
        applyTrackerSyncPreferences(tracker.syncPreferences)

        let credentialsByProvider = Dictionary(uniqueKeysWithValues: tracker.credentials.map { ($0.provider, $0.accessToken) })
        for provider in TrackerProvider.allCases {
            try SecureStore.save(
                credentialsByProvider[provider] ?? "",
                service: DefaultsKey.trackerTokenService,
                account: trackerTokenAccount(for: provider)
            )
        }
    }

    private static func makeTrackerBackupData(
        accounts: [TrackerAccount],
        bindings: [TrackerBinding],
        defaults: UserDefaults
    ) -> TrackerBackupData {
        TrackerBackupData(
            accounts: accounts.sorted { $0.provider.rawValue < $1.provider.rawValue },
            bindings: bindings.map(TrackerBindingBackupData.init(binding:)).sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
                if lhs.sourceKey != rhs.sourceKey { return lhs.sourceKey.localizedStandardCompare(rhs.sourceKey) == .orderedAscending }
                return lhs.comicID.localizedStandardCompare(rhs.comicID) == .orderedAscending
            },
            syncPreferences: trackerSyncPreferences(defaults: defaults),
            credentials: trackerCredentials()
        )
    }

    private static func trackerSyncPreferences(defaults: UserDefaults) -> TrackerSyncPreferencesBackupData {
        TrackerSyncPreferencesBackupData(
            automaticSyncEnabled: defaults.object(forKey: DefaultsKey.trackerAutomaticSyncEnabled) as? Bool ?? true,
            automaticSyncDirection: TrackerSyncDirection(rawValue: defaults.string(forKey: DefaultsKey.trackerAutomaticSyncDirection) ?? "") ?? .localToRemote,
            manualSyncDefaultDirection: TrackerSyncDirection(rawValue: defaults.string(forKey: DefaultsKey.trackerManualSyncDefaultDirection) ?? "") ?? .localToRemote,
            automaticProviderSyncEnabled: Dictionary(uniqueKeysWithValues: TrackerProvider.allCases.map { provider in
                let key = DefaultsKey.trackerAutomaticProviderSyncEnabled(provider)
                let enabled = defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
                return (provider.rawValue, enabled)
            })
        )
    }

    private static func applyTrackerSyncPreferences(_ preferences: TrackerSyncPreferencesBackupData) {
        let defaults = UserDefaults.standard
        set(preferences.automaticSyncEnabled, forKey: DefaultsKey.trackerAutomaticSyncEnabled, in: defaults)
        set(preferences.automaticSyncDirection?.rawValue, forKey: DefaultsKey.trackerAutomaticSyncDirection, in: defaults)
        set(preferences.manualSyncDefaultDirection?.rawValue, forKey: DefaultsKey.trackerManualSyncDefaultDirection, in: defaults)
        for (providerRawValue, enabled) in preferences.automaticProviderSyncEnabled {
            guard let provider = TrackerProvider(rawValue: providerRawValue) else { continue }
            defaults.set(enabled, forKey: DefaultsKey.trackerAutomaticProviderSyncEnabled(provider))
        }
    }

    private static func trackerCredentials() -> [TrackerCredentialBackupData] {
        TrackerProvider.allCases.compactMap { provider in
            let token = try? SecureStore.read(
                service: DefaultsKey.trackerTokenService,
                account: trackerTokenAccount(for: provider)
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let token, !token.isEmpty else { return nil }
            return TrackerCredentialBackupData(provider: provider, accessToken: token)
        }
    }

    private static func trackerTokenAccount(for provider: TrackerProvider) -> String {
        "token.\(provider.rawValue)"
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

    private static func set(_ value: Double?, forKey key: String, in defaults: UserDefaults) {
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

private extension TrackerBindingBackupData {
    init(binding: TrackerBinding) {
        self.init(
            provider: binding.provider,
            sourceKey: binding.sourceKey,
            comicID: binding.comicID,
            remoteMediaID: binding.remoteMediaID,
            remoteTitle: binding.remoteTitle,
            remoteCoverURL: binding.remoteCoverURL,
            sourceTitle: binding.sourceTitle,
            sourceCoverURL: binding.sourceCoverURL,
            lastSyncedProgress: binding.lastSyncedProgress,
            lastSyncedStatus: binding.lastSyncedStatus
        )
    }
}

nonisolated enum BackupServiceError: LocalizedError, Sendable {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "Unsupported backup schema version \(version)"
        }
    }
}
