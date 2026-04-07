import CoreGraphics
import CryptoKit
import Foundation

actor ReaderTranslationService {
    private let database: SQLiteStore
    private let ocrProvider: OCRProvider
    private let translationProvider: TranslationProvider

    init(
        database: SQLiteStore,
        ocrProvider: OCRProvider? = nil,
        translationProvider: TranslationProvider? = nil
    ) {
        self.database = database
        self.ocrProvider = ocrProvider ?? AppleVisionOCRProvider()
        self.translationProvider = translationProvider ?? AppleTranslationProvider()
    }

    func loadCachedPage(
        item: ComicSummary,
        chapterID: String,
        pageIndex: Int,
        request: ImageRequest,
        targetLanguage: ReaderTranslationLanguage
    ) async throws -> ReaderPageTranslationRecord? {
        let requestKey = Self.imageRequestKey(request)
        return try await database.getReaderPageTranslation(
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapterID,
            pageIndex: pageIndex,
            targetLanguage: targetLanguage,
            imageRequestKey: requestKey
        )
    }

    func translatePage(
        item: ComicSummary,
        chapterID: String,
        pageIndex: Int,
        request: ImageRequest,
        targetLanguage: ReaderTranslationLanguage
    ) async throws -> ReaderPageTranslationRecord {
        guard let urlRequest = Self.buildURLRequest(from: request) else {
            throw ReaderImagePipelineError.invalidResponse
        }

        let imageData = try await ReaderImagePipeline.shared.loadData(for: urlRequest)
        let requestKey = Self.imageRequestKey(request)
        let fingerprint = Self.imageFingerprint(for: imageData)

        if let cached = try await database.getReaderPageTranslation(
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapterID,
            pageIndex: pageIndex,
            targetLanguage: targetLanguage,
            imageRequestKey: requestKey
        ), cached.imageFingerprint == fingerprint {
            return cached
        }

        let regions = try await ocrProvider.recognizeTextRegions(from: imageData)
        let translated = try await translationProvider.translate(
            texts: regions.map(\.text),
            targetLanguage: targetLanguage
        )

        let overlays = zip(regions, translated).enumerated().map { idx, pair in
            ReaderTranslationOverlay(
                id: "page-\(pageIndex)-overlay-\(idx)",
                pageIndex: pageIndex,
                x: pair.0.boundingBox.minX,
                y: 1 - pair.0.boundingBox.maxY,
                width: pair.0.boundingBox.width,
                height: pair.0.boundingBox.height,
                text: pair.1,
                sourceText: pair.0.text
            )
        }

        return try await database.upsertReaderPageTranslation(
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapterID,
            pageIndex: pageIndex,
            targetLanguage: targetLanguage,
            provider: "\(ocrProvider.name)+\(translationProvider.name)",
            status: .ready,
            imageRequestKey: requestKey,
            imageFingerprint: fingerprint,
            overlays: overlays,
            errorText: nil
        )
    }

    func saveFailure(
        item: ComicSummary,
        chapterID: String,
        pageIndex: Int,
        request: ImageRequest,
        targetLanguage: ReaderTranslationLanguage,
        errorText: String
    ) async {
        do {
            _ = try await database.upsertReaderPageTranslation(
                sourceKey: item.sourceKey,
                comicID: item.id,
                chapterID: chapterID,
                pageIndex: pageIndex,
                targetLanguage: targetLanguage,
                provider: "\(ocrProvider.name)+\(translationProvider.name)",
                status: .failed,
                imageRequestKey: Self.imageRequestKey(request),
                imageFingerprint: "",
                overlays: [],
                errorText: errorText
            )
        } catch {
            return
        }
    }

    private static func imageFingerprint(for data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private static func buildURLRequest(from request: ImageRequest) -> URLRequest? {
        let normalizedURL = request.url.hasPrefix("//") ? "https:\(request.url)" : request.url
        guard let url = URL(string: normalizedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file"
        else {
            return nil
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = 25
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

    private static func imageRequestKey(_ request: ImageRequest) -> String {
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
        let bodyDigest = bodyData.map { Self.digest($0.base64EncodedString()) } ?? "no-body"
        let normalizedMethod = request.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let method = normalizedMethod.isEmpty ? "GET" : normalizedMethod
        return [method, request.url, headers, bodyDigest].joined(separator: "|")
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
}
