import Foundation

struct SourceConfigIndexItem: Codable, Identifiable, Hashable {
    let name: String
    let key: String?
    let version: String?
    let description: String?
    let url: String?
    let fileName: String?
    let filename: String?

    nonisolated var id: String {
        key ?? name
    }

    nonisolated var resolvedFileName: String? {
        fileName ?? filename
    }
}

struct InstalledSource: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let key: String
    let version: String
    let scriptFileName: String
    let originalURL: String
    let installedAt: Int64
}

struct SourceScriptMetadata: Codable, Hashable {
    let className: String
    let name: String
    let key: String
    let version: String
    let url: String?
}
