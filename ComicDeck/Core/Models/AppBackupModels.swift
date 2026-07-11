import Foundation

nonisolated struct AppBackupPayload: Codable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAt: Date
    let library: LibraryBackupData
    let preferences: AppPreferencesBackup
    let sourceRuntime: SourceRuntimeBackupData
    let tracker: TrackerBackupData?
}

nonisolated struct LibraryBackupData: Codable, Sendable {
    let favorites: [FavoriteComic]
    let categories: [LibraryCategory]
    let categoryMemberships: [String: [String]]
    let history: [ReadingHistoryItem]
}

nonisolated struct AppPreferencesBackup: Codable, Sendable {
    let appAppearance: String?
    let comicBrowseMode: String?
    let debugLogsEnabled: Bool?
    let favoritesSelectedSourceKey: String?
    let readerMode: String?
    let readerInvertTapZones: Bool?
    let readerPreloadDistance: Int?
    let readerTapZones: String?
    let readerTapTurnMargin: Double?
    let readerAnimatePageTransitions: Bool?
    let readerBackgroundColor: String?
    let readerKeepScreenOn: Bool?
}

nonisolated struct SourceRuntimeBackupData: Codable, Sendable {
    let indexURL: String?
    let selectedSourceKey: String?
    let autoLoadRemoteSources: Bool?
    let cookieFormValues: [String: [String: String]]
    let authProfiles: BackupJSONValue?
    let activeAuthProfiles: [String: String]
    let sourceSettings: [String: BackupJSONValue]

    init(
        indexURL: String?,
        selectedSourceKey: String?,
        autoLoadRemoteSources: Bool?,
        cookieFormValues: [String: [String: String]],
        authProfiles: BackupJSONValue?,
        activeAuthProfiles: [String: String],
        sourceSettings: [String: BackupJSONValue]
    ) {
        self.indexURL = indexURL
        self.selectedSourceKey = selectedSourceKey
        self.autoLoadRemoteSources = autoLoadRemoteSources
        self.cookieFormValues = cookieFormValues
        self.authProfiles = authProfiles
        self.activeAuthProfiles = activeAuthProfiles
        self.sourceSettings = sourceSettings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        indexURL = try container.decodeIfPresent(String.self, forKey: .indexURL)
        selectedSourceKey = try container.decodeIfPresent(String.self, forKey: .selectedSourceKey)
        autoLoadRemoteSources = try container.decodeIfPresent(Bool.self, forKey: .autoLoadRemoteSources)
        cookieFormValues = try container.decodeIfPresent([String: [String: String]].self, forKey: .cookieFormValues) ?? [:]
        authProfiles = try container.decodeIfPresent(BackupJSONValue.self, forKey: .authProfiles)
        activeAuthProfiles = try container.decodeIfPresent([String: String].self, forKey: .activeAuthProfiles) ?? [:]
        sourceSettings = try container.decodeIfPresent([String: BackupJSONValue].self, forKey: .sourceSettings) ?? [:]
    }
}

nonisolated struct TrackerBackupData: Codable, Sendable {
    let accounts: [TrackerAccount]
    let bindings: [TrackerBindingBackupData]
    let syncPreferences: TrackerSyncPreferencesBackupData
    let credentials: [TrackerCredentialBackupData]
}

nonisolated struct TrackerBindingBackupData: Codable, Sendable {
    let provider: TrackerProvider
    let sourceKey: String
    let comicID: String
    let remoteMediaID: String
    let remoteTitle: String
    let remoteCoverURL: String?
    let sourceTitle: String?
    let sourceCoverURL: String?
    let lastSyncedProgress: Int
    let lastSyncedStatus: TrackerReadingStatus?
}

nonisolated struct TrackerSyncPreferencesBackupData: Codable, Sendable {
    let automaticSyncEnabled: Bool?
    let automaticSyncDirection: TrackerSyncDirection?
    let manualSyncDefaultDirection: TrackerSyncDirection?
    let automaticProviderSyncEnabled: [String: Bool]
}

nonisolated struct TrackerCredentialBackupData: Codable, Sendable {
    let provider: TrackerProvider
    let accessToken: String
}

nonisolated enum BackupJSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([BackupJSONValue])
    case object([String: BackupJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: BackupJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([BackupJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported backup JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    nonisolated init?(propertyListValue: Any) {
        switch propertyListValue {
        case let value as String:
            self = .string(value)
        case let value as Bool:
            self = .bool(value)
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as [Any]:
            self = .array(value.compactMap(Self.init(propertyListValue:)))
        case let value as [String: Any]:
            var object: [String: BackupJSONValue] = [:]
            for (key, child) in value {
                object[key] = Self(propertyListValue: child) ?? .null
            }
            self = .object(object)
        default:
            return nil
        }
    }

    nonisolated var propertyListValue: Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .bool(value):
            return value
        case let .array(values):
            return values.map(\.propertyListValue)
        case let .object(values):
            return values.mapValues(\.propertyListValue)
        case .null:
            return NSNull()
        }
    }
}
