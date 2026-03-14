import Foundation

struct WebDAVSyncConfiguration: Hashable {
    var directoryURLString: String
    var username: String
    var password: String
    var remoteFileName: String

    var directoryURL: URL? {
        URL(string: directoryURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var remoteFileURL: URL? {
        guard let directoryURL else { return nil }
        return directoryURL.appendingPathComponent(remoteFileName)
    }
}

enum WebDAVSyncError: LocalizedError {
    case invalidDirectoryURL
    case invalidRemoteFileName
    case missingCredentials
    case unexpectedStatus(Int)
    case invalidResponse
    case noRemoteBackups

    var errorDescription: String? {
        switch self {
        case .invalidDirectoryURL:
            return "Invalid WebDAV directory URL"
        case .invalidRemoteFileName:
            return "Invalid remote backup file name"
        case .missingCredentials:
            return "WebDAV username and password are required"
        case let .unexpectedStatus(code):
            return "WebDAV request failed with status \(code)"
        case .invalidResponse:
            return "Invalid WebDAV response"
        case .noRemoteBackups:
            return "No remote backups found"
        }
    }
}

final class WebDAVSyncService {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        self.session = URLSession(configuration: configuration)
    }

    func testConnection(_ configuration: WebDAVSyncConfiguration) async throws {
        let request = try makeRequest(
            method: "PROPFIND",
            url: validatedDirectoryURL(configuration),
            configuration: configuration,
            body: """
            <?xml version="1.0" encoding="utf-8" ?>
            <d:propfind xmlns:d="DAV:">
              <d:prop><d:displayname/></d:prop>
            </d:propfind>
            """.data(using: .utf8),
            contentType: "application/xml; charset=utf-8"
        ) {
            $0.setValue("0", forHTTPHeaderField: "Depth")
        }

        _ = try await send(request, acceptableStatusCodes: [200, 207, 301, 302])
    }

    func uploadBackup(_ payload: AppBackupPayload, configuration: WebDAVSyncConfiguration) async throws {
        try await ensureDirectoryExists(configuration)
        let remoteFileURL = try validatedRemoteFileURL(configuration)
        let data = try AppBackupService.encodePayload(payload)
        try await uploadData(data, to: remoteFileURL, configuration: configuration)
    }

    func uploadSnapshotBackup(_ payload: AppBackupPayload, configuration: WebDAVSyncConfiguration) async throws -> WebDAVRemoteBackup {
        try await ensureDirectoryExists(configuration)
        let fileName = AppBackupService.snapshotFileName(for: payload)
        guard let directoryURL = configuration.directoryURL else {
            throw WebDAVSyncError.invalidDirectoryURL
        }
        let remoteURL = directoryURL.appendingPathComponent(fileName)
        let data = try AppBackupService.encodePayload(payload)
        try await uploadData(data, to: remoteURL, configuration: configuration)
        return WebDAVRemoteBackup(
            name: fileName,
            url: remoteURL,
            modifiedAt: payload.exportedAt,
            sizeBytes: Int64(data.count)
        )
    }

    func downloadBackup(configuration: WebDAVSyncConfiguration) async throws -> AppBackupPayload {
        try await downloadBackup(
            from: try validatedRemoteFileURL(configuration),
            configuration: configuration
        )
    }

    func downloadBackup(from remoteURL: URL, configuration: WebDAVSyncConfiguration) async throws -> AppBackupPayload {
        let request = try makeRequest(
            method: "GET",
            url: remoteURL,
            configuration: configuration,
            body: nil,
            contentType: nil
        )

        let data = try await send(request, acceptableStatusCodes: [200])
        return try AppBackupService.decodePayload(data: data)
    }

    func listBackups(configuration: WebDAVSyncConfiguration) async throws -> [WebDAVRemoteBackup] {
        let directoryURL = try validatedDirectoryURL(configuration)
        let request = try makeRequest(
            method: "PROPFIND",
            url: directoryURL,
            configuration: configuration,
            body: """
            <?xml version="1.0" encoding="utf-8" ?>
            <d:propfind xmlns:d="DAV:">
              <d:prop>
                <d:displayname/>
                <d:getcontentlength/>
                <d:getlastmodified/>
                <d:resourcetype/>
              </d:prop>
            </d:propfind>
            """.data(using: .utf8),
            contentType: "application/xml; charset=utf-8"
        ) {
            $0.setValue("1", forHTTPHeaderField: "Depth")
        }

        let data = try await send(request, acceptableStatusCodes: [200, 207])
        return try WebDAVPROPFINDParser.parse(data: data, baseDirectoryURL: directoryURL)
            .filter { $0.name.lowercased().hasSuffix(".json") }
            .sorted {
                switch ($0.modifiedAt, $1.modifiedAt) {
                case let (lhs?, rhs?):
                    return lhs > rhs
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
    }

    func downloadLatestBackup(configuration: WebDAVSyncConfiguration) async throws -> AppBackupPayload {
        let backups = try await listBackups(configuration: configuration)
        guard let latest = backups.first else {
            throw WebDAVSyncError.noRemoteBackups
        }
        return try await downloadBackup(from: latest.url, configuration: configuration)
    }

    func deleteBackup(_ backup: WebDAVRemoteBackup, configuration: WebDAVSyncConfiguration) async throws {
        let request = try makeRequest(
            method: "DELETE",
            url: backup.url,
            configuration: configuration,
            body: nil,
            contentType: nil
        )
        _ = try await send(request, acceptableStatusCodes: [200, 202, 204])
    }

    private func validatedDirectoryURL(_ configuration: WebDAVSyncConfiguration) throws -> URL {
        guard let url = configuration.directoryURL else {
            throw WebDAVSyncError.invalidDirectoryURL
        }
        return url
    }

    private func validatedRemoteFileURL(_ configuration: WebDAVSyncConfiguration) throws -> URL {
        guard !configuration.remoteFileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebDAVSyncError.invalidRemoteFileName
        }
        guard let url = configuration.remoteFileURL else {
            throw WebDAVSyncError.invalidDirectoryURL
        }
        return url
    }

    private func ensureDirectoryExists(_ configuration: WebDAVSyncConfiguration) async throws {
        let url = try validatedDirectoryURL(configuration)
        var mkcolRequest = try makeRequest(
            method: "MKCOL",
            url: url,
            configuration: configuration,
            body: nil,
            contentType: nil
        )
        mkcolRequest.timeoutInterval = 30
        do {
            _ = try await send(mkcolRequest, acceptableStatusCodes: [201, 301, 405])
        } catch WebDAVSyncError.unexpectedStatus(let code) where code == 409 {
            throw WebDAVSyncError.invalidDirectoryURL
        } catch {
            throw error
        }
    }

    private func uploadData(_ data: Data, to remoteURL: URL, configuration: WebDAVSyncConfiguration) async throws {
        let request = try makeRequest(
            method: "PUT",
            url: remoteURL,
            configuration: configuration,
            body: data,
            contentType: "application/json"
        )
        _ = try await send(request, acceptableStatusCodes: [200, 201, 204])
    }

    private func makeRequest(
        method: String,
        url: URL,
        configuration: WebDAVSyncConfiguration,
        body: Data?,
        contentType: String?,
        mutate: ((inout URLRequest) -> Void)? = nil
    ) throws -> URLRequest {
        guard !configuration.username.isEmpty, !configuration.password.isEmpty else {
            throw WebDAVSyncError.missingCredentials
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Basic \(basicAuth(configuration.username, configuration.password))", forHTTPHeaderField: "Authorization")
        mutate?(&request)
        return request
    }

    private func send(_ request: URLRequest, acceptableStatusCodes: Set<Int>) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebDAVSyncError.invalidResponse
        }
        guard acceptableStatusCodes.contains(httpResponse.statusCode) else {
            throw WebDAVSyncError.unexpectedStatus(httpResponse.statusCode)
        }
        return data
    }

    private func basicAuth(_ username: String, _ password: String) -> String {
        Data("\(username):\(password)".utf8).base64EncodedString()
    }
}

private enum WebDAVPROPFINDParser {
    static func parse(data: Data, baseDirectoryURL: URL) throws -> [WebDAVRemoteBackup] {
        let delegate = WebDAVPROPFINDDelegate(baseDirectoryURL: baseDirectoryURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw parser.parserError ?? WebDAVSyncError.invalidResponse
        }
        return delegate.entries
    }
}

private final class WebDAVPROPFINDDelegate: NSObject, XMLParserDelegate {
    private struct EntryBuilder {
        var href = ""
        var displayName = ""
        var contentLength = ""
        var lastModified = ""
        var isCollection = false
    }

