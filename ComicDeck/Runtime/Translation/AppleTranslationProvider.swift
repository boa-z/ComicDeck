import Foundation
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

protocol TranslationProvider: Sendable {
    nonisolated var name: String { get }
    @MainActor
    func translate(
        texts: [String],
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage
    ) async throws -> [String]
}

enum AppleTranslationProviderError: LocalizedError {
    case unavailable
    case noInstalledLanguageModel
    case invalidTranslationResponse(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return AppLocalization.text("reader.translation.error.unavailable", "On-device translation is unavailable on this device.")
        case .noInstalledLanguageModel:
            return AppLocalization.text("reader.translation.error.model_not_installed", "The required on-device translation model is not installed.")
        case let .invalidTranslationResponse(expected, actual):
            return AppLocalization.format(
                "reader.translation.error.invalid_response",
                "Translation returned %1$lld items for %2$lld requests.",
                Int64(actual),
                Int64(expected)
            )
        }
    }
}

struct AppleTranslationProvider: TranslationProvider {
    nonisolated let name = "apple-translation"

    @MainActor
    func translate(
        texts: [String],
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage
    ) async throws -> [String] {
        let normalized = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.contains(where: { !$0.isEmpty }) else { return texts }

        #if canImport(Translation)
        if #available(iOS 18.0, macOS 26.0, *) {
            let resolvedSourceLanguage = sourceLanguage?.localeLanguage ?? detectSourceLanguage(in: normalized)
            let availability = LanguageAvailability()
            let status = await availability.status(from: resolvedSourceLanguage, to: targetLanguage.localeLanguage)
            guard status == .installed else {
                throw AppleTranslationProviderError.noInstalledLanguageModel
            }

            let responses = try await translateBatch(
                normalized,
                sourceLanguage: resolvedSourceLanguage,
                targetLanguage: targetLanguage.localeLanguage
            )
            guard responses.count == normalized.count else {
                throw AppleTranslationProviderError.invalidTranslationResponse(expected: normalized.count, actual: responses.count)
            }
            let mapped: [Int: String] = Dictionary(uniqueKeysWithValues: responses.compactMap { response -> (Int, String)? in
                guard let identifier = response.clientIdentifier, let index = Int(identifier) else { return nil }
                return (index, response.targetText)
            })
            return normalized.enumerated().map { mapped[$0.offset] ?? $0.element }
        }
        #endif

        throw AppleTranslationProviderError.unavailable
    }

    private func detectSourceLanguage(in texts: [String]) -> Locale.Language {
        let recognizer = NLLanguageRecognizer()
        for text in texts where !text.isEmpty {
            recognizer.processString(text)
        }
        if let language = recognizer.dominantLanguage {
            return Locale.Language(identifier: language.rawValue)
        }
        return Locale.Language(identifier: "ja")
    }

    #if canImport(Translation)
    @available(iOS 18.0, macOS 26.0, *)
    private nonisolated func translateBatch(
        _ texts: [String],
        sourceLanguage: Locale.Language,
        targetLanguage: Locale.Language
    ) async throws -> [TranslationSession.Response] {
        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
        let requests = texts.enumerated().map { index, text in
            TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
        }
        return try await session.translations(from: requests)
    }
    #endif
}
