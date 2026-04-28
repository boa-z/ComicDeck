import Foundation
import Observation
import SwiftUI

enum OfflineChapterLoadError: LocalizedError {
    case missingDirectory
    case noImagesFound
    case incompleteDownload(found: Int, expected: Int)

    var errorDescription: String? {
        switch self {
        case .missingDirectory:
            return AppLocalization.text("reader.error.missing_directory", "Offline chapter files are missing.")
        case .noImagesFound:
            return AppLocalization.text("reader.error.no_images", "No offline pages were found in this chapter.")
        case let .incompleteDownload(found, expected):
            return AppLocalization.format(
                "reader.error.incomplete_download",
                "Offline chapter is incomplete: %lld of %lld pages available.",
                Int64(found),
                Int64(expected)
            )
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingDirectory, .noImagesFound:
            return AppLocalization.text("reader.error.redownload_suggestion", "Re-download this chapter before opening it offline.")
        case .incompleteDownload:
            return AppLocalization.text("reader.error.delete_redownload_suggestion", "Delete the broken download and download the chapter again.")
        }
    }
}

@MainActor
@Observable
final class ReaderSession {
    private enum ReaderLoadConstants {
        static let initialBatchRadius = 1
        static let nearbyBatchRadius = 4
        static let translationBatchRadius = 1
    }

    let item: ComicSummary
    var chapterID: String
    var chapterTitle: String
    var localChapterDirectory: String?
    var initialPage: Int?
    let initialChapterSequence: [ComicChapter]?

    var imageRequests: [ImageRequest?] = []
    var totalPages = 0
    var resolvedPageCount = 0
    var chapterSequence: [ComicChapter] = []
    var currentChapterIndex: Int?
    var loading = false
    var isLoadingMore = false
    var loadingProgress: Double = 0
    var loadingMessage = "Loading..."
    var errorText = ""
    var offlineStatusText = ""

    var currentPage = 0
    var showControls = true
    var reloadNonce = 0

    var translationController = ReaderTranslationController()
    var progressTracker = ReaderProgressTracker()
    var pagePresentationStates: [Int: ReaderPagePresentationState] = [:]

    var translationEnabled: Bool {
        get { translationController.enabled }
        set { translationController.enabled = newValue }
    }

    var translationShowOriginal: Bool {
        get { translationController.showOriginal }
        set { translationController.showOriginal = newValue }
    }

    var translationBackendKind: ReaderTranslationBackendKind {
        get { translationController.backendKind }
        set { translationController.backendKind = newValue }
    }

    var translationKoharuBaseURL: String {
        get { translationController.koharuBaseURL }
        set { translationController.koharuBaseURL = newValue }
    }

    var translationRequestTimeoutSeconds: Int {
        get { translationController.requestTimeoutSeconds }
        set { translationController.requestTimeoutSeconds = newValue }
    }

    var translationKoharuLLM: ReaderKoharuLLMConfiguration {
        get { translationController.koharuLLM }
        set { translationController.koharuLLM = newValue }
    }

    var translationSourceLanguage: ReaderTranslationLanguage? {
        get { translationController.sourceLanguage }
        set { translationController.sourceLanguage = newValue }
    }

    var translationTargetLanguage: ReaderTranslationLanguage {
        get { translationController.targetLanguage }
        set { translationController.targetLanguage = newValue }
    }

    var translationPageStates: [Int: ReaderPageTranslationStatus] {
        get { translationController.pageStates }
        set { translationController.pageStates = newValue }
    }

    var translationPageDocuments: [Int: ReaderPageTranslationDocument] {
        get { translationController.pageDocuments }
        set { translationController.pageDocuments = newValue }
    }

    var translationErrorText: [Int: String] {
        get { translationController.errorText }
        set { translationController.errorText = newValue }
    }

    var translationUnsupportedReason: String {
        get { translationController.unsupportedReason }
        set { translationController.unsupportedReason = newValue }
    }

    var translationPageBlocks: [Int: [ReaderTextBlock]] {
        translationController.pageBlocks
    }

    var translationRenderedAssets: [Int: ReaderRenderedPageAsset] {
        translationController.renderedAssets
    }

