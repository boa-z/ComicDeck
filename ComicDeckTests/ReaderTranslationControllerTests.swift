import XCTest
@testable import ComicDeck

@MainActor
final class ReaderTranslationControllerTests: XCTestCase {
    func testApplyingChangedPreferencesClearsCachedTranslationState() {
        let controller = ReaderTranslationController()

        controller.applyPreferences(
            ReaderTranslationPreferences(
                enabled: true,
                backendConfiguration: ReaderPageTranslationBackendConfiguration(
                    kind: .koharu,
                    koharuBaseURL: "https://koharu.example.com",
                    requestTimeoutSeconds: 60,
                    koharuLLM: baselineKoharuLLMConfiguration()
                ),
                sourceLanguage: .japanese,
                targetLanguage: .english
            )
        )
        seedTranslationCache(into: controller)
        controller.primeTranslationTaskForTests(pageIndex: 0)
        let initialGeneration = controller.translationGenerationForTests()

        controller.applyPreferences(
            ReaderTranslationPreferences(
                enabled: true,
                backendConfiguration: ReaderPageTranslationBackendConfiguration(
                    kind: .koharu,
                    koharuBaseURL: "https://koharu.example.com",
                    requestTimeoutSeconds: 45,
                    koharuLLM: baselineKoharuLLMConfiguration()
                ),
                sourceLanguage: .japanese,
                targetLanguage: .english
            )
        )

        XCTAssertEqual(controller.translationGenerationForTests(), initialGeneration + 1)
        XCTAssertEqual(controller.translationTaskCountForTests(), 0)
        XCTAssertTrue(controller.pageStates.isEmpty)
        XCTAssertTrue(controller.pageDocuments.isEmpty)
        XCTAssertTrue(controller.errorText.isEmpty)
        XCTAssertEqual(controller.unsupportedReason, "")
    }

