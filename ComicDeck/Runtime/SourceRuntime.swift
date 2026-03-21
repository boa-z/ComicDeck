import Foundation
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

@MainActor
final class SourceRuntime {
    private let sourceManager: SourceManagerViewModel
    private let library: LibraryViewModel
    private let login: LoginViewModel
    private let engineExecutionQueue: DispatchQueue

    init(
        sourceManager: SourceManagerViewModel,
        library: LibraryViewModel,
        login: LoginViewModel,
        engineExecutionQueue: DispatchQueue
    ) {
        self.sourceManager = sourceManager
        self.library = library
        self.login = login
        self.engineExecutionQueue = engineExecutionQueue
    }

    func executeSearch(
        sourceKey: String,
        keyword: String,
        options: [String],
        page: Int,
        nextToken: String?
    ) async throws -> ReaderViewModel.SearchExecutionResponse {
        let (source, engine) = try await sourceEngine(sourceKey: sourceKey)
        vmDebugLog("search start: key=\(source.key), keyword=\(keyword)", level: .info)
        let pageResult = try await withTimeout(seconds: 25) {
            try await self.runEngine {
                try engine.searchSourcePage(
                    keyword: keyword,
                    sourceKey: source.key,
                    options: options,
                    page: max(1, page),
                    nextToken: nextToken
                )
            }
        }
        vmDebugLog("search ok: key=\(source.key), page=\(page), count=\(pageResult.comics.count)", level: .info)
        return ReaderViewModel.SearchExecutionResponse(sourceName: source.name, pageResult: pageResult)
    }

    func loadCategoryPageProfile(sourceKey: String) async throws -> CategoryPageProfile {
        let (_, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 25) {
            try await self.runEngine {
                try engine.getCategoryPageProfile()
            }
        }
    }

    func loadExplorePages(sourceKey: String) async throws -> [ExplorePageItem] {
        let (_, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 25) {
            try await self.runEngine {
                try engine.getExplorePages()
            }
        }
    }

    func loadExploreComicsPage(
        sourceKey: String,
        pageIndex: Int,
        page: Int = 1,
        nextToken: String?
    ) async throws -> ComicPageResult {
        let (source, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 35) {
            try await self.runEngine {
                try engine.loadExploreComicsPage(
                    sourceKey: source.key,
                    pageIndex: max(0, pageIndex),
                    page: max(1, page),
                    nextToken: nextToken
                )
            }
        }
    }

    func loadExploreMultiPart(sourceKey: String, pageIndex: Int) async throws -> [ExplorePartData] {
        let (source, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 35) {
            try await self.runEngine {
                try engine.loadExploreMultiPart(sourceKey: source.key, pageIndex: max(0, pageIndex))
            }
        }
    }

    func loadExploreMixed(sourceKey: String, pageIndex: Int, page: Int = 1) async throws -> ExploreMixedPageResult {
        let (source, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 35) {
            try await self.runEngine {
                try engine.loadExploreMixed(
                    sourceKey: source.key,
                    pageIndex: max(0, pageIndex),
                    page: max(1, page)
                )
            }
        }
    }

    func loadCategoryComicsOptionGroups(sourceKey: String, category: String, param: String?) async throws -> [CategoryComicsOptionGroup] {
        let (_, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 25) {
            try await self.runEngine {
                try engine.getCategoryComicsOptionGroups(category: category, param: param)
            }
        }
    }

    func loadCategoryRankingProfile(sourceKey: String) async throws -> CategoryRankingProfile {
        let (_, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 25) {
            try await self.runEngine {
                try engine.getCategoryRankingProfile()
            }
        }
    }

    func loadCategoryComics(
        sourceKey: String,
        category: String,
        param: String?,
        options: [String],
        page: Int = 1,
        nextToken: String?
    ) async throws -> CategoryComicsPage {
        let (source, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 30) {
            try await self.runEngine {
                try engine.loadCategoryComics(
                    sourceKey: source.key,
                    category: category,
                    param: param,
                    options: options,
                    page: max(1, page),
                    nextToken: nextToken
                )
            }
        }
    }

    func loadCategoryRanking(
        sourceKey: String,
        option: String,
        page: Int = 1,
        nextToken: String?
    ) async throws -> CategoryComicsPage {
        let (source, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 30) {
            try await self.runEngine {
                try engine.loadCategoryRanking(
                    sourceKey: source.key,
                    option: option,
                    page: max(1, page),
                    nextToken: nextToken
                )
            }
        }
    }