    private var loadGeneration = 0
    private var pendingPageIndexes: Set<Int> = []
    private var readerPageRequestSessionHandle: ReaderPageRequestSessionHandle?
    private var backgroundLoadTask: Task<Void, Never>?

    init(
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        localChapterDirectory: String? = nil,
        initialPage: Int? = nil,
        chapterSequence: [ComicChapter]? = nil
    ) {
        self.item = item
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.localChapterDirectory = localChapterDirectory
        self.initialPage = initialPage
        self.initialChapterSequence = chapterSequence
    }

    var isOfflineReading: Bool {
        localChapterDirectory != nil
    }

    var previousChapter: ComicChapter? {
        guard let currentChapterIndex, currentChapterIndex > 0 else { return nil }
        return chapterSequence[currentChapterIndex - 1]
    }

    var nextChapter: ComicChapter? {
        guard let currentChapterIndex, currentChapterIndex + 1 < chapterSequence.count else { return nil }
        return chapterSequence[currentChapterIndex + 1]
    }

    var canRenderReader: Bool {
        guard totalPages > 0 else { return false }
        return imageRequests.indices.contains(currentPage) && imageRequests[currentPage] != nil
    }

    func displayedPageIndex(readerMode: ReaderMode) -> Int {
        guard totalPages > 0 else { return 0 }
        if readerMode == .rtl {
            return totalPages - currentPage
        }
        return currentPage + 1
    }

    func load(using vm: ReaderViewModel, readerMode: ReaderMode) async {
        loadGeneration += 1
        let generation = loadGeneration
        backgroundLoadTask?.cancel()
        backgroundLoadTask = nil
        await disposeReaderPageRequestSession(using: vm)
        resetChapterLoadState()

        loading = true
        loadingProgress = 0.05
        loadingMessage = AppLocalization.text("reader.loading.chapter", "Loading chapter...")
        errorText = ""
        offlineStatusText = isOfflineReading ? AppLocalization.text("reader.status.offline.loading", "Opening downloaded chapter") : ""
        readerDebugLog("load start: comicID=\(item.id), chapterID=\(chapterID)", level: .info)

        do {
            if let localChapterDirectory {
                let localRequests = try await Task.detached(priority: .userInitiated) {
                    try Self.scanLocalImages(from: localChapterDirectory)
                }.value
                guard generation == loadGeneration, !Task.isCancelled else { return }
                applyLoadedRequests(localRequests)
                currentPage = preferredInitialPageIndex(total: totalPages, readerMode: readerMode)
                if readerMode == .vertical {
                }
                loadingProgress = 1
                loadingMessage = AppLocalization.text("reader.loading.done", "Done")
                offlineStatusText = AppLocalization.format("reader.status.offline.ready", "%lld pages offline", Int64(totalPages))
                loading = false
                readerDebugLog("load local success: imageRequests=\(totalPages), path=\(localChapterDirectory)", level: .info)
                return
            }

            loadingProgress = 0.2
            loadingMessage = AppLocalization.text("reader.loading.resolving_requests", "Resolving image requests...")
            let prepared = try await vm.prepareReaderPageRequestSession(item, chapterID: chapterID)
            guard generation == loadGeneration, !Task.isCancelled else {
                await vm.disposeReaderPageRequestSession(prepared.handle, item: item)
                return
            }

            if prepared.totalPages <= 0 {
                await vm.disposeReaderPageRequestSession(prepared.handle, item: item)
                try await loadRemoteChapterFallback(using: vm, generation: generation, readerMode: readerMode)
                return
            }

            readerPageRequestSessionHandle = prepared.handle
            totalPages = prepared.totalPages
            imageRequests = Array(repeating: nil, count: prepared.totalPages)
            currentPage = preferredInitialPageIndex(total: totalPages, readerMode: readerMode)

            loadingProgress = 0.55
            loadingMessage = AppLocalization.text("reader.loading.preparing_reader", "Preparing reader...")
            try await resolvePageIndexes(
                prioritizedIndexes(around: currentPage, radius: ReaderLoadConstants.initialBatchRadius),
                using: vm,
                generation: generation
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }

            if !canRenderReader {
                await disposeReaderPageRequestSession(using: vm)
                try await loadRemoteChapterFallback(using: vm, generation: generation, readerMode: readerMode)
                return
            }

            loadingProgress = 1
            loadingMessage = AppLocalization.text("reader.loading.done", "Done")
            loading = false
            readerDebugLog("load progressive success: totalPages=\(totalPages), resolved=\(resolvedPageCount)", level: .info)
            queueBackgroundResolution(using: vm, readerMode: readerMode)
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            errorText = error.localizedDescription
            if let recovery = (error as? LocalizedError)?.recoverySuggestion {
                errorText += "\n\(recovery)"
            }
            loading = false
            readerDebugLog("load failed: \(error.localizedDescription)", level: .error)
        }
    }