    func testEquivalentNormalizedPreferencesKeepCachedTranslationState() {
        let controller = ReaderTranslationController()

        controller.applyPreferences(
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
        seedTranslationCache(into: controller)

        controller.applyPreferences(
            ReaderTranslationPreferences.fromStorage(
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
        )

        XCTAssertEqual(controller.pageStates[0], .ready)
        XCTAssertNotNil(controller.pageDocuments[0])
        XCTAssertEqual(controller.errorText[0], "cached-error")
        XCTAssertEqual(controller.unsupportedReason, "cached-warning")
    }

    func testReloadPageClearsOnlyCurrentPageTranslationState() {
        let controller = ReaderTranslationController()
        seedTranslationCache(into: controller)
        controller.pageStates[1] = .ready
        controller.errorText[1] = "other-error"

        controller.reloadPage(0)

        XCTAssertEqual(controller.status(for: 0), .idle)
        XCTAssertNil(controller.pageDocuments[0])
        XCTAssertNil(controller.error(for: 0))
        XCTAssertEqual(controller.pageStates[1], .ready)
        XCTAssertEqual(controller.errorText[1], "other-error")
    }

    func testStartingTranslationCancelsExistingTaskAndMarksPageProcessing() {
        let controller = ReaderTranslationController()
        controller.errorText[0] = "stale-error"
        controller.primeTranslationTaskForTests(pageIndex: 0)
        let initialGeneration = controller.translationGenerationForTests()

        let generation = controller.beginTranslation(pageIndex: 0)

        XCTAssertEqual(generation, initialGeneration + 1)
        XCTAssertEqual(controller.translationGenerationForTests(), initialGeneration + 1)
        XCTAssertEqual(controller.status(for: 0), .processing)
        XCTAssertNil(controller.errorText[0])
        XCTAssertEqual(controller.translationTaskCountForTests(), 0)
        XCTAssertEqual(controller.unsupportedReason, "")
    }

    func testRecordingSuccessfulTranslationStoresDocumentState() {
        let controller = ReaderTranslationController()
        let document = makeTranslationDocument(pageIndex: 0, status: .ready)

        controller.recordSuccess(document, pageIndex: 0)

        XCTAssertEqual(controller.status(for: 0), .ready)
        XCTAssertEqual(controller.pageDocuments[0], document)
        XCTAssertNil(controller.errorText[0])
    }

    func testRecordingSuccessfulTranslationClearsTrackedTaskForPage() {
        let controller = ReaderTranslationController()
        controller.primeTranslationTaskForTests(pageIndex: 0)

        controller.recordSuccess(makeTranslationDocument(pageIndex: 0, status: .ready), pageIndex: 0)

        XCTAssertEqual(controller.translationTaskCountForTests(), 0)
    }

    func testRecordingFailedTranslationStoresFailureState() {
        let controller = ReaderTranslationController()

        controller.recordFailure(message: "Bad URL", pageIndex: 0, isUnsupported: true)

        XCTAssertEqual(controller.status(for: 0), .failed)
        XCTAssertNil(controller.pageDocuments[0])
        XCTAssertEqual(controller.errorText[0], "Bad URL")
        XCTAssertEqual(controller.unsupportedReason, "Bad URL")
    }

    func testRecordingFailedTranslationClearsTrackedTaskForPage() {
        let controller = ReaderTranslationController()
        controller.primeTranslationTaskForTests(pageIndex: 0)

        controller.recordFailure(message: "Bad URL", pageIndex: 0, isUnsupported: false)

        XCTAssertEqual(controller.translationTaskCountForTests(), 0)
    }

    func testBackendConfigurationReflectsCurrentTranslationSettings() {
        let controller = ReaderTranslationController()
        let expectedLLM = ReaderKoharuLLMConfiguration(
            mode: .provider,
            providerID: "provider-b",
            modelID: "model-2",
            temperature: 0.7,
            maxTokens: 2048,
            customSystemPrompt: "Use concise Chinese."
        )

        controller.backendKind = .koharu
        controller.koharuBaseURL = "https://koharu.example.com"
        controller.requestTimeoutSeconds = 45
        controller.koharuLLM = expectedLLM

        XCTAssertEqual(
            controller.backendConfiguration,
            ReaderPageTranslationBackendConfiguration(
                kind: .koharu,
                koharuBaseURL: "https://koharu.example.com",
                requestTimeoutSeconds: 45,
                koharuLLM: expectedLLM
            )
        )
    }

    func testCurrentGenerationCheckRejectsStaleGenerationAfterInvalidate() {
        let controller = ReaderTranslationController()

        let generation = controller.beginTranslation(pageIndex: 0)
        XCTAssertTrue(controller.isCurrentGeneration(generation))

        controller.invalidate(resetCachedState: false)

        XCTAssertFalse(controller.isCurrentGeneration(generation))
        XCTAssertTrue(controller.isCurrentGeneration(controller.translationGenerationForTests()))
    }

    func testStartingTranslationTaskRemovesTrackedTaskWhenOperationReturns() async {
        let controller = ReaderTranslationController()

        controller.startTranslation(pageIndex: 0) { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(controller.translationTaskCountForTests(), 1)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(controller.translationTaskCountForTests(), 0)
    }

    func testEarlierCompletedTaskDoesNotClearNewerTrackedTask() async {
        let controller = ReaderTranslationController()

        controller.startTranslation(pageIndex: 0) { _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        controller.startTranslation(pageIndex: 0) { _ in
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        XCTAssertEqual(controller.translationTaskCountForTests(), 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(controller.translationTaskCountForTests(), 1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(controller.translationTaskCountForTests(), 0)
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

    private func seedTranslationCache(into controller: ReaderTranslationController) {
        controller.pageStates[0] = .ready
        controller.pageDocuments[0] = makeTranslationDocument(pageIndex: 0, status: .ready)
        controller.errorText[0] = "cached-error"
        controller.unsupportedReason = "cached-warning"
    }

    private func makeTranslationDocument(
        pageIndex: Int,
        status: ReaderPageTranslationStatus
    ) -> ReaderPageTranslationDocument {
        ReaderPageTranslationDocument(
            id: 1,
            sourceKey: "test",
            comicID: "comic-1",
            chapterID: "chapter-1",
            pageIndex: pageIndex,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            provider: "koharu",
            status: status,
            currentStage: status == .ready ? .ready : .failed,
            imageRequestKey: "GET|https://example.com/page-1.jpg",
            imageFingerprint: "fingerprint-1",
            pipelineVersion: "reader-page-translation-v1",
            providerConfigHash: "config-hash-1",
            blocks: [],
            cleanupRegions: [],
            renderedAsset: nil,
            errorText: status == .failed ? "failure" : nil,
            updatedAt: 123456
        )
    }
}