    private let baseDirectoryURL: URL
    private let httpDateFormatter: DateFormatter
    private var currentElement = ""
    private var currentValue = ""
    private var currentEntry: EntryBuilder?
    private(set) var entries: [WebDAVRemoteBackup] = []

    init(baseDirectoryURL: URL) {
        self.baseDirectoryURL = baseDirectoryURL
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        self.httpDateFormatter = formatter
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let normalizedName = qName ?? elementName
        currentElement = normalizedName
        currentValue = ""
        if normalizedName.hasSuffix("response") {
            currentEntry = EntryBuilder()
        } else if normalizedName.hasSuffix("collection") {
            currentEntry?.isCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let normalizedName = qName ?? elementName
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch normalizedName {
        case let name where name.hasSuffix("href"):
            currentEntry?.href = value
        case let name where name.hasSuffix("displayname"):
            currentEntry?.displayName = value
        case let name where name.hasSuffix("getcontentlength"):
            currentEntry?.contentLength = value
        case let name where name.hasSuffix("getlastmodified"):
            currentEntry?.lastModified = value
        case let name where name.hasSuffix("response"):
            finishCurrentEntry()
        default:
            break
        }

        currentElement = ""
        currentValue = ""
    }

    private func finishCurrentEntry() {
        guard let entry = currentEntry else { return }
        defer { currentEntry = nil }
        guard !entry.isCollection, !entry.href.isEmpty else { return }

        let resolvedURL: URL
        if let url = URL(string: entry.href, relativeTo: baseDirectoryURL)?.absoluteURL {
            resolvedURL = url
        } else {
            return
        }

        let normalizedDirectory = baseDirectoryURL.absoluteString.hasSuffix("/")
            ? baseDirectoryURL.absoluteString
            : baseDirectoryURL.absoluteString + "/"
        let normalizedResolved = resolvedURL.absoluteString
        guard normalizedResolved != normalizedDirectory else { return }

        let name = entry.displayName.isEmpty
            ? resolvedURL.lastPathComponent.removingPercentEncoding ?? resolvedURL.lastPathComponent
            : entry.displayName

        let backup = WebDAVRemoteBackup(
            name: name,
            url: resolvedURL,
            modifiedAt: httpDateFormatter.date(from: entry.lastModified),
            sizeBytes: Int64(entry.contentLength)
        )
        entries.append(backup)
    }
}
