import Foundation
import Observation

@MainActor
@Observable
final class ReaderTranslationController {
    var enabled = false
    var showOriginal = false
    var backendKind: ReaderTranslationBackendKind = .builtIn
    var koharuBaseURL = ""
    var requestTimeoutSeconds = 60
    var koharuLLM = ReaderKoharuLLMConfiguration()
    var sourceLanguage: ReaderTranslationLanguage?
    var targetLanguage: ReaderTranslationLanguage = .chineseSimplified
    var pageStates: [Int: ReaderPageTranslationStatus] = [:]
    var pageDocuments: [Int: ReaderPageTranslationDocument] = [:]
    var errorText: [Int: String] = [:]
    var unsupportedReason = ""
    var translationGeneration = 0
    var translationTasks: [Int: Task<Void, Never>] = [:]
    private var translationTaskIdentifiers: [Int: Int] = [:]
    private var nextTranslationTaskIdentifier = 0

    var backendConfiguration: ReaderPageTranslationBackendConfiguration {
        ReaderPageTranslationBackendConfiguration(
            kind: backendKind,
            koharuBaseURL: koharuBaseURL,
            requestTimeoutSeconds: requestTimeoutSeconds,
            koharuLLM: koharuLLM
        )
    }

    var pageBlocks: [Int: [ReaderTextBlock]] {
        pageDocuments.mapValues { $0.blocks }
    }

    var renderedAssets: [Int: ReaderRenderedPageAsset] {
        pageDocuments.compactMapValues(\.renderedAsset)
    }

    func applyPreferences(_ preferences: ReaderTranslationPreferences) {
        let normalizedBackendConfiguration = preferences.backendConfiguration
        let preferencesChanged = backendConfiguration != normalizedBackendConfiguration
            || sourceLanguage != preferences.sourceLanguage
            || targetLanguage != preferences.targetLanguage

        enabled = preferences.enabled
        showOriginal = false
        backendKind = normalizedBackendConfiguration.kind
        koharuBaseURL = normalizedBackendConfiguration.koharuBaseURL
        requestTimeoutSeconds = normalizedBackendConfiguration.requestTimeoutSeconds
        koharuLLM = normalizedBackendConfiguration.koharuLLM
        sourceLanguage = preferences.sourceLanguage
        targetLanguage = preferences.targetLanguage

        if preferencesChanged {
            invalidate(resetCachedState: true)
        }
    }

    func toggleShowOriginal() {
        showOriginal.toggle()
    }

    func status(for pageIndex: Int) -> ReaderPageTranslationStatus {
        pageStates[pageIndex] ?? .idle
    }

    func blocks(for pageIndex: Int) -> [ReaderTextBlock] {
        guard !showOriginal else { return [] }
        return pageDocuments[pageIndex]?.blocks ?? []
    }

    func error(for pageIndex: Int) -> String? {
        guard !showOriginal else { return nil }
        return errorText[pageIndex]
    }

    func reloadPage(_ pageIndex: Int) {
        pageStates[pageIndex] = .idle
        pageDocuments[pageIndex] = nil
        errorText[pageIndex] = nil
    }

    func beginTranslation(pageIndex: Int) -> Int {
        unsupportedReason = ""
        translationGeneration += 1
        translationTasks[pageIndex]?.cancel()
        translationTasks.removeValue(forKey: pageIndex)
        translationTaskIdentifiers.removeValue(forKey: pageIndex)
        pageStates[pageIndex] = .processing
        errorText[pageIndex] = nil
        return translationGeneration
    }

    func startTranslation(
        pageIndex: Int,
        operation: @escaping @MainActor (Int) async -> Void
    ) {
        let generation = beginTranslation(pageIndex: pageIndex)
        nextTranslationTaskIdentifier += 1
        let taskIdentifier = nextTranslationTaskIdentifier
        translationTaskIdentifiers[pageIndex] = taskIdentifier
        let task = Task { [weak self] in
            await operation(generation)
            self?.finishTranslationTask(pageIndex: pageIndex, taskIdentifier: taskIdentifier)
        }
        translationTasks[pageIndex] = task
    }

    func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == translationGeneration
    }

    func recordSuccess(_ document: ReaderPageTranslationDocument, pageIndex: Int) {
        translationTasks.removeValue(forKey: pageIndex)
        translationTaskIdentifiers.removeValue(forKey: pageIndex)
        pageStates[pageIndex] = document.status
        pageDocuments[pageIndex] = document
        errorText[pageIndex] = document.errorText
    }

    func recordFailure(message: String, pageIndex: Int, isUnsupported: Bool) {
        translationTasks.removeValue(forKey: pageIndex)
        translationTaskIdentifiers.removeValue(forKey: pageIndex)
        pageStates[pageIndex] = .failed
        pageDocuments[pageIndex] = nil
        errorText[pageIndex] = message
        if isUnsupported {
            unsupportedReason = message
        }
    }

    func invalidate(resetCachedState: Bool) {
        translationGeneration += 1
        translationTasks.values.forEach { $0.cancel() }
        translationTasks.removeAll()
        translationTaskIdentifiers.removeAll()

        guard resetCachedState else { return }
        pageStates.removeAll()
        pageDocuments.removeAll()
        errorText.removeAll()
        unsupportedReason = ""
    }

    private func finishTranslationTask(pageIndex: Int, taskIdentifier: Int) {
        guard translationTaskIdentifiers[pageIndex] == taskIdentifier else { return }
        translationTasks.removeValue(forKey: pageIndex)
        translationTaskIdentifiers.removeValue(forKey: pageIndex)
    }

    #if DEBUG
    func translationGenerationForTests() -> Int {
        translationGeneration
    }

    func primeTranslationTaskForTests(pageIndex: Int = 0) {
        translationTasks[pageIndex] = Task {}
    }

    func translationTaskCountForTests() -> Int {
        translationTasks.count
    }
    #endif
}