    func loadChapterSequenceIfNeeded(using vm: ReaderViewModel) async {
        if !chapterSequence.isEmpty {
            syncCurrentChapterIndex()
            return
        }

        if let initialChapterSequence, !initialChapterSequence.isEmpty {
            chapterSequence = initialChapterSequence
            syncCurrentChapterIndex()
            return
        }

        do {
            let detail = try await vm.loadComicDetail(item)
            chapterSequence = detail.chapters
            syncCurrentChapterIndex()
        } catch {
            readerDebugLog("loadChapterSequenceIfNeeded failed: \(error.localizedDescription)", level: .warn)
        }
    }

    func loadAdjacentChapter(
        step: Int,
        using vm: ReaderViewModel,
        library: LibraryViewModel,
        readerMode: ReaderMode
    ) async {
        guard step != 0 else { return }
        if chapterSequence.isEmpty {
            await loadChapterSequenceIfNeeded(using: vm)
            guard !chapterSequence.isEmpty else { return }
        }
        guard let currentChapterIndex else { return }

        let nextIndex = currentChapterIndex + step
        guard chapterSequence.indices.contains(nextIndex) else { return }

        let chapter = chapterSequence[nextIndex]
        await disposeReaderPageRequestSession(using: vm)
        chapterID = chapter.id
        chapterTitle = chapter.title.isEmpty ? chapter.id : chapter.title
        localChapterDirectory = library.offlineChapter(
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapter.id
        ).flatMap { $0.integrityStatus == .complete ? $0 : nil }?.directoryPath
        initialPage = 1
        syncCurrentChapterIndex()
        await load(using: vm, readerMode: readerMode)
    }

    func resolvePagesAroundCurrentPage(using vm: ReaderViewModel, readerMode: ReaderMode) {
        guard !loading else { return }
        guard readerPageRequestSessionHandle != nil else { return }
        queueBackgroundResolution(using: vm, readerMode: readerMode)
    }

    func applyTranslationPreferences(_ preferences: ReaderTranslationPreferences) {
        translationController.applyPreferences(preferences)
    }

