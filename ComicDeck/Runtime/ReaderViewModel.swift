import Foundation
import Observation

enum VMLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
func vmDebugLog(_ message: String, level: VMLogLevel = .debug) {
    guard RuntimeDebugConsole.isEnabled else { return }
    let line = "[SourceRuntime][\(level.rawValue)][VM] \(message)"
    NSLog("%@", line)
    RuntimeDebugConsole.shared.append(line)
}

/// Central coordinator ViewModel. Owns infrastructure (core, stores, queues)
/// and delegates domain responsibilities to child ViewModels:
/// - `SourceManagerViewModel` — source install/update/select
/// - `LibraryViewModel` — favorites/history/downloads
/// - `LoginViewModel` — login flows and session state
@MainActor
@Observable
final class ReaderViewModel {
    struct SearchExecutionResponse {
        let sourceName: String
        let pageResult: ComicPageResult
    }

    // MARK: - Child ViewModels
    var sourceManager = SourceManagerViewModel()
    var library = LibraryViewModel()
    var login = LoginViewModel()
    var tracker = TrackerViewModel()

    // MARK: - Private Infrastructure
    private let engineExecutionQueue = DispatchQueue(label: "source.runtime.engine.execution", qos: .userInitiated)
    private var core: CoreBootstrap?
    private var sourceStore: SourceStore?
    private var downloadManager: ComicDownloadManager?
    private var sourceRuntime: SourceRuntime?
    private let notificationCenter: NotificationCenter
    private var downloadUpdateObserver: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter

        // Wire up login VM engine runner
        login.engineExecutionQueue = engineExecutionQueue

        // Watch for source selection changes
        sourceManager.onSelectedSourceChanged = { [weak self] _ in
            Task { await self?.login.refreshLoginURLForSelectedSource() }
        }

