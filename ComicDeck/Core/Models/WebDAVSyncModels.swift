import Foundation

struct WebDAVRemoteBackup: Hashable, Identifiable {
    let name: String
    let url: URL
    let modifiedAt: Date?
    let sizeBytes: Int64?

    var id: URL { url }
}
