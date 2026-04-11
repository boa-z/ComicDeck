import CoreGraphics
import Foundation
import ImageIO

private nonisolated enum KoharuLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
private nonisolated func koharuDebugLog(_ message: String, level: KoharuLogLevel = .debug) {
    RuntimeDebugConsole.appendRuntimeLine("[SourceRuntime][\(level.rawValue)][Koharu] \(message)")
}

private nonisolated struct KoharuImportResult: Decodable, Sendable {
    struct DocumentSummary: Decodable, Sendable {
        let id: String
        let name: String
        let width: Int
        let height: Int
    }

    let totalCount: Int
    let documents: [DocumentSummary]
}

private nonisolated struct KoharuDocumentDetail: Decodable, Sendable {
    let id: String
    let name: String
    let width: Int
    let height: Int
    let textBlocks: [KoharuTextBlockDetail]
    let image: String
    let segment: String?
    let inpainted: String?
    let brushLayer: String?
    let rendered: String?
}

private nonisolated struct KoharuTextBlockDetail: Decodable, Sendable {
    let id: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let confidence: Double
    let sourceDirection: KoharuTextDirection?
    let renderedDirection: KoharuTextDirection?
    let sourceLanguage: String?
    let rotationDeg: CGFloat?
    let detectedFontSizePx: CGFloat?
    let detector: String?
    let text: String?
    let translation: String?
    let renderX: CGFloat?
    let renderY: CGFloat?
    let renderWidth: CGFloat?
    let renderHeight: CGFloat?
}

private nonisolated enum KoharuTextDirection: String, Decodable, Sendable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"
}

private nonisolated struct KoharuTranslateRequest: Encodable, Sendable {
    let textBlockId: String?
    let language: String?
    let systemPrompt: String?
}

nonisolated enum KoharuLLMTargetKind: String, Encodable, Sendable {
    case provider
    case local
}

private nonisolated enum KoharuLLMCommandError: LocalizedError {
    case missingProviderID
    case missingModelID

    var errorDescription: String? {
        switch self {
        case .missingProviderID:
            return "Koharu provider LLM configuration requires a provider ID."
        case .missingModelID:
            return "Koharu LLM configuration requires a model ID."
        }
    }
}

nonisolated struct KoharuLLMCommand: Sendable {
    struct Body: Encodable, Sendable {
        struct Target: Encodable, Sendable {
            let kind: KoharuLLMTargetKind
            let providerID: String?
            let modelID: String?

            private enum CodingKeys: String, CodingKey {
                case kind
                case providerID = "providerId"
                case modelID = "modelId"
            }
        }

        struct Options: Encodable, Sendable {
            let temperature: Double?
            let maxTokens: Int?
            let customSystemPrompt: String?

            private enum CodingKeys: String, CodingKey {
                case temperature
                case maxTokens
                case customSystemPrompt
            }
        }

        let target: Target
        let options: Options?
    }

    let method: String
    let path: String
    let body: Body?

    static func make(from configuration: ReaderKoharuLLMConfiguration) throws -> KoharuLLMCommand {
        switch configuration.mode {
        case .serverDefault:
            return KoharuLLMCommand(method: "DELETE", path: "llm", body: nil)
        case .provider:
            guard let providerID = configuration.providerID else {
                throw KoharuLLMCommandError.missingProviderID
            }
            guard let modelID = configuration.modelID else {
                throw KoharuLLMCommandError.missingModelID
            }
            return KoharuLLMCommand(
                method: "PUT",
                path: "llm",
                body: Body(
                    target: Body.Target(
                        kind: .provider,
                        providerID: providerID,
                        modelID: modelID
                    ),
                    options: makeOptions(from: configuration)
                )
            )
        case .local:
            guard let modelID = configuration.modelID else {
                throw KoharuLLMCommandError.missingModelID
            }
            return KoharuLLMCommand(
                method: "PUT",
                path: "llm",
                body: Body(
                    target: Body.Target(
                        kind: .local,
                        providerID: nil,
                        modelID: modelID
                    ),
                    options: makeOptions(from: configuration)
                )
            )
        }
    }

    private static func makeOptions(from configuration: ReaderKoharuLLMConfiguration) -> Body.Options? {
        guard configuration.temperature != nil || configuration.maxTokens != nil || configuration.customSystemPrompt != nil else {
            return nil
        }
        return Body.Options(
            temperature: configuration.temperature,
            maxTokens: configuration.maxTokens,
            customSystemPrompt: configuration.customSystemPrompt
        )
    }
}

