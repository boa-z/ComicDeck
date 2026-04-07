import Foundation

enum SourceConfigServiceError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Network response is invalid"
        case .invalidPayload:
            return "Response payload is invalid"
        }
    }
}

actor SourceConfigService {
    private let session: URLSession
    private let indexCache: HybridDataCache

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = URLSession(configuration: config)
        self.indexCache = HybridDataCache(
            directoryName: "SourceIndexCache",
            policy: DataCachePolicy(
                memoryTTL: 10 * 60,
                diskTTL: 60 * 60,
                maxMemoryItems: 4,
                maxMemoryBytes: 2 * 1024 * 1024,
                maxDiskBytes: 8 * 1024 * 1024
            )
        )
    }

    func fetchIndex(from indexURL: String, forceRefresh: Bool = false) async throws -> [SourceConfigIndexItem] {
        guard let url = URL(string: indexURL) else {
            throw SourceConfigServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let cacheKey = RequestCacheKeyBuilder.key(for: request)

        if !forceRefresh, let hit = await indexCache.lookupData(forKey: cacheKey) {
            return try decodeIndex(from: hit.data)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw SourceConfigServiceError.invalidResponse
        }
        let decoded = try decodeIndex(from: data)
        await indexCache.store(data, forKey: cacheKey)
        return decoded
    }

    func resolveScriptURL(indexURL: String, item: SourceConfigIndexItem) -> String? {
        if let direct = item.url, direct.hasPrefix("http") {
            return direct
        }
        guard let relative = item.resolvedFileName else {
            return nil
        }

        guard var base = URL(string: indexURL) else {
            return nil
        }
        if base.pathExtension.lowercased() == "json" {
            base.deleteLastPathComponent()
        }
        return base.appending(path: relative).absoluteString
    }

    func downloadScript(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw SourceConfigServiceError.invalidURL
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw SourceConfigServiceError.invalidResponse
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw SourceConfigServiceError.invalidPayload
        }
        return text
    }

    private func decodeIndex(from data: Data) throws -> [SourceConfigIndexItem] {
        do {
            return try JSONDecoder().decode([SourceConfigIndexItem].self, from: data)
        } catch {
            throw SourceConfigServiceError.invalidPayload
        }
    }
}
