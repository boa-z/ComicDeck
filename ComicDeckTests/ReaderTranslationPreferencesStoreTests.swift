import XCTest
@testable import ComicDeck

@MainActor
final class ReaderTranslationPreferencesStoreTests: XCTestCase {
    func testFromStorageNormalizesKoharuPreferences() {
        let preferences = ReaderTranslationPreferences.fromStorage(
            enabled: true,
            backendRaw: ReaderTranslationBackendKind.koharu.rawValue,
            koharuBaseURL: " https://koharu.example.com ",
            requestTimeoutSeconds: 5,
            koharuLLMModeRaw: ReaderKoharuLLMMode.provider.rawValue,
            koharuLLMProviderID: " provider-a ",
            koharuLLMModelID: " model-1 ",
            koharuLLMTemperatureRaw: " 0.4 ",
            koharuLLMMaxTokensRaw: " 1024 ",
            koharuLLMSystemPrompt: " Translate naturally. ",
            sourceLanguageRaw: ReaderTranslationLanguage.japanese.rawValue,
            targetLanguageRaw: ReaderTranslationLanguage.english.rawValue
        )

        XCTAssertTrue(preferences.enabled)
        XCTAssertEqual(preferences.sourceLanguage, .japanese)
        XCTAssertEqual(preferences.targetLanguage, .english)
        XCTAssertEqual(
            preferences.backendConfiguration,
            ReaderPageTranslationBackendConfiguration(
                kind: .koharu,
                koharuBaseURL: "https://koharu.example.com",
                requestTimeoutSeconds: ReaderPageTranslationBackendConfiguration.minRequestTimeoutSeconds,
                koharuLLM: ReaderKoharuLLMConfiguration(
                    mode: .provider,
                    providerID: "provider-a",
                    modelID: "model-1",
                    temperature: 0.4,
                    maxTokens: 1024,
                    customSystemPrompt: "Translate naturally."
                )
            )
        )
    }

    func testFromStorageFallsBackForInvalidRawValues() {
        let preferences = ReaderTranslationPreferences.fromStorage(
            enabled: false,
            backendRaw: "invalid-backend",
            koharuBaseURL: "",
            requestTimeoutSeconds: 999,
            koharuLLMModeRaw: "invalid-mode",
            koharuLLMProviderID: "",
            koharuLLMModelID: "",
            koharuLLMTemperatureRaw: "oops",
            koharuLLMMaxTokensRaw: "oops",
            koharuLLMSystemPrompt: "",
            sourceLanguageRaw: "invalid-source",
            targetLanguageRaw: "invalid-target"
        )

        XCTAssertFalse(preferences.enabled)
        XCTAssertNil(preferences.sourceLanguage)
        XCTAssertEqual(preferences.targetLanguage, .chineseSimplified)
        XCTAssertEqual(
            preferences.backendConfiguration,
            ReaderPageTranslationBackendConfiguration(
                kind: .builtIn,
                koharuBaseURL: "",
                requestTimeoutSeconds: ReaderPageTranslationBackendConfiguration.maxRequestTimeoutSeconds,
                koharuLLM: ReaderKoharuLLMConfiguration(mode: .serverDefault)
            )
        )
    }

    func testEquivalentNormalizedStorageProducesEqualPreferences() {
        let lhs = ReaderTranslationPreferences.fromStorage(
            enabled: true,
            backendRaw: " \(ReaderTranslationBackendKind.koharu.rawValue) ",
            koharuBaseURL: " https://koharu.example.com ",
            requestTimeoutSeconds: 60,
            koharuLLMModeRaw: " \(ReaderKoharuLLMMode.provider.rawValue) ",
            koharuLLMProviderID: " provider-a ",
            koharuLLMModelID: " model-1 ",
            koharuLLMTemperatureRaw: " 0.4 ",
            koharuLLMMaxTokensRaw: " 1024 ",
            koharuLLMSystemPrompt: " Translate naturally. ",
            sourceLanguageRaw: " \(ReaderTranslationLanguage.japanese.rawValue) ",
            targetLanguageRaw: " \(ReaderTranslationLanguage.english.rawValue) "
        )
        let rhs = ReaderTranslationPreferences.fromStorage(
            enabled: true,
            backendRaw: ReaderTranslationBackendKind.koharu.rawValue,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            koharuLLMModeRaw: ReaderKoharuLLMMode.provider.rawValue,
            koharuLLMProviderID: "provider-a",
            koharuLLMModelID: "model-1",
            koharuLLMTemperatureRaw: "0.4",
            koharuLLMMaxTokensRaw: "1024",
            koharuLLMSystemPrompt: "Translate naturally.",
            sourceLanguageRaw: ReaderTranslationLanguage.japanese.rawValue,
            targetLanguageRaw: ReaderTranslationLanguage.english.rawValue
        )

        XCTAssertEqual(lhs, rhs)
    }
}