    func loadSourceCapabilityProfile(sourceKey: String) async throws -> SourceCapabilityProfile {
        let (_, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 20) {
            try await self.runEngine {
                try engine.getSourceCapabilityProfile()
            }
        }
    }

    func loadSourceSettings(sourceKey: String) async throws -> [SourceSettingDefinition] {
        let (_, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 20) {
            try await self.runEngine {
                try engine.getSourceSettings()
            }
        }
    }

    func saveSourceSetting(sourceKey: String, key: String, value: Any) async throws {
        let (_, engine) = try await sourceEngine(sourceKey: sourceKey)
        try await withTimeout(seconds: 20) {
            try await self.runEngine {
                try engine.saveSourceSetting(key: key, value: value)
            }
        }
    }

    func loadComicDetail(_ item: ComicSummary) async throws -> ComicDetail {
        let (source, engine) = try await sourceEngine(item: item)
        vmDebugLog("loadComicDetail: key=\(source.key), comicID=\(item.id)", level: .info)
        do {
            return try await runEngine {
                try engine.loadComicInfo(comicID: item.id)
            }
        } catch {
            vmDebugLog("loadComicDetail retry: \(error.localizedDescription)", level: .warn)
            do {
                return try await runEngine {
                    try engine.loadComicInfo(comicID: item.id)
                }
            } catch {
                if let fallback = offlineComicDetail(for: item) {
                    vmDebugLog("loadComicDetail offline fallback: comicID=\(item.id), chapters=\(fallback.chapters.count)", level: .warn)
                    return fallback
                }
                throw error
            }
        }
    }

    func loadComicPages(_ item: ComicSummary, chapterID: String) async throws -> [String] {
        let (source, engine) = try await sourceEngine(item: item)
        vmDebugLog("loadComicPages: key=\(source.key), comicID=\(item.id), chapter=\(chapterID)", level: .info)
        return try await runEngine {
            try engine.loadComicEp(comicID: item.id, chapterID: chapterID)
        }
    }

    func loadComicPageRequests(_ item: ComicSummary, chapterID: String) async throws -> [ImageRequest] {
        let (source, engine) = try await sourceEngine(item: item)
        vmDebugLog("loadComicPageRequests: key=\(source.key), comicID=\(item.id), chapter=\(chapterID)", level: .info)
        return try await runEngine {
            try engine.loadComicEpRequests(comicID: item.id, chapterID: chapterID)
        }
    }

    func prepareReaderPageRequestSession(_ item: ComicSummary, chapterID: String) async throws -> ReaderPageRequestSessionPreparation {
        let (source, engine) = try await sourceEngine(item: item)
        vmDebugLog("prepareReaderPageRequestSession: key=\(source.key), comicID=\(item.id), chapter=\(chapterID)", level: .info)
        return try await runEngine {
            try engine.prepareReaderPageRequestSession(comicID: item.id, chapterID: chapterID)
        }
    }

    func resolveReaderPageRequestSession(
        _ handle: ReaderPageRequestSessionHandle,
        item: ComicSummary,
        chapterID: String,
        pageIndexes: [Int]
    ) async throws -> [IndexedImageRequest] {
        let (source, engine) = try await sourceEngine(item: item)
        vmDebugLog(
            "resolveReaderPageRequestSession: key=\(source.key), comicID=\(item.id), chapter=\(chapterID), indexes=\(pageIndexes.count)",
            level: .info
        )
        return try await runEngine {
            try engine.resolveReaderPageRequestSession(handle, pageIndexes: pageIndexes)
        }
    }

    func disposeReaderPageRequestSession(_ handle: ReaderPageRequestSessionHandle, item: ComicSummary) async {
        guard let (source, engine) = try? await sourceEngine(item: item) else { return }
        vmDebugLog("disposeReaderPageRequestSession: key=\(source.key), comicID=\(item.id), session=\(handle.id)", level: .info)
        do {
            try await runEngine {
                engine.disposeReaderPageRequestSession(handle)
            }
        } catch {
            vmDebugLog("disposeReaderPageRequestSession failed: \(error.localizedDescription)", level: .warn)
        }
    }

