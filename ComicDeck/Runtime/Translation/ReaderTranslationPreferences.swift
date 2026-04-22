import Foundation

struct ReaderTranslationPreferences: Equatable, Sendable {
    let enabled: Bool
    let backendConfiguration: ReaderPageTranslationBackendConfiguration
    let sourceLanguage: ReaderTranslationLanguage?
    let targetLanguage: ReaderTranslationLanguage

    init(
        enabled: Bool,
        backendConfiguration: ReaderPageTranslationBackendConfiguration,
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage
    ) {
        self.enabled = enabled
        self.backendConfiguration = backendConfiguration
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }

    static func fromStorage(
        enabled: Bool,
        backendRaw: String,
        koharuBaseURL: String,
        requestTimeoutSeconds: Int,
        koharuLLMModeRaw: String,
        koharuLLMProviderID: String,
        koharuLLMModelID: String,
        koharuLLMTemperatureRaw: String,
        koharuLLMMaxTokensRaw: String,
        koharuLLMSystemPrompt: String,
        sourceLanguageRaw: String,
        targetLanguageRaw: String
    ) -> Self {
        let backendKind = ReaderTranslationBackendKind(rawValue: Self.trimmed(backendRaw)) ?? .builtIn
        let koharuLLMMode = ReaderKoharuLLMMode(rawValue: Self.trimmed(koharuLLMModeRaw)) ?? .serverDefault
        let sourceLanguage = ReaderTranslationLanguage(rawValue: Self.trimmed(sourceLanguageRaw))
        let targetLanguage = ReaderTranslationLanguage(rawValue: Self.trimmed(targetLanguageRaw)) ?? .chineseSimplified

        return Self(
            enabled: enabled,
            backendConfiguration: ReaderPageTranslationBackendConfiguration(
                kind: backendKind,
                koharuBaseURL: Self.trimmed(koharuBaseURL),
                requestTimeoutSeconds: requestTimeoutSeconds,
                koharuLLM: ReaderKoharuLLMConfiguration(
                    mode: koharuLLMMode,
                    providerID: koharuLLMProviderID,
                    modelID: koharuLLMModelID,
                    temperature: Self.parseDouble(koharuLLMTemperatureRaw),
                    maxTokens: Self.parseInt(koharuLLMMaxTokensRaw),
                    customSystemPrompt: koharuLLMSystemPrompt
                )
            ),
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    private static func parseDouble(_ rawValue: String) -> Double? {
        let trimmed = trimmed(rawValue)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed)
    }

    private static func parseInt(_ rawValue: String) -> Int? {
        let trimmed = trimmed(rawValue)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    private static func trimmed(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