    func applyTranslationPreferences(
        enabled: Bool,
        backendKind: ReaderTranslationBackendKind,
        koharuBaseURL: String,
        requestTimeoutSeconds: Int,
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage,
        koharuLLM: ReaderKoharuLLMConfiguration = ReaderKoharuLLMConfiguration()
    ) {
        applyTranslationPreferences(
            ReaderTranslationPreferences(
                enabled: enabled,
                backendConfiguration: ReaderPageTranslationBackendConfiguration(
                    kind: backendKind,
                    koharuBaseURL: koharuBaseURL,
                    requestTimeoutSeconds: requestTimeoutSeconds,
                    koharuLLM: koharuLLM
                ),
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        )
    }

    func toggleTranslationShowOriginal() {
        translationController.toggleShowOriginal()
    }

    func translationStatus(for pageIndex: Int) -> ReaderPageTranslationStatus {
        translationController.status(for: pageIndex)
    }

    func translationBlocks(for pageIndex: Int) -> [ReaderTextBlock] {
        translationController.blocks(for: pageIndex)
    }

    func translationError(for pageIndex: Int) -> String? {
        translationController.error(for: pageIndex)
    }

    func translateCurrentPage(using vm: ReaderViewModel) {
        guard translationEnabled else { return }
        guard imageRequests.indices.contains(currentPage), let request = imageRequests[currentPage] else { return }
        let pageIndex = currentPage
        let sourceLanguage = translationSourceLanguage
        let targetLanguage = translationTargetLanguage
        translationController.startTranslation(pageIndex: pageIndex) { [weak self] generation in
            await self?.translatePage(
                at: pageIndex,
                request: request,
                using: vm,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                generation: generation
            )
        }
    }

    func nextPage(readerMode: ReaderMode, animatePageTransitions: Bool, reduceMotion: Bool) {
        guard totalPages > 0 else { return }
        if readerMode == .vertical {
            let target = min(totalPages - 1, currentPage + 1)
            jumpToPage(target, readerMode: readerMode)
            return
        }
        let move = {
            if readerMode == .rtl {
                self.currentPage = max(0, self.currentPage - 1)
            } else {
                self.currentPage = min(self.totalPages - 1, self.currentPage + 1)
            }
        }
        if animatePageTransitions && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.15)) { move() }
        } else {
            move()
        }
    }

    func previousPage(readerMode: ReaderMode, animatePageTransitions: Bool, reduceMotion: Bool) {
        guard totalPages > 0 else { return }
        if readerMode == .vertical {
            let target = max(0, currentPage - 1)
            jumpToPage(target, readerMode: readerMode)
            return
        }
        let move = {
            if readerMode == .rtl {
                self.currentPage = min(self.totalPages - 1, self.currentPage + 1)
            } else {
                self.currentPage = max(0, self.currentPage - 1)
            }
        }
        if animatePageTransitions && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.15)) { move() }
        } else {
            move()
        }
    }

    func reloadCurrentPage() {
        reloadNonce += 1
        translationController.reloadPage(currentPage)
    }

    func jumpToPage(_ target: Int, readerMode: ReaderMode) {
        guard totalPages > 0 else { return }
        if readerMode == .vertical {
            currentPage = max(0, min(totalPages - 1, target))
            return
        }
        let clamped = max(0, min(totalPages - 1, target))
        currentPage = clamped
    }

    func persistHistory(using library: LibraryViewModel, readerMode: ReaderMode) async {
        guard let payload = progressTracker.historyPayload(
            item: item,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            totalPages: totalPages,
            canRenderReader: canRenderReader,
            displayedPage: displayedPageIndex(readerMode: readerMode)
        ) else {
            return
        }

        await library.recordReadingHistory(
            comicID: payload.comicID,
            sourceKey: payload.sourceKey,
            title: payload.title,
            coverURL: payload.coverURL,
            author: payload.author,
            tags: payload.tags,
            chapterID: payload.chapterID,
            chapter: payload.chapter,
            page: payload.page
        )
    }

    func markVisible() {
        progressTracker.markVisible()
    }

    func finishReadingSession(using library: LibraryViewModel) {
        guard let duration = progressTracker.finishReadingSession(totalPages: totalPages) else { return }
        library.addReadingDuration(duration)
    }

    func completedChapterProgress(readerMode: ReaderMode) -> (progress: Int, status: TrackerReadingStatus)? {
        let lastPageIndex = lastAbsolutePageIndex(readerMode: readerMode)
        let lastPageIsResolved = imageRequests.indices.contains(lastPageIndex) && imageRequests[lastPageIndex] != nil
        return progressTracker.completedChapterProgress(
            totalPages: totalPages,
            resolvedPageCount: resolvedPageCount,
            lastDisplayedPage: displayedPageIndex(readerMode: readerMode),
            lastPageIsResolved: lastPageIsResolved,
            currentChapterIndex: currentChapterIndex,
            chapterCount: chapterSequence.count
        )
    }

    func close(using vm: ReaderViewModel) async {
        loadGeneration += 1
        translationController.invalidate(resetCachedState: false)
        backgroundLoadTask?.cancel()
        backgroundLoadTask = nil
        await disposeReaderPageRequestSession(using: vm)
        pendingPageIndexes.removeAll()
        isLoadingMore = false
    }

    private func syncCurrentChapterIndex() {
        currentChapterIndex = chapterSequence.firstIndex(where: { $0.id == chapterID })
    }

    private func resetChapterLoadState() {
        imageRequests = []
        totalPages = 0
        resolvedPageCount = 0
        pendingPageIndexes.removeAll()
        isLoadingMore = false
        readerPageRequestSessionHandle = nil
        currentPage = 0
        translationController.invalidate(resetCachedState: true)
        pagePresentationStates.removeAll()
    }

    #if DEBUG
    func reloadReaderPresentationStateForTests() {
        resetChapterLoadState()
    }

    func translationGenerationForTests() -> Int {
        translationController.translationGenerationForTests()
    }

    func primeTranslationTaskForTests(pageIndex: Int = 0) {
        translationController.primeTranslationTaskForTests(pageIndex: pageIndex)
    }

    func translationTaskCountForTests() -> Int {
        translationController.translationTaskCountForTests()
    }
    #endif

    private func applyLoadedRequests(_ requests: [ImageRequest]) {
        imageRequests = requests.map(Optional.some)
        totalPages = requests.count
        resolvedPageCount = requests.count
    }

    private func prioritizedIndexes(around center: Int, radius: Int) -> [Int] {
        guard totalPages > 0 else { return [] }
        let clampedCenter = max(0, min(totalPages - 1, center))
        var ordered: [Int] = [clampedCenter]
        if radius > 0 {
            for step in 1...radius {
                let lower = clampedCenter - step
                if lower >= 0 {
                    ordered.append(lower)
                }
                let upper = clampedCenter + step
                if upper < totalPages {
                    ordered.append(upper)
                }
            }
        }
        return ordered
    }

    private func queueBackgroundResolution(using vm: ReaderViewModel, readerMode: ReaderMode) {
        backgroundLoadTask?.cancel()
        let generation = loadGeneration
        backgroundLoadTask = Task { [weak self] in
            await self?.resolveNearbyPages(using: vm, readerMode: readerMode, generation: generation)
        }
    }

    private func resolveNearbyPages(using vm: ReaderViewModel, readerMode: ReaderMode, generation: Int) async {
        do {
            let indexes = prioritizedIndexes(around: currentPage, radius: ReaderLoadConstants.nearbyBatchRadius)
            try await resolvePageIndexes(indexes, using: vm, generation: generation)
        } catch {
            guard generation == loadGeneration else { return }
            readerDebugLog("resolveNearbyPages failed: \(error.localizedDescription)", level: .warn)
        }
    }

    private func resolvePageIndexes(
        _ indexes: [Int],
        using vm: ReaderViewModel,
        generation: Int
    ) async throws {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        guard let handle = readerPageRequestSessionHandle else { return }

        var seen = Set<Int>()
        let unresolved = indexes.filter { idx in
            imageRequests.indices.contains(idx)
                && imageRequests[idx] == nil
                && !pendingPageIndexes.contains(idx)
                && seen.insert(idx).inserted
        }
        guard !unresolved.isEmpty else { return }

        pendingPageIndexes.formUnion(unresolved)
        isLoadingMore = !pendingPageIndexes.isEmpty
        defer {
            for index in unresolved {
                pendingPageIndexes.remove(index)
            }
            isLoadingMore = !pendingPageIndexes.isEmpty
        }

        let resolved = try await vm.resolveReaderPageRequestSession(
            handle,
            item: item,
            chapterID: chapterID,
            pageIndexes: unresolved
        )
        guard generation == loadGeneration, !Task.isCancelled else { return }
        for entry in resolved {
            guard imageRequests.indices.contains(entry.index) else { continue }
            if imageRequests[entry.index] == nil {
                resolvedPageCount += 1
            }
            imageRequests[entry.index] = entry.request
        }
    }

    private func translatePage(
        at pageIndex: Int,
        request: ImageRequest,
        using vm: ReaderViewModel,
        sourceLanguage: ReaderTranslationLanguage?,
        targetLanguage: ReaderTranslationLanguage,
        generation: Int
    ) async {
        guard translationController.isCurrentGeneration(generation), !Task.isCancelled else { return }

        let backendConfiguration = translationController.backendConfiguration

        do {
            let backend = try await vm.getReaderPageTranslationBackend(
                configuration: backendConfiguration
            )
            let record = try await backend.translatePage(
                item: item,
                chapterID: chapterID,
                pageIndex: pageIndex,
                request: request,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            guard translationController.isCurrentGeneration(generation), !Task.isCancelled else { return }
            translationController.recordSuccess(record, pageIndex: pageIndex)
            readerDebugLog(
                "translation ready: page=\(pageIndex), status=\(record.status.rawValue), blocks=\(record.blocks.count), source=\(sourceLanguage?.rawValue ?? "auto"), target=\(targetLanguage.rawValue)",
                level: .info
            )
        } catch {
            guard translationController.isCurrentGeneration(generation), !Task.isCancelled else { return }
            let message = error.localizedDescription
            let isUnsupported: Bool
            if case ReaderPageTranslationBackendConfigurationError.invalidKoharuBaseURL = error {
                isUnsupported = true
            } else {
                isUnsupported = false
            }
            translationController.recordFailure(message: message, pageIndex: pageIndex, isUnsupported: isUnsupported)
            if let backend = try? await vm.getReaderPageTranslationBackend(
                configuration: backendConfiguration
            ) {
                await backend.saveFailure(
                    item: item,
                    chapterID: chapterID,
                    pageIndex: pageIndex,
                    request: request,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    errorText: message
                )
            }
            readerDebugLog("translation failed: page=\(pageIndex), error=\(message)", level: .warn)
        }
    }

    private func loadRemoteChapterFallback(
        using vm: ReaderViewModel,
        generation: Int,
        readerMode: ReaderMode
    ) async throws {
        loadingProgress = 0.65
        loadingMessage = AppLocalization.text("reader.loading.fallback_direct_links", "Falling back to direct links...")
        var requests = try await vm.loadComicPageRequests(item, chapterID: chapterID)
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if requests.isEmpty {
            let links = try await vm.loadComicPages(item, chapterID: chapterID)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if links.isEmpty {
                throw ScriptEngineError.invalidResult("No image requests returned by source")
            }
            requests = links.map { link in
                ImageRequest(url: link, method: "GET", headers: [:], body: nil)
            }
        }
        applyLoadedRequests(requests)
        currentPage = preferredInitialPageIndex(total: totalPages, readerMode: readerMode)
        loadingProgress = 1
        loadingMessage = AppLocalization.text("reader.loading.done", "Done")
        loading = false
        readerDebugLog("load fallback success: totalPages=\(totalPages)", level: .warn)
    }

    private func disposeReaderPageRequestSession(using vm: ReaderViewModel) async {
        guard let handle = readerPageRequestSessionHandle else { return }
        readerPageRequestSessionHandle = nil
        await vm.disposeReaderPageRequestSession(handle, item: item)
    }

    private func lastAbsolutePageIndex(readerMode: ReaderMode) -> Int {
        guard totalPages > 0 else { return 0 }
        if readerMode == .rtl {
            return 0
        }
        return totalPages - 1
    }

    private nonisolated static func scanLocalImages(from directoryPath: String) throws -> [ImageRequest] {
        let url = URL(fileURLWithPath: directoryPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OfflineChapterLoadError.missingDirectory
        }

        let metadataURL = url.appendingPathComponent("metadata.json")
        var expectedPageCount: Int?
        if let data = try? Data(contentsOf: metadataURL),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let totalPages = payload["totalPages"] as? Int {
            expectedPageCount = totalPages
        }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )

        let supportedExt = Set(["jpg", "jpeg", "png", "webp", "avif", "gif", "heic", "heif", "bmp"])
        let imageFiles = files.filter { fileURL in
            let ext = fileURL.pathExtension.lowercased()
            guard supportedExt.contains(ext) else { return false }
            let isRegular = (try? fileURL.resourceValues(forKeys: Set(keys)).isRegularFile) ?? false
            return isRegular
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !imageFiles.isEmpty else {
            throw OfflineChapterLoadError.noImagesFound
        }
        if let expectedPageCount, imageFiles.count < expectedPageCount {
            throw OfflineChapterLoadError.incompleteDownload(found: imageFiles.count, expected: expectedPageCount)
        }
        return imageFiles.map { fileURL in
            ImageRequest(url: fileURL.absoluteString, method: "GET", headers: [:], body: nil)
        }
    }

    func preferredInitialPageIndex(total: Int, readerMode: ReaderMode) -> Int {
        guard total > 0 else { return 0 }
        let oneBased = max(1, initialPage ?? 1)
        let ltrIndex = min(total - 1, oneBased - 1)
        if readerMode == .rtl {
            return max(0, total - 1 - ltrIndex)
        }
        return ltrIndex
    }
}