nonisolated enum KoharuProviderConfigurationFingerprint {
    static func make(configuration: ReaderPageTranslationBackendConfiguration) throws -> String {
        let normalizedBaseURL = try configuration.normalizedKoharuAPIBaseURL()
        let normalizedLLM = configuration.koharuLLM
        let rawValue = [
            "baseURL=\(normalizedBaseURL.absoluteString)",
            "mode=\(normalizedLLM.mode.rawValue)",
            "providerID=\(normalizedLLM.providerID ?? "")",
            "modelID=\(normalizedLLM.modelID ?? "")",
            "temperature=\(normalizedLLM.temperature.map { String(describing: $0) } ?? "")",
            "maxTokens=\(normalizedLLM.maxTokens.map { String($0) } ?? "")",
            "customSystemPrompt=\(normalizedLLM.customSystemPrompt ?? "")"
        ].joined(separator: "|")
        return "koharu-\(ReaderPageTranslationBackendSupport.digest(rawValue))"
    }

    static func make(baseURL: URL, koharuLLM: ReaderKoharuLLMConfiguration) -> String {
        let configuration = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: baseURL.absoluteString,
            requestTimeoutSeconds: ReaderPageTranslationBackendConfiguration.minRequestTimeoutSeconds,
            koharuLLM: koharuLLM
        )
        return (try? make(configuration: configuration))
            ?? "koharu-\(ReaderPageTranslationBackendSupport.digest(baseURL.absoluteString))"
    }
}

private nonisolated struct KoharuAPIError: Decodable, Sendable {
    let status: Int
    let message: String
}

private nonisolated func koharuPipelineError(stage: String, error: Error) -> NSError {
    let nsError = error as NSError
    return NSError(
        domain: "KoharuPipeline",
        code: nsError.code,
        userInfo: [
            NSLocalizedDescriptionKey: "Koharu \(stage) failed: \(nsError.localizedDescription)",
            NSUnderlyingErrorKey: nsError
        ]
    )
}

