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
    let item: ComicSummary
    var chapterID: String
    var chapterTitle: String
    var localChapterDirectory: String?
    let initialPage: Int?
    let initialChapterSequence: [ComicChapter]?

    var imageRequests: [ImageRequest] = []
    var chapterSequence: [ComicChapter] = []
    var currentChapterIndex: Int?
    var loading = false
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

    func displayedPageIndex(readerMode: ReaderMode) -> Int {
        if readerMode == .rtl {
            return imageRequests.count - currentPage
        }
        return currentPage + 1
    }

    func load(using vm: ReaderViewModel, readerMode: ReaderMode) async {
        loading = true
        loadingProgress = 0.05
        loadingMessage = "Loading chapter..."
        readerDebugLog("load start: comicID=\(item.id), chapterID=\(chapterID)", level: .info)
        errorText = ""
        offlineStatusText = isOfflineReading ? "Offline" : ""
        do {
            if let localChapterDirectory {
                let localRequests = try loadLocalImageRequests(from: localChapterDirectory)
                imageRequests = localRequests
                loadingProgress = 0.9
                loadingMessage = "Loading local chapter..."
                currentPage = preferredInitialPageIndex(total: imageRequests.count, readerMode: readerMode)
                if readerMode == .vertical {
                    verticalScrollTarget = currentPage
                }
                loadingProgress = 1
                loadingMessage = "Done"
                offlineStatusText = "Offline • \(imageRequests.count) pages downloaded"
                readerDebugLog("load local success: imageRequests=\(imageRequests.count), path=\(localChapterDirectory)", level: .info)
                loading = false
                return
            }

            loadingProgress = 0.25
            loadingMessage = "Resolving image requests..."
            var requests = try await vm.loadComicPageRequests(item, chapterID: chapterID)
            if requests.isEmpty {
                loadingProgress = 0.45
                loadingMessage = "Retrying request resolution..."
                requests = try await vm.loadComicPageRequests(item, chapterID: chapterID)
            }
            if requests.isEmpty {
                loadingProgress = 0.65
                loadingMessage = "Falling back to direct links..."
                let links = try await vm.loadComicPages(item, chapterID: chapterID)
                if links.isEmpty {
                    throw ScriptEngineError.invalidResult("No image requests returned by source")
                }
                imageRequests = links.map { link in
                    ImageRequest(url: link, method: "GET", headers: [:], body: nil)
                }
            } else {
                imageRequests = requests
            }
            loadingProgress = 0.9
            loadingMessage = "Preparing reader..."
            currentPage = preferredInitialPageIndex(total: imageRequests.count, readerMode: readerMode)
            if readerMode == .vertical {
                verticalScrollTarget = currentPage
            }
            loadingProgress = 1
            loadingMessage = "Done"
            readerDebugLog("load success: imageRequests=\(imageRequests.count)", level: .info)
        } catch {
            errorText = error.localizedDescription
            if let recovery = (error as? LocalizedError)?.recoverySuggestion {
                errorText += "\n\(recovery)"
            }
            readerDebugLog("load failed: \(error.localizedDescription)", level: .error)
        }
        loading = false
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
        loading = true
        loadingProgress = 0.05
        loadingMessage = "Loading chapter..."
        chapterID = chapter.id
        chapterTitle = chapter.title.isEmpty ? chapter.id : chapter.title
        localChapterDirectory = library.offlineChapter(
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapter.id
        )?.directoryPath
        imageRequests = []
        errorText = ""
        currentPage = 0
        verticalScrollTarget = nil
        verticalPageFrames = [:]
        syncCurrentChapterIndex()
        await load(using: vm, readerMode: readerMode)
    }

    func nextPage(readerMode: ReaderMode, animatePageTransitions: Bool, reduceMotion: Bool) {
        guard !imageRequests.isEmpty else { return }
        if readerMode == .vertical {
            let target = min(imageRequests.count - 1, currentPage + 1)
            jumpToVerticalPage(target, readerMode: readerMode)
            return
        }
        let move = {
            if readerMode == .rtl {
                self.currentPage = max(0, self.currentPage - 1)
            } else {
                self.currentPage = min(self.imageRequests.count - 1, self.currentPage + 1)
            }
        }
        if animatePageTransitions && !reduceMotion {
            withAnimation(.easeInOut(duration: 0.15)) { move() }
        } else {
            move()
        }
    }

    func previousPage(readerMode: ReaderMode, animatePageTransitions: Bool, reduceMotion: Bool) {
        guard !imageRequests.isEmpty else { return }
        if readerMode == .vertical {
            let target = max(0, currentPage - 1)
            jumpToVerticalPage(target, readerMode: readerMode)
            return
        }
        let move = {
            if readerMode == .rtl {
                self.currentPage = min(self.imageRequests.count - 1, self.currentPage + 1)
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
        guard !imageRequests.isEmpty else { return }
        let clamped = max(0, min(imageRequests.count - 1, target))
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
        guard !loading else { return }
        guard !imageRequests.isEmpty else { return }
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
        guard !imageRequests.isEmpty else { return }
        library.addReadingDuration(Date().timeIntervalSince(readingSessionStartedAt))
    }

    private func syncCurrentChapterIndex() {
        currentChapterIndex = chapterSequence.firstIndex(where: { $0.id == chapterID })
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

    private func preferredInitialPageIndex(total: Int, readerMode: ReaderMode) -> Int {
        guard total > 0 else { return 0 }
        let oneBased = max(1, initialPage ?? 1)
        let ltrIndex = min(total - 1, oneBased - 1)
        if readerMode == .rtl {
            return max(0, total - 1 - ltrIndex)
        }
        return ltrIndex
    }
}
