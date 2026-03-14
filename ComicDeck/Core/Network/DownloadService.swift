import Foundation

public actor DownloadService {
    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .default) {
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        self.session = URLSession(configuration: configuration)
    }

    @discardableResult
    public func downloadFile(from remoteURL: URL, to localURL: URL) async throws -> URL {
        let (tempURL, response) = try await session.download(from: remoteURL)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else {
            throw URLError(.badServerResponse)
        }

        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }

        try FileManager.default.moveItem(at: tempURL, to: localURL)
        return localURL
    }

    public func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