private nonisolated enum KoharuPageTranslationDocumentMapper {
    static let pipelineVersion = "koharu-page-translation-v1"
    static let providerName = "koharu"

    static func makeDocument(
        detail: KoharuDocumentDetail,
        sourceKey: String,
        comicID: String,
        chapterID: String,
        pageIndex: Int,
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage,
        imageRequestKey: String,
        imageFingerprint: String,
        providerConfigHash: String,
        renderedAssetLocalFilePath: String?
    ) -> ReaderPageTranslationDocument {
        let blocks = detail.textBlocks.enumerated().map { index, block in
            makeBlock(detail: detail, block: block, zIndex: index, sourceLanguage: sourceLanguage)
        }

        let renderedAsset = renderedAssetLocalFilePath.map {
            ReaderRenderedPageAsset(
                localFilePath: $0,
                pixelWidth: detail.width,
                pixelHeight: detail.height,
                renderMode: .translated,
                provider: providerName,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )
        }

        return ReaderPageTranslationDocument(
            id: 0,
            sourceKey: sourceKey,
            comicID: comicID,
            chapterID: chapterID,
            pageIndex: pageIndex,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: providerName,
            status: .ready,
            currentStage: .ready,
            imageRequestKey: imageRequestKey,
            imageFingerprint: imageFingerprint,
            pipelineVersion: pipelineVersion,
            providerConfigHash: providerConfigHash,
            blocks: blocks,
            cleanupRegions: [],
            renderedAsset: renderedAsset,
            errorText: nil,
            updatedAt: 0
        )
    }

    private static func makeBlock(
        detail: KoharuDocumentDetail,
        block: KoharuTextBlockDetail,
        zIndex: Int,
        sourceLanguage: ReaderTranslationLanguage?
    ) -> ReaderTextBlock {
        let sourceRect = ReaderNormalizedRect(
            x: normalized(block.x, total: CGFloat(detail.width)),
            y: normalized(block.y, total: CGFloat(detail.height)),
            width: normalized(block.width, total: CGFloat(detail.width)),
            height: normalized(block.height, total: CGFloat(detail.height))
        )

        let containerRect: ReaderNormalizedRect?
        if let renderX = block.renderX,
           let renderY = block.renderY,
           let renderWidth = block.renderWidth,
           let renderHeight = block.renderHeight {
            containerRect = ReaderNormalizedRect(
                x: normalized(renderX, total: CGFloat(detail.width)),
                y: normalized(renderY, total: CGFloat(detail.height)),
                width: normalized(renderWidth, total: CGFloat(detail.width)),
                height: normalized(renderHeight, total: CGFloat(detail.height))
            )
        } else {
            containerRect = nil
        }

        let preferredDirection = block.renderedDirection ?? block.sourceDirection
        return ReaderTextBlock(
            id: block.id,
            sourceRect: sourceRect,
            containerRect: containerRect,
            readingDirection: readingDirection(for: preferredDirection, sourceLanguage: sourceLanguage),
            sourceText: block.text ?? "",
            translatedText: block.translation,
            styleHints: styleHints(for: preferredDirection),
            zIndex: zIndex,
            confidence: block.confidence
        )
    }

    private static func normalized(_ value: CGFloat, total: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return max(0, min(1, value / total))
    }

    private static func styleHints(for direction: KoharuTextDirection?) -> ReaderTextStyleHints? {
        guard let direction else { return nil }
        return ReaderTextStyleHints(
            fontStyle: .speechBubble,
            prefersVerticalLayout: direction == .vertical
        )
    }

    private static func readingDirection(
        for direction: KoharuTextDirection?,
        sourceLanguage: ReaderTranslationLanguage?
    ) -> ReaderTextReadingDirection {
        switch direction {
        case .vertical:
            return .verticalRL
        case .horizontal:
            return .horizontalLTR
        case .none:
            return ReaderPageTranslationBackendSupport.inferredReadingDirection(sourceLanguage: sourceLanguage)
        }
    }
}

