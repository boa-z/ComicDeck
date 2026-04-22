import XCTest
@testable import ComicDeck

@MainActor
final class ReaderSessionTranslationPreferencesTests: XCTestCase {
    func testChangingKoharuLLMConfigurationClearsCachedTranslationState() {
        let session = makeSession()

        session.applyTranslationPreferences(
            enabled: true,
            backendKind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            koharuLLM: baselineKoharuLLMConfiguration()
        )
        seedTranslationCache(into: session)

        session.applyTranslationPreferences(
            enabled: true,
            backendKind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-2",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            )
        )

        XCTAssertTrue(session.translationPageStates.isEmpty)
        XCTAssertTrue(session.translationPageDocuments.isEmpty)
        XCTAssertTrue(session.translationErrorText.isEmpty)
        XCTAssertTrue(session.translationUnsupportedReason.isEmpty)
    }

    func testChangingPreferencesInvalidatesGenerationAndCancelsTrackedTasks() {
        let session = makeSession()

        session.applyTranslationPreferences(
            enabled: true,
            backendKind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            koharuLLM: baselineKoharuLLMConfiguration()
        )
        seedTranslationCache(into: session)
        session.primeTranslationTaskForTests(pageIndex: 0)
        let initialGeneration = session.translationGenerationForTests()

        session.applyTranslationPreferences(
            enabled: true,
            backendKind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 45,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            koharuLLM: baselineKoharuLLMConfiguration()
        )

        XCTAssertEqual(session.translationGenerationForTests(), initialGeneration + 1)
        XCTAssertEqual(session.translationTaskCountForTests(), 0)
        XCTAssertTrue(session.translationPageStates.isEmpty)
        XCTAssertTrue(session.translationPageDocuments.isEmpty)
        XCTAssertTrue(session.translationErrorText.isEmpty)
        XCTAssertTrue(session.translationUnsupportedReason.isEmpty)
    }

    func testReapplyingEquivalentNormalizedKoharuLLMConfigurationKeepsCachedTranslationState() {
        let session = makeSession()

        session.applyTranslationPreferences(
            enabled: true,
            backendKind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            koharuLLM: baselineKoharuLLMConfiguration()
        )
        seedTranslationCache(into: session)

        session.applyTranslationPreferences(
            enabled: true,
            backendKind: .koharu,
            koharuBaseURL: "https://koharu.example.com",
            requestTimeoutSeconds: 60,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            koharuLLM: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: " provider-a ",
                modelID: " model-1 ",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: " Translate naturally. "
            )
        )

        XCTAssertEqual(session.translationPageStates[0], .ready)
        XCTAssertNotNil(session.translationPageDocuments[0])
        XCTAssertEqual(session.translationErrorText[0], "cached-error")
        XCTAssertEqual(session.translationUnsupportedReason, "cached-warning")
    }

    func testApplyingEquivalentNormalizedPreferencesSnapshotKeepsCachedTranslationState() {
        let session = makeSession()

        session.applyTranslationPreferences(
            ReaderTranslationPreferences.fromStorage(
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
        )
        seedTranslationCache(into: session)

        session.applyTranslationPreferences(
            ReaderTranslationPreferences.fromStorage(
                enabled: true,
                backendRaw: ReaderTranslationBackendKind.koharu.rawValue,
                koharuBaseURL: " https://koharu.example.com ",
                requestTimeoutSeconds: 60,
                koharuLLMModeRaw: ReaderKoharuLLMMode.provider.rawValue,
                koharuLLMProviderID: " provider-a ",
                koharuLLMModelID: " model-1 ",
                koharuLLMTemperatureRaw: " 0.4 ",
                koharuLLMMaxTokensRaw: " 1024 ",
                koharuLLMSystemPrompt: " Translate naturally. ",
                sourceLanguageRaw: ReaderTranslationLanguage.japanese.rawValue,
                targetLanguageRaw: ReaderTranslationLanguage.english.rawValue
            )
        )

        XCTAssertEqual(session.translationPageStates[0], .ready)
        XCTAssertNotNil(session.translationPageDocuments[0])
        XCTAssertEqual(session.translationErrorText[0], "cached-error")
        XCTAssertEqual(session.translationUnsupportedReason, "cached-warning")
    }

    func testCompletedChapterProgressReturnsCompletedWhenLastPageIsResolved() {
        let session = makeSession()
        session.chapterSequence = [
            ComicChapter(id: "chapter-1", title: "Chapter 1"),
            ComicChapter(id: "chapter-2", title: "Chapter 2")
        ]
        session.currentChapterIndex = 1
        session.totalPages = 3
        session.resolvedPageCount = 3
        session.imageRequests = [
            ImageRequest(url: "https://example.com/1.jpg", method: "GET", headers: [:], body: nil),
            ImageRequest(url: "https://example.com/2.jpg", method: "GET", headers: [:], body: nil),
            ImageRequest(url: "https://example.com/3.jpg", method: "GET", headers: [:], body: nil)
        ].map(Optional.some)
        session.currentPage = 2

        let completion = session.completedChapterProgress(readerMode: .ltr)

        XCTAssertEqual(completion?.progress, 2)
        XCTAssertEqual(completion?.status, .completed)
    }

    func testCompletedChapterProgressReturnsNilWhenLastPageRequestIsMissing() {
        let session = makeSession()
        session.chapterSequence = [ComicChapter(id: "chapter-1", title: "Chapter 1")]
        session.currentChapterIndex = 0
        session.totalPages = 3
        session.resolvedPageCount = 3
        session.imageRequests = [
            ImageRequest(url: "https://example.com/1.jpg", method: "GET", headers: [:], body: nil),
            ImageRequest(url: "https://example.com/2.jpg", method: "GET", headers: [:], body: nil),
            nil
        ]
        session.currentPage = 2

        let completion = session.completedChapterProgress(readerMode: .ltr)

        XCTAssertNil(completion)
    }

    private func makeSession() -> ReaderSession {
        ReaderSession(
            item: ComicSummary(id: "comic-1", sourceKey: "test", title: "Test Comic"),
            chapterID: "chapter-1",
            chapterTitle: "Chapter 1"
        )
    }

    private func baselineKoharuLLMConfiguration() -> ReaderKoharuLLMConfiguration {
        ReaderKoharuLLMConfiguration(
            mode: .provider,
            providerID: "provider-a",
            modelID: "model-1",
            temperature: 0.4,
            maxTokens: 1024,
            customSystemPrompt: "Translate naturally."
        )
    }

    private func seedTranslationCache(into session: ReaderSession) {
        session.translationPageStates[0] = .ready
        session.translationPageDocuments[0] = ReaderPageTranslationDocument(
            id: 1,
            sourceKey: "test",
            comicID: "comic-1",
            chapterID: "chapter-1",
            pageIndex: 0,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            provider: "koharu",
            status: .ready,
            currentStage: .ready,
            imageRequestKey: "GET|https://example.com/page-1.jpg",
            imageFingerprint: "fingerprint-1",
            pipelineVersion: "reader-page-translation-v1",
            providerConfigHash: "config-hash-1",
            blocks: [],
            cleanupRegions: [],
            renderedAsset: nil,
            errorText: nil,
            updatedAt: 123456
        )
        session.translationErrorText[0] = "cached-error"
        session.translationUnsupportedReason = "cached-warning"
    }
}