    func loadSourceFavoriteFolders(_ item: ComicSummary) async throws -> FavoriteFolderListing {
        let (_, engine) = try await sourceEngine(item: item)
        return try await runEngine {
            try engine.loadFavoriteFolders(comicID: item.id)
        }
    }

    func loadSourceFavoriteFolders(sourceKey: String) async throws -> FavoriteFolderListing {
        let (_, engine) = try await sourceEngine(sourceKey: sourceKey)
        return try await withTimeout(seconds: 40) {
            try await self.runEngine {
                try engine.loadFavoriteFolders(comicID: nil)
            }
        }
    }

    func loadSourceFavoriteComics(sourceKey: String, page: Int = 1, folderID: String? = nil) async throws -> [ComicSummary] {
        let paged = try await loadSourceFavoriteComicsPage(sourceKey: sourceKey, page: page, folderID: folderID, nextToken: nil)
        return paged.comics
    }

    func loadSourceFavoriteComicsPage(
        sourceKey: String,
        page: Int = 1,
        folderID: String? = nil,
        nextToken: String?
    ) async throws -> ComicPageResult {
        let (source, engine) = try await sourceEngine(sourceKey: sourceKey)
        do {
            return try await withTimeout(seconds: 45) {
                try await self.runEngine {
                    try engine.loadFavoriteComicsPage(
                        sourceKey: source.key,
                        page: max(1, page),
                        folderID: folderID,
                        nextToken: nextToken
                    )
                }
            }
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("login expired") || message.contains("invalid token") || message.contains("401") {
                login.currentSourceIsLogged = false
                login.currentSourceLoginStateLabel = "Logged Out"
            }
            throw error
        }
    }

    func toggleSourceFavorite(
        _ item: ComicSummary,
        detail: ComicDetail,
        folderID: String? = nil,
        isAdding: Bool? = nil
    ) async throws -> ComicDetail {
        let (_, engine) = try await sourceEngine(item: item)
        let next = isAdding ?? !(detail.isFavorite ?? false)
        _ = try await runEngine {
            try engine.setFavoriteStatus(comicID: item.id, isAdding: next, favoriteId: detail.favoriteId, folderID: folderID)
        }
        return try await runEngine {
            try engine.loadComicInfo(comicID: item.id)
        }
    }

    func setSourceFavorite(
        _ item: ComicSummary,
        favoriteId: String? = nil,
        folderID: String? = nil,
        isAdding: Bool
    ) async throws {
        let (_, engine) = try await sourceEngine(item: item)
        _ = try await runEngine {
            try engine.setFavoriteStatus(
                comicID: item.id,
                isAdding: isAdding,
                favoriteId: favoriteId,
                folderID: folderID
            )
        }
    }

    func getComicCommentCapabilities(_ item: ComicSummary) async throws -> ComicCommentCapabilities {
        let (_, engine) = try await sourceEngine(item: item)
        return try await withTimeout(seconds: 20) {
            try await self.runEngine {
                try engine.getComicCommentCapabilities()
            }
        }
    }

    func loadComicComments(
        _ item: ComicSummary,
        detail: ComicDetail,
        page: Int = 1,
        replyTo: String? = nil
    ) async throws -> ComicCommentsPage {
        let (_, engine) = try await sourceEngine(item: item)
        return try await withTimeout(seconds: 45) {
            try await self.runEngine {
                try engine.loadComicComments(
                    comicID: item.id,
                    subID: detail.subID,
                    page: max(1, page),
                    replyTo: replyTo
                )
            }
        }
    }

    func sendComicComment(
        _ item: ComicSummary,
        detail: ComicDetail,
        content: String,
        replyTo: String? = nil
    ) async throws {
        let (_, engine) = try await sourceEngine(item: item)
        try await withTimeout(seconds: 30) {
            try await self.runEngine {
                try engine.sendComicComment(
                    comicID: item.id,
                    subID: detail.subID,
                    content: content,
                    replyTo: replyTo
                )
            }
        }
    }

    func likeComicComment(
        _ item: ComicSummary,
        detail: ComicDetail,
        commentID: String,
        isLiking: Bool
    ) async throws -> Int? {
        let (_, engine) = try await sourceEngine(item: item)
        return try await withTimeout(seconds: 20) {
            try await self.runEngine {
                try engine.likeComicComment(
                    comicID: item.id,
                    subID: detail.subID,
                    commentID: commentID,
                    isLiking: isLiking
                )
            }
        }
    }

