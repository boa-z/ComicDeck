import CryptoKit
import Foundation

enum ReaderTranslationBackendKind: String, CaseIterable, Identifiable, Sendable, Hashable {
    case builtIn
    case koharu

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .builtIn:
            return AppLocalization.text(
                "reader.translation.settings.backend.option.built_in",
                "Built-in"
            )
        case .koharu:
            return AppLocalization.text(
                "reader.translation.settings.backend.option.koharu",
                "Koharu"
            )
        }
    }
}

enum ReaderKoharuLLMMode: String, Sendable, Hashable {
    case serverDefault
    case provider
    case local
}

struct ReaderKoharuLLMConfiguration: Sendable, Hashable {
    let mode: ReaderKoharuLLMMode
    let providerID: String?
    let modelID: String?
    let temperature: Double?
    let maxTokens: Int?
    let customSystemPrompt: String?

    nonisolated init(
        mode: ReaderKoharuLLMMode = .serverDefault,
        providerID: String? = nil,
        modelID: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        customSystemPrompt: String? = nil
    ) {
        let normalizedProviderID = Self.normalizedOptionalString(providerID)
        let normalizedModelID = Self.normalizedOptionalString(modelID)
        let normalizedCustomSystemPrompt = Self.normalizedOptionalString(customSystemPrompt)

        self.mode = mode

        switch mode {
        case .serverDefault:
            self.providerID = nil
            self.modelID = nil
            self.temperature = nil
            self.maxTokens = nil
            self.customSystemPrompt = nil
        case .provider:
            self.providerID = normalizedProviderID
            self.modelID = normalizedModelID
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.customSystemPrompt = normalizedCustomSystemPrompt
        case .local:
            self.providerID = nil
            self.modelID = normalizedModelID
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.customSystemPrompt = normalizedCustomSystemPrompt
        }
    }

    nonisolated private static func normalizedOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

struct ReaderPageTranslationBackendConfiguration: Sendable, Hashable {
    static let minRequestTimeoutSeconds = 15
    static let maxRequestTimeoutSeconds = 300

    let kind: ReaderTranslationBackendKind
    let koharuBaseURL: String
    let requestTimeoutSeconds: Int
    let koharuLLM: ReaderKoharuLLMConfiguration

    init(
        kind: ReaderTranslationBackendKind,
        koharuBaseURL: String,
        requestTimeoutSeconds: Int,
        koharuLLM: ReaderKoharuLLMConfiguration = ReaderKoharuLLMConfiguration()
    ) {
        self.kind = kind
        self.koharuBaseURL = koharuBaseURL
        self.requestTimeoutSeconds = Self.clampedRequestTimeoutSeconds(requestTimeoutSeconds)
        self.koharuLLM = koharuLLM
    }

    nonisolated static func clampedRequestTimeoutSeconds(_ value: Int) -> Int {
        min(max(value, minRequestTimeoutSeconds), maxRequestTimeoutSeconds)
    }

    var trimmedKoharuBaseURL: String {
        koharuBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func normalizedKoharuAPIBaseURL() throws -> URL {
        let trimmed = trimmedKoharuBaseURL
        guard !trimmed.isEmpty,
              let rawURL = URL(string: trimmed),
              var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            throw ReaderPageTranslationBackendConfigurationError.invalidKoharuBaseURL
        }

        components.query = nil
        components.fragment = nil
        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath: String
        if trimmedPath.isEmpty {
            normalizedPath = "api/v1"
        } else if trimmedPath.hasSuffix("api/v1") {
            normalizedPath = trimmedPath
        } else {
            normalizedPath = trimmedPath + "/api/v1"
        }
        components.path = "/" + normalizedPath

        guard let url = components.url else {
            throw ReaderPageTranslationBackendConfigurationError.invalidKoharuBaseURL
        }
        return url
    }
}

enum ReaderPageTranslationBackendConfigurationError: LocalizedError {
    case serviceUnavailable
    case invalidKoharuBaseURL

    nonisolated var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            return AppLocalization.text(
                "reader.translation.error.service_unavailable",
                "Translation service is unavailable."
            )
        case .invalidKoharuBaseURL:
            return AppLocalization.text(
                "reader.translation.error.koharu_url_invalid",
                "Koharu server URL is invalid."
            )
        }
    }
}

protocol ReaderPageTranslationBackend: Sendable {
    func translatePage(
        item: ComicSummary,
        chapterID: String,
        pageIndex: Int,
        request: ImageRequest,
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage
    ) async throws -> ReaderPageTranslationDocument

    func saveFailure(
        item: ComicSummary,
        chapterID: String,
        pageIndex: Int,
        request: ImageRequest,
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage,
        errorText: String
    ) async
}

enum ReaderPageTranslationBackendSupport {
    nonisolated static func buildURLRequest(from request: ImageRequest, timeoutSeconds: Int) -> URLRequest? {
        let normalizedURL = request.url.hasPrefix("//") ? "https:\(request.url)" : request.url
        guard let url = URL(string: normalizedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file"
        else {
            return nil
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = TimeInterval(ReaderPageTranslationBackendConfiguration.clampedRequestTimeoutSeconds(timeoutSeconds))
        let normalizedMethod = request.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let method = normalizedMethod.isEmpty ? "GET" : normalizedMethod
        urlRequest.httpMethod = method
        if method != "GET" && method != "HEAD", let body = request.body, !body.isEmpty {
            urlRequest.httpBody = Data(body)
        } else {
            urlRequest.httpBody = nil
            urlRequest.setValue(nil as String?, forHTTPHeaderField: "Content-Length")
        }
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if urlRequest.value(forHTTPHeaderField: "Accept") == nil {
            urlRequest.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        }
        if urlRequest.value(forHTTPHeaderField: "User-Agent") == nil {
            urlRequest.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        }
        if urlRequest.value(forHTTPHeaderField: "Referer") == nil,
           urlRequest.value(forHTTPHeaderField: "referer") == nil,
           let host = url.host {
            urlRequest.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }
        return urlRequest
    }

    nonisolated static func imageFingerprint(for data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func imageRequestKey(_ request: ImageRequest, sourceLanguage: ReaderTranslationLanguage?) -> String {
        let bodyData = request.body.map { Data($0) }
        let headers = request.headers
            .map { ($0.key.lowercased(), $0.value) }
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 {
                    return lhs.1 < rhs.1
                }
                return lhs.0 < rhs.0
            }
            .map { "\($0)=\($1)" }
            .joined(separator: "&")
        let bodyDigest = bodyData.map { digest($0.base64EncodedString()) } ?? "no-body"
        let normalizedMethod = request.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let method = normalizedMethod.isEmpty ? "GET" : normalizedMethod
        return [method, request.url, sourceLanguage?.rawValue ?? "auto", headers, bodyDigest].joined(separator: "|")
    }

    nonisolated static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func inferredReadingDirection(sourceLanguage: ReaderTranslationLanguage?) -> ReaderTextReadingDirection {
        switch sourceLanguage {
        case .japanese, .korean, .chineseSimplified, .chineseTraditional:
            return .verticalRL
        case .english, .none:
            return .horizontalLTR
        }
    }
}
