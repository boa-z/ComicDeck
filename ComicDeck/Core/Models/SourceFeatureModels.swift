import Foundation

struct SourceCapabilityProfile: Hashable {
    let hasExplore: Bool
    let hasCategory: Bool
    let hasSearch: Bool
    let hasFavorites: Bool
    let hasComments: Bool
    let hasAccountLogin: Bool
    let hasWebLogin: Bool
    let hasCookieLogin: Bool
    let hasSettings: Bool
    let searchOptionGroupCount: Int
    let settingCount: Int
    let availableSearchMethods: [String]

    static let empty = SourceCapabilityProfile(
        hasExplore: false,
        hasCategory: false,
        hasSearch: false,
        hasFavorites: false,
        hasComments: false,
        hasAccountLogin: false,
        hasWebLogin: false,
        hasCookieLogin: false,
        hasSettings: false,
        searchOptionGroupCount: 0,
        settingCount: 0,
        availableSearchMethods: []
    )
}

struct SourceSettingOption: Identifiable, Hashable {
    let id: String
    let value: String
    let label: String
}

struct SourceSettingDefinition: Identifiable, Hashable {
    let id: String
    let key: String
    let title: String
    let type: String
    let defaultValue: String?
    let currentStringValue: String
    let currentBoolValue: Bool
    let options: [SourceSettingOption]
}
