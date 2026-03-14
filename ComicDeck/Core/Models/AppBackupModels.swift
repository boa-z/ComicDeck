import Foundation

struct AppBackupPayload: Codable, Hashable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let exportedAt: Date
    let library: LibraryBackupData
    let preferences: AppPreferencesBackup
    let sourceRuntime: SourceRuntimeBackupData
}

struct LibraryBackupData: Codable, Hashable {
    let favorites: [FavoriteComic]
    let categories: [LibraryCategory]
    let categoryMemberships: [String: [String]]
    let history: [ReadingHistoryItem]
}

struct AppPreferencesBackup: Codable, Hashable {
    let appAppearance: String?
    let comicBrowseMode: String?
    let debugLogsEnabled: Bool?
    let favoritesSelectedSourceKey: String?
    let readerMode: String?
    let readerInvertTapZones: Bool?
    let readerPreloadDistance: Int?
    let readerTapZones: String?
    let readerAnimatePageTransitions: Bool?
    let readerBackgroundColor: String?
    let readerKeepScreenOn: Bool?
}

struct SourceRuntimeBackupData: Codable, Hashable {
    let indexURL: String?
    let selectedSourceKey: String?
    let autoLoadRemoteSources: Bool?
    let cookieFormValues: [String: [String: String]]
    let sourceSettings: [String: BackupJSONValue]
}

enum BackupJSONValue: Codable, Hashable {
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