    func voteComicComment(
        _ item: ComicSummary,
        detail: ComicDetail,
        commentID: String,
        isUp: Bool,
        isCancel: Bool
    ) async throws -> Int? {
        let (_, engine) = try await sourceEngine(item: item)
        return try await withTimeout(seconds: 20) {
            try await self.runEngine {
                try engine.voteComicComment(
                    comicID: item.id,
                    subID: detail.subID,
                    commentID: commentID,
                    isUp: isUp,
                    isCancel: isCancel
                )
            }
        }
    }

    func resolveComicTagClick(_ item: ComicSummary, namespace: String, tag: String) async throws -> CategoryJumpTarget {
        let (_, engine) = try await sourceEngine(item: item)
        return try await withTimeout(seconds: 20) {
            try await self.runEngine {
                try engine.resolveComicTagClick(namespace: namespace, tag: tag)
            }
        }
    }

    func enqueueChapterDownload(
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        comicDescription: String? = nil
    ) async -> String {
        do {
            let requests = try await resolveDownloadRequests(item: item, chapterID: chapterID)
            await library.enqueueChapterDownload(
                item: item,
                chapterID: chapterID,
                chapterTitle: chapterTitle,
                comicDescription: comicDescription,
                requests: requests
            )
            var message = library.status
#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
            if #available(iOS 16.1, *), !ActivityAuthorizationInfo().areActivitiesEnabled {
                message = "Download queued. Live Activities is disabled in system settings."
            }
#endif
            return message
        } catch {
            return "Queue download failed: \(error.localizedDescription)"
        }
    }

    private func sourceEngine(sourceKey: String) async throws -> (InstalledSource, ComicSourceScriptEngine) {
        let source = try installedSource(for: sourceKey)
        let engine = try await sourceManager.getOrCreateEngine(for: source, runEngine: { [weak self] work in
            guard let self else { throw ScriptEngineError.buildContextFailed }
            return try await self.runEngine(work)
        })
        return (source, engine)
    }

    private func sourceEngine(item: ComicSummary) async throws -> (InstalledSource, ComicSourceScriptEngine) {
        try await sourceEngine(sourceKey: item.sourceKey)
    }

    private func installedSource(for sourceKey: String) throws -> InstalledSource {
        guard let source = sourceManager.installedSources.first(where: { $0.key == sourceKey }) else {
            throw ScriptEngineError.invalidResult("source not installed: \(sourceKey)")
        }
        return source
    }

    private func resolveDownloadRequests(item: ComicSummary, chapterID: String) async throws -> [ImageRequest] {
        let requestList = try await loadComicPageRequests(item, chapterID: chapterID)
        if !requestList.isEmpty { return requestList }
        let links = try await loadComicPages(item, chapterID: chapterID)
        return links.map { ImageRequest(url: $0, method: "GET", headers: [:], body: nil) }
    }

    private func offlineComicDetail(for item: ComicSummary) -> ComicDetail? {
        let chapters = library.offlineChapters
            .filter {
                $0.sourceKey == item.sourceKey &&
                $0.comicID == item.id
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                if lhs.chapterTitle != rhs.chapterTitle { return lhs.chapterTitle.localizedCompare(rhs.chapterTitle) == .orderedAscending }
                return lhs.chapterID.localizedCompare(rhs.chapterID) == .orderedAscending
            }
            .map { chapter in
                ComicChapter(
                    id: chapter.chapterID,
                    title: chapter.chapterTitle.isEmpty ? chapter.chapterID : chapter.chapterTitle
                )
            }
        guard !chapters.isEmpty else { return nil }
        return ComicDetail(
            title: item.title,
            cover: item.coverURL,
            description: chapters.first.flatMap { completed in
                library.offlineChapters.first {
                    $0.sourceKey == item.sourceKey &&
                    $0.comicID == item.id &&
                    $0.chapterID == completed.id
                }?.comicDescription
            } ?? "Offline mode: loaded from downloaded chapters.",
            comicURL: nil,
            subID: nil,
            tags: [],
            isFavorite: nil,
            favoriteId: nil,
            chapters: chapters,
            commentsCount: nil,
            comments: []
        )
    }

    private func runEngine<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            engineExecutionQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func withTimeout<T>(seconds: UInt64, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw ScriptEngineError.timeout("operation timeout (\(seconds)s)")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
