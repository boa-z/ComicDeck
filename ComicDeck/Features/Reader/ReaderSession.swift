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
            return "Offline chapter files are missing."
        case .noImagesFound:
            return "No offline pages were found in this chapter."
        case let .incompleteDownload(found, expected):
            return "Offline chapter is incomplete: \(found) of \(expected) pages available."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingDirectory, .noImagesFound:
            return "Re-download this chapter before opening it offline."
        case .incompleteDownload:
            return "Delete the broken download and download the chapter again."
        }
    }
}

@MainActor
@Observable
final class ReaderSession {
    private enum ReaderLoadConstants {
        static let initialBatchRadius = 1
        static let nearbyBatchRadius = 4
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
    var verticalPageFrames: [Int: CGRect] = [:]
    var verticalViewportHeight: CGFloat = 1
    var verticalScrollTarget: Int? = nil
    var verticalTrackingSuspendedUntil: Date = .distantPast

    private var readingSessionStartedAt: Date?
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
        loadingMessage = "Loading chapter..."
        errorText = ""
        offlineStatusText = isOfflineReading ? "Offline" : ""
        readerDebugLog("load start: comicID=\(item.id), chapterID=\(chapterID)", level: .info)

        do {
            if let localChapterDirectory {
                let localRequests = try loadLocalImageRequests(from: localChapterDirectory)
                guard generation == loadGeneration, !Task.isCancelled else { return }
                applyLoadedRequests(localRequests)
                currentPage = preferredInitialPageIndex(total: totalPages, readerMode: readerMode)
                if readerMode == .vertical {
                    verticalScrollTarget = currentPage
                }
                loadingProgress = 1
                loadingMessage = "Done"
                offlineStatusText = "Offline • \(totalPages) pages downloaded"
                loading = false
                readerDebugLog("load local success: imageRequests=\(totalPages), path=\(localChapterDirectory)", level: .info)
                return
            }

            loadingProgress = 0.2
            loadingMessage = "Resolving image requests..."
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
            if readerMode == .vertical {
                verticalScrollTarget = currentPage
            }

            loadingProgress = 0.55
            loadingMessage = "Preparing reader..."
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
            loadingMessage = "Done"
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
        )?.directoryPath
        initialPage = 1
        syncCurrentChapterIndex()
        await load(using: vm, readerMode: readerMode)
    }

    func resolvePagesAroundCurrentPage(using vm: ReaderViewModel, readerMode: ReaderMode) {
        guard !loading else { return }
        guard readerPageRequestSessionHandle != nil else { return }
        queueBackgroundResolution(using: vm, readerMode: readerMode)
    }

    func nextPage(readerMode: ReaderMode, animatePageTransitions: Bool, reduceMotion: Bool) {
        guard totalPages > 0 else { return }
        if readerMode == .vertical {
            let target = min(totalPages - 1, currentPage + 1)
            jumpToVerticalPage(target, readerMode: readerMode)
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
            jumpToVerticalPage(target, readerMode: readerMode)
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
    }

    func jumpToVerticalPage(_ target: Int, readerMode: ReaderMode) {
        guard readerMode == .vertical else { return }
        guard totalPages > 0 else { return }
        let clamped = max(0, min(totalPages - 1, target))
        currentPage = clamped
        verticalScrollTarget = clamped
    }

    func updateCurrentPageFromVerticalLayout(readerMode: ReaderMode) {
        guard readerMode == .vertical else { return }
        guard Date() >= verticalTrackingSuspendedUntil else { return }
        guard !verticalPageFrames.isEmpty else { return }
        let viewportMid = verticalViewportHeight * 0.5
        let best = verticalPageFrames.min { lhs, rhs in
            abs(lhs.value.midY - viewportMid) < abs(rhs.value.midY - viewportMid)
        }?.key
        guard let best else { return }
        if best != currentPage {
            currentPage = best
        }
    }

    func persistHistory(using library: LibraryViewModel, readerMode: ReaderMode) async {
        guard totalPages > 0 else { return }
        guard canRenderReader else { return }
        let chapterValue = chapterTitle.isEmpty ? chapterID : chapterTitle
        await library.recordReadingHistory(
            comicID: item.id,
            sourceKey: item.sourceKey,
            title: item.title,
            coverURL: item.coverURL,
            author: item.author,
            tags: item.tags,
            chapterID: chapterID,
            chapter: chapterValue,
            page: max(1, displayedPageIndex(readerMode: readerMode))
        )
    }

    func markVisible() {
        if readingSessionStartedAt == nil {
            readingSessionStartedAt = Date()
        }
    }

    func finishReadingSession(using library: LibraryViewModel) {
        guard let readingSessionStartedAt else { return }
        self.readingSessionStartedAt = nil
        guard totalPages > 0 else { return }
        library.addReadingDuration(Date().timeIntervalSince(readingSessionStartedAt))
    }

    func completedChapterProgress(readerMode: ReaderMode) -> (progress: Int, status: TrackerReadingStatus)? {
        guard totalPages > 0 else { return nil }
        guard resolvedPageCount >= totalPages else { return nil }
        guard imageRequests.indices.contains(lastAbsolutePageIndex(readerMode: readerMode)) else { return nil }
        guard imageRequests[lastAbsolutePageIndex(readerMode: readerMode)] != nil else { return nil }
        guard displayedPageIndex(readerMode: readerMode) >= totalPages else { return nil }
        guard let currentChapterIndex else { return nil }
        let progress = currentChapterIndex + 1
        let status: TrackerReadingStatus = progress >= chapterSequence.count ? .completed : .current
        return (progress, status)
    }

    func close(using vm: ReaderViewModel) async {
        loadGeneration += 1
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
        verticalPageFrames = [:]
        verticalScrollTarget = nil
        currentPage = 0
    }

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

        let unresolved = Array(Set(indexes))
            .filter { imageRequests.indices.contains($0) }
            .filter { imageRequests[$0] == nil }
            .filter { !pendingPageIndexes.contains($0) }
            .sorted()
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

    private func loadRemoteChapterFallback(
        using vm: ReaderViewModel,
        generation: Int,
        readerMode: ReaderMode
    ) async throws {
        loadingProgress = 0.65
        loadingMessage = "Falling back to direct links..."
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
        if readerMode == .vertical {
            verticalScrollTarget = currentPage
        }
        loadingProgress = 1
        loadingMessage = "Done"
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

    private func loadLocalImageRequests(from directoryPath: String) throws -> [ImageRequest] {
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