        // Refresh download list on background download updates
        downloadUpdateObserver = notificationCenter.addObserver(
            forName: .comicDownloadDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                let item = notification.userInfo?[ComicDownloadNotificationKey.item] as? DownloadChapterItem
                if let item {
                    if item.status != .completed {
                        self.library.applyDownloadUpdate(item)
                    }
                    if item.status == .completed || item.status == .failed {
                        await self.library.refreshDownloadList()
                    }
                } else {
                    await self.library.refreshDownloadList()
                }
            }
        }
    }

    // MARK: - Initialization

    func prepareIfNeeded() async {
        if core != nil, sourceStore != nil, downloadManager != nil, sourceRuntime != nil {
            return
        }
        do {
            let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SourceRuntime", isDirectory: true)
            if core == nil {
                core = try CoreBootstrap(baseDirectory: baseDir)
            }
            let store: SourceStore
            if let sourceStore {
                store = sourceStore
            } else {
                store = try SourceStore(baseDirectory: baseDir)
            }
            sourceStore = store
            if downloadManager == nil {
                downloadManager = ComicDownloadManager(
                    database: core!.database,
                    rootDirectory: baseDir.appendingPathComponent("downloads", isDirectory: true)
                )
            }
            WebLoginCookieStore.restoreCookies()

            // Wire child VMs
            login.sourceStore = store
            login.sourceManagerViewModel = sourceManager

            try await sourceManager.prepare(sourceStore: store)
            try await library.prepare(core: core!, downloadManager: downloadManager!)
            try await tracker.prepare(database: core!.database)
            sourceRuntime = SourceRuntime(
                sourceManager: sourceManager,
                library: library,
                login: login,
                engineExecutionQueue: engineExecutionQueue
            )

            vmDebugLog("prepareIfNeeded initialized at \(baseDir.path)", level: .info)
        } catch {
            vmDebugLog("prepareIfNeeded failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Search

    func executeSearch(
        sourceKey: String,
        keyword: String,
        options: [String],
        page: Int,
        nextToken: String?
    ) async throws -> SearchExecutionResponse {
        await prepareIfNeeded()
        return try await requireSourceRuntime().executeSearch(
            sourceKey: sourceKey,
            keyword: keyword,
            options: options,
            page: page,
            nextToken: nextToken
        )
    }

    func currentRuntimeDownloadQueueItems() async -> [DownloadChapterItem] {
        await prepareIfNeeded()
        guard let downloadManager else { return [] }
        return await downloadManager.currentQueueItems()
    }

    func loadCategoryPageProfile(sourceKey: String) async throws -> CategoryPageProfile {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadCategoryPageProfile(sourceKey: sourceKey)
    }

    func loadExplorePages(sourceKey: String) async throws -> [ExplorePageItem] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadExplorePages(sourceKey: sourceKey)
    }

    func loadExploreComicsPage(
        sourceKey: String,
        pageIndex: Int,
        page: Int = 1,
        nextToken: String?
    ) async throws -> ComicPageResult {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadExploreComicsPage(
            sourceKey: sourceKey,
            pageIndex: pageIndex,
            page: page,
            nextToken: nextToken
        )
    }

    func loadExploreMultiPart(sourceKey: String, pageIndex: Int) async throws -> [ExplorePartData] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadExploreMultiPart(sourceKey: sourceKey, pageIndex: pageIndex)
    }

    func loadExploreMixed(sourceKey: String, pageIndex: Int, page: Int = 1) async throws -> ExploreMixedPageResult {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadExploreMixed(sourceKey: sourceKey, pageIndex: pageIndex, page: page)
    }

    func loadCategoryComicsOptionGroups(sourceKey: String, category: String, param: String?) async throws -> [CategoryComicsOptionGroup] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadCategoryComicsOptionGroups(sourceKey: sourceKey, category: category, param: param)
    }

    func loadCategoryRankingProfile(sourceKey: String) async throws -> CategoryRankingProfile {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadCategoryRankingProfile(sourceKey: sourceKey)
    }

    func loadCategoryComics(
        sourceKey: String,
        category: String,
        param: String?,
        options: [String],
        page: Int = 1,
        nextToken: String?
    ) async throws -> CategoryComicsPage {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadCategoryComics(
            sourceKey: sourceKey,
            category: category,
            param: param,
            options: options,
            page: page,
            nextToken: nextToken
        )
    }

    func loadCategoryRanking(
        sourceKey: String,
        option: String,
        page: Int = 1,
        nextToken: String?
    ) async throws -> CategoryComicsPage {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadCategoryRanking(
            sourceKey: sourceKey,
            option: option,
            page: page,
            nextToken: nextToken
        )
    }

    func loadSourceCapabilityProfile(sourceKey: String) async throws -> SourceCapabilityProfile {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadSourceCapabilityProfile(sourceKey: sourceKey)
    }

    func loadSourceSettings(sourceKey: String) async throws -> [SourceSettingDefinition] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadSourceSettings(sourceKey: sourceKey)
    }

    func saveSourceSetting(sourceKey: String, key: String, value: Any) async throws {
        await prepareIfNeeded()
        try await requireSourceRuntime().saveSourceSetting(sourceKey: sourceKey, key: key, value: value)
    }

    // MARK: - Comic Detail & Pages

    func loadComicDetail(_ item: ComicSummary) async throws -> ComicDetail {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadComicDetail(item)
    }

    func loadComicPages(_ item: ComicSummary, chapterID: String) async throws -> [String] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadComicPages(item, chapterID: chapterID)
    }

    func loadComicPageRequests(_ item: ComicSummary, chapterID: String) async throws -> [ImageRequest] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadComicPageRequests(item, chapterID: chapterID)
    }

    // MARK: - Source Favorites (delegated to engine, not local SQLite)

    func loadSourceFavoriteFolders(_ item: ComicSummary) async throws -> [FavoriteFolder] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadSourceFavoriteFolders(item)
    }

    func loadSourceFavoriteFolders(sourceKey: String) async throws -> [FavoriteFolder] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadSourceFavoriteFolders(sourceKey: sourceKey)
    }

    func loadSourceFavoriteComics(sourceKey: String, page: Int = 1, folderID: String? = nil) async throws -> [ComicSummary] {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadSourceFavoriteComics(sourceKey: sourceKey, page: page, folderID: folderID)
    }

    func loadSourceFavoriteComicsPage(
        sourceKey: String,
        page: Int = 1,
        folderID: String? = nil,
        nextToken: String?
    ) async throws -> ComicPageResult {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadSourceFavoriteComicsPage(
            sourceKey: sourceKey,
            page: page,
            folderID: folderID,
            nextToken: nextToken
        )
    }

    func toggleSourceFavorite(
        _ item: ComicSummary,
        detail: ComicDetail,
        folderID: String? = nil,
        isAdding: Bool? = nil
    ) async throws -> ComicDetail {
        await prepareIfNeeded()
        return try await requireSourceRuntime().toggleSourceFavorite(
            item,
            detail: detail,
            folderID: folderID,
            isAdding: isAdding
        )
    }

    func setSourceFavorite(
        _ item: ComicSummary,
        favoriteId: String? = nil,
        folderID: String? = nil,
        isAdding: Bool
    ) async throws {
        await prepareIfNeeded()
        try await requireSourceRuntime().setSourceFavorite(
            item,
            favoriteId: favoriteId,
            folderID: folderID,
            isAdding: isAdding
        )
    }

    // MARK: - Comments

    func getComicCommentCapabilities(_ item: ComicSummary) async throws -> ComicCommentCapabilities {
        await prepareIfNeeded()
        return try await requireSourceRuntime().getComicCommentCapabilities(item)
    }

    func loadComicComments(
        _ item: ComicSummary,
        detail: ComicDetail,
        page: Int = 1,
        replyTo: String? = nil
    ) async throws -> ComicCommentsPage {
        await prepareIfNeeded()
        return try await requireSourceRuntime().loadComicComments(
            item,
            detail: detail,
            page: page,
            replyTo: replyTo
        )
    }

    func sendComicComment(
        _ item: ComicSummary,
        detail: ComicDetail,
        content: String,
        replyTo: String? = nil
    ) async throws {
        await prepareIfNeeded()
        try await requireSourceRuntime().sendComicComment(item, detail: detail, content: content, replyTo: replyTo)
    }

    func likeComicComment(
        _ item: ComicSummary,
        detail: ComicDetail,
        commentID: String,
        isLiking: Bool
    ) async throws -> Int? {
        await prepareIfNeeded()
        return try await requireSourceRuntime().likeComicComment(
            item,
            detail: detail,
            commentID: commentID,
            isLiking: isLiking
        )
    }

    func voteComicComment(
        _ item: ComicSummary,
        detail: ComicDetail,
        commentID: String,
        isUp: Bool,
        isCancel: Bool
    ) async throws -> Int? {
        await prepareIfNeeded()
        return try await requireSourceRuntime().voteComicComment(
            item,
            detail: detail,
            commentID: commentID,
            isUp: isUp,
            isCancel: isCancel
        )
    }

    func resolveComicTagClick(_ item: ComicSummary, namespace: String, tag: String) async throws -> CategoryJumpTarget {
        await prepareIfNeeded()
        return try await requireSourceRuntime().resolveComicTagClick(item, namespace: namespace, tag: tag)
    }

    // MARK: - Downloads (Chapter)

    func enqueueChapterDownload(
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        comicDescription: String? = nil
    ) async -> String {
        await prepareIfNeeded()
        return await requireSourceRuntime().enqueueChapterDownload(
            item: item,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            comicDescription: comicDescription
        )
    }

    // MARK: - Private Helpers

    private func requireSourceRuntime() -> SourceRuntime {
        if let sourceRuntime {
            return sourceRuntime
        }
        if core != nil, sourceStore != nil, downloadManager != nil {
            let runtime = SourceRuntime(
                sourceManager: sourceManager,
                library: library,
                login: login,
                engineExecutionQueue: engineExecutionQueue
            )
            sourceRuntime = runtime
            vmDebugLog("requireSourceRuntime recovered missing runtime after partial prepare", level: .warn)
            return runtime
        }
        preconditionFailure("SourceRuntime accessed before prepareIfNeeded completed")
    }
}