actor KoharuClient {
    private let baseURL: URL
    private let session: URLSession
    private let requestTimeoutSeconds: Int

    init(baseURL: URL, requestTimeoutSeconds: Int, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.requestTimeoutSeconds = ReaderPageTranslationBackendConfiguration.clampedRequestTimeoutSeconds(requestTimeoutSeconds)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieStorage = HTTPCookieStorage.shared
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
            configuration.waitsForConnectivity = true
            self.session = URLSession(configuration: configuration)
        }
    }

    private func logRequest(_ request: URLRequest, body: Data? = nil) {
        guard RuntimeDebugConsole.isEnabled else { return }
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? ""
        let bodySummary = summarizedPayload(body ?? request.httpBody)
        koharuDebugLog(
            "request method=\(method) url=\(urlText) timeout=\(Int(request.timeoutInterval)) headers=\(request.allHTTPHeaderFields ?? [:]) body=\(bodySummary)",
            level: .info
        )
    }

    private func logResponse(_ response: URLResponse, data: Data) {
        guard RuntimeDebugConsole.isEnabled else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let urlText = response.url?.absoluteString ?? ""
        koharuDebugLog(
            "response status=\(status) url=\(urlText) bytes=\(data.count) body=\(summarizedPayload(data))",
            level: status >= 200 && status < 300 ? .info : .warn
        )
    }

    private func logTransportError(_ error: any Error, request: URLRequest) {
        guard RuntimeDebugConsole.isEnabled else { return }
        let method = request.httpMethod ?? "GET"
        let urlText = request.url?.absoluteString ?? ""
        koharuDebugLog(
            "transport error method=\(method) url=\(urlText) timeout=\(Int(request.timeoutInterval)) error=\(error.localizedDescription)",
            level: .error
        )
    }

    private func summarizedPayload(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "<empty>" }
        let decoded = String(data: data, encoding: .utf8) ?? Data(data.prefix(256)).base64EncodedString()
        let singleLine = decoded.replacingOccurrences(of: "\n", with: "\\n")
        if singleLine.count <= 512 {
            return singleLine
        }
        return String(singleLine.prefix(512)) + "…"
    }

    func importDocument(imageData: Data, filename: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpointURL(path: "documents", queryItems: [URLQueryItem(name: "mode", value: "replace")]))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            imageData: imageData,
            filename: filename,
            mimeType: inferredImageMimeType(from: imageData),
            boundary: boundary
        )
        koharuDebugLog("import document filename=\(filename) imageBytes=\(imageData.count)", level: .info)
        let result: KoharuImportResult = try await decodeJSON(request)
        guard let documentID = result.documents.last?.id else {
            throw ReaderPageTranslationBackendConfigurationError.serviceUnavailable
        }
        return documentID
    }

    fileprivate func getDocumentDetail(documentID: String) async throws -> KoharuDocumentDetail {
        var request = URLRequest(url: endpointURL(path: "documents/\(documentID)"))
        request.httpMethod = "GET"
        return try await decodeJSON(request)
    }

    func detect(documentID: String) async throws {
        koharuDebugLog("detect documentID=\(documentID)", level: .info)
        try await postNoContent(path: "documents/\(documentID)/detect")
    }

    func recognize(documentID: String) async throws {
        koharuDebugLog("recognize documentID=\(documentID)", level: .info)
        try await postNoContent(path: "documents/\(documentID)/recognize")
    }

    func applyLLMConfiguration(_ configuration: ReaderKoharuLLMConfiguration) async throws {
        let command = try KoharuLLMCommand.make(from: configuration)
        var request = URLRequest(url: endpointURL(path: command.path))
        request.httpMethod = command.method
        if let body = command.body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else {
            request.httpBody = nil
        }
        koharuDebugLog("apply llm method=\(command.method) mode=\(configuration.mode.rawValue)", level: .info)
        let (data, response) = try await send(request)
        try validate(response: response, data: data)
    }

    func translate(documentID: String, targetLanguage: String) async throws {
        var request = URLRequest(url: endpointURL(path: "documents/\(documentID)/translate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            KoharuTranslateRequest(textBlockId: nil, language: targetLanguage, systemPrompt: nil)
        )
        koharuDebugLog("translate documentID=\(documentID) targetLanguage=\(targetLanguage)", level: .info)
        let (data, response) = try await send(request)
        try validate(response: response, data: data)
    }

    func inpaint(documentID: String) async throws {
        koharuDebugLog("inpaint documentID=\(documentID)", level: .info)
        try await postNoContent(path: "documents/\(documentID)/inpaint")
    }

    func render(documentID: String) async throws {
        koharuDebugLog("render documentID=\(documentID)", level: .info)
        try await postNoContent(path: "documents/\(documentID)/render", body: Data("{}".utf8), contentType: "application/json")
    }

    func exportRendered(documentID: String) async throws -> Data {
        var request = URLRequest(url: endpointURL(
            path: "documents/\(documentID)/export/png",
            queryItems: [URLQueryItem(name: "layer", value: "rendered")]
        ))
        request.httpMethod = "GET"
        koharuDebugLog("export rendered documentID=\(documentID)", level: .info)
        let (data, response) = try await send(request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw ReaderPageTranslationBackendConfigurationError.serviceUnavailable
        }
        koharuDebugLog("export rendered complete documentID=\(documentID) bytes=\(data.count)", level: .info)
        return data
    }

    private func postNoContent(path: String, body: Data? = nil, contentType: String? = nil) async throws {
        var request = URLRequest(url: endpointURL(path: path))
        request.httpMethod = "POST"
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        let (data, response) = try await send(request)
        try validate(response: response, data: data)
    }

    private func endpointURL(path: String, queryItems: [URLQueryItem] = []) -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return baseURL.appendingPathComponent(path)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url ?? baseURL.appendingPathComponent(path)
    }

    private func decodeJSON<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await send(request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = TimeInterval(requestTimeoutSeconds)
        logRequest(request)
        do {
            let (data, response) = try await session.data(for: request)
            logResponse(response, data: data)
            return (data, response)
        } catch {
            logTransportError(error, request: request)
            throw error
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ReaderPageTranslationBackendConfigurationError.serviceUnavailable
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            if let apiError = try? JSONDecoder().decode(KoharuAPIError.self, from: data), !apiError.message.isEmpty {
                throw NSError(domain: "KoharuAPI", code: apiError.status, userInfo: [NSLocalizedDescriptionKey: apiError.message])
            }
            let message = String(data: data, encoding: .utf8) ?? AppLocalization.text(
                "reader.translation.error.service_unavailable",
                "Translation service is unavailable."
            )
            throw NSError(domain: "KoharuAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func multipartBody(imageData: Data, filename: String, mimeType: String, boundary: String) -> Data {
        var data = Data()
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\n".utf8))
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(imageData)
        data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return data
    }

    private func inferredImageMimeType(from data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        return "image/png"
    }
}

actor KoharuPageTranslationBackend: ReaderPageTranslationBackend {
    private let database: SQLiteStore
    private let client: KoharuClient
    private let providerConfigHash: String
    private let workingDirectory: URL
    private let requestTimeoutSeconds: Int
    private let koharuLLM: ReaderKoharuLLMConfiguration

    init(
        database: SQLiteStore,
        baseURL: URL,
        workingDirectory: URL,
        requestTimeoutSeconds: Int,
        koharuLLM: ReaderKoharuLLMConfiguration = ReaderKoharuLLMConfiguration(),
        session: URLSession? = nil
    ) {
        let normalizedRequestTimeoutSeconds = ReaderPageTranslationBackendConfiguration.clampedRequestTimeoutSeconds(requestTimeoutSeconds)
        let fingerprintConfiguration = ReaderPageTranslationBackendConfiguration(
            kind: .koharu,
            koharuBaseURL: baseURL.absoluteString,
            requestTimeoutSeconds: normalizedRequestTimeoutSeconds,
            koharuLLM: koharuLLM
        )

        self.database = database
        self.requestTimeoutSeconds = normalizedRequestTimeoutSeconds
        self.koharuLLM = fingerprintConfiguration.koharuLLM
        self.client = KoharuClient(baseURL: baseURL, requestTimeoutSeconds: normalizedRequestTimeoutSeconds, session: session)
        self.providerConfigHash = (try? KoharuProviderConfigurationFingerprint.make(configuration: fingerprintConfiguration))
            ?? KoharuProviderConfigurationFingerprint.make(baseURL: baseURL, koharuLLM: koharuLLM)
        self.workingDirectory = workingDirectory
    }

    func translatePage(
        item: ComicSummary,
        chapterID: String,
        pageIndex: Int,
        request: ImageRequest,
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage
    ) async throws -> ReaderPageTranslationDocument {
        guard let urlRequest = ReaderPageTranslationBackendSupport.buildURLRequest(
            from: request,
            timeoutSeconds: requestTimeoutSeconds
        ) else {
            throw ReaderImagePipelineError.invalidResponse
        }

        let imageData = try await ReaderImagePipeline.shared.loadData(for: urlRequest)
        let imageRequestKey = ReaderPageTranslationBackendSupport.imageRequestKey(request, sourceLanguage: sourceLanguage)
        let imageFingerprint = ReaderPageTranslationBackendSupport.imageFingerprint(for: imageData)
        koharuDebugLog(
            "translate page start comicID=\(item.id) chapterID=\(chapterID) page=\(pageIndex) source=\(sourceLanguage?.rawValue ?? "auto") target=\(targetLanguage.rawValue) imageBytes=\(imageData.count) fingerprint=\(String(imageFingerprint.prefix(12))) timeout=\(requestTimeoutSeconds)",
            level: .info
        )

        if let cached = try await database.getReaderPageTranslationDocument(
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapterID,
            pageIndex: pageIndex,
            targetLanguage: targetLanguage,
            imageRequestKey: imageRequestKey,
            pipelineVersion: KoharuPageTranslationDocumentMapper.pipelineVersion,
            providerConfigHash: providerConfigHash
        ), cached.imageFingerprint == imageFingerprint {
            return cached
        }

        let fileExtension = inferredFileExtension(from: imageData)
        let filename = "comicdeck-\(item.id)-\(chapterID)-\(pageIndex).\(fileExtension)"
        let documentID: String
        do {
            documentID = try await client.importDocument(imageData: imageData, filename: filename)
        } catch {
            throw koharuPipelineError(stage: "import", error: error)
        }
        koharuDebugLog("document imported page=\(pageIndex) documentID=\(documentID)", level: .info)
        do {
            try await client.detect(documentID: documentID)
        } catch {
            throw koharuPipelineError(stage: "detect", error: error)
        }
        do {
            try await client.recognize(documentID: documentID)
        } catch {
            throw koharuPipelineError(stage: "recognize", error: error)
        }
        do {
            try await client.applyLLMConfiguration(koharuLLM)
        } catch {
            throw koharuPipelineError(stage: "llm", error: error)
        }
        do {
            try await client.translate(documentID: documentID, targetLanguage: targetLanguage.rawValue)
        } catch {
            throw koharuPipelineError(stage: "translate", error: error)
        }
        do {
            try await client.inpaint(documentID: documentID)
        } catch {
            throw koharuPipelineError(stage: "inpaint", error: error)
        }
        do {
            try await client.render(documentID: documentID)
        } catch {
            throw koharuPipelineError(stage: "render", error: error)
        }

        let renderedImageData: Data
        do {
            renderedImageData = try await client.exportRendered(documentID: documentID)
        } catch {
            throw koharuPipelineError(stage: "export rendered", error: error)
        }
        let renderedURL = try persistRenderedImage(
            data: renderedImageData,
            comicID: item.id,
            chapterID: chapterID,
            pageIndex: pageIndex,
            fingerprint: imageFingerprint
        )
        let detail = try await client.getDocumentDetail(documentID: documentID)

        let document = KoharuPageTranslationDocumentMapper.makeDocument(
            detail: detail,
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapterID,
            pageIndex: pageIndex,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            imageRequestKey: imageRequestKey,
            imageFingerprint: imageFingerprint,
            providerConfigHash: providerConfigHash,
            renderedAssetLocalFilePath: renderedURL.path
        )
        koharuDebugLog(
            "translate page ready page=\(pageIndex) documentID=\(documentID) blocks=\(detail.textBlocks.count) renderedBytes=\(renderedImageData.count) renderedPath=\(renderedURL.path)",
            level: .info
        )
        return try await database.upsertReaderPageTranslationDocument(document)
    }

    func saveFailure(
        item: ComicSummary,
        chapterID: String,
        pageIndex: Int,
        request: ImageRequest,
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage,
        errorText: String
    ) async {
        do {
            _ = try await database.upsertReaderPageTranslationDocument(
                ReaderPageTranslationDocument(
                    id: 0,
                    sourceKey: item.sourceKey,
                    comicID: item.id,
                    chapterID: chapterID,
                    pageIndex: pageIndex,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    provider: KoharuPageTranslationDocumentMapper.providerName,
                    status: .failed,
                    currentStage: .failed,
                    imageRequestKey: ReaderPageTranslationBackendSupport.imageRequestKey(request, sourceLanguage: sourceLanguage),
                    imageFingerprint: "",
                    pipelineVersion: KoharuPageTranslationDocumentMapper.pipelineVersion,
                    providerConfigHash: providerConfigHash,
                    blocks: [],
                    cleanupRegions: [],
                    renderedAsset: nil,
                    errorText: errorText,
                    updatedAt: 0
                )
            )
        } catch {
            return
        }
    }

    private func inferredFileExtension(from data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "png"
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "jpg"
        }
        return "png"
    }

    private func persistRenderedImage(
        data: Data,
        comicID: String,
        chapterID: String,
        pageIndex: Int,
        fingerprint: String
    ) throws -> URL {
        let directory = workingDirectory
            .appendingPathComponent("translation-artifacts", isDirectory: true)
            .appendingPathComponent(comicID, isDirectory: true)
            .appendingPathComponent(chapterID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("page-\(pageIndex)-\(fingerprint).png")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
