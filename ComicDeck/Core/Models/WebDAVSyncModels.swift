import Foundation

struct WebDAVRemoteBackup: Hashable, Identifiable {
    let name: String
    let url: URL
    let modifiedAt: Date?
    let sizeBytes: Int64?

    var id: URL { url }

    var subtitle: String {
        var parts: [String] = []
        if let modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        if let sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        return parts.isEmpty ? "Unknown metadata" : parts.joined(separator: " · ")
    }
}
