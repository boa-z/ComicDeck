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

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        self.session = URLSession(configuration: config)
    }

    func fetchIndex(from indexURL: String) async throws -> [SourceConfigIndexItem] {
        guard let url = URL(string: indexURL) else {
            throw SourceConfigServiceError.invalidURL
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw SourceConfigServiceError.invalidResponse
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode([SourceConfigIndexItem].self, from: data)
        } catch {
            throw SourceConfigServiceError.invalidPayload
        }
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
}
