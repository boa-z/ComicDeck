import Foundation
import Observation

private enum LibVMLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
private func libDebugLog(_ message: String, level: LibVMLogLevel = .debug) {
    guard RuntimeDebugConsole.isEnabled else { return }
    let line = "[SourceRuntime][\(level.rawValue)][LibraryVM] \(message)"
    NSLog("%@", line)
    RuntimeDebugConsole.shared.append(line)
}

@MainActor
@Observable
final class LibraryViewModel {
    private enum Limits {
        static let favorites = 100
        static let history = 100
        static let downloads = 400
    }

    private enum PersistKey {
        static let readingDurationDay = "library.readingDuration.day"
        static let readingDurationSeconds = "library.readingDuration.seconds"
    }

    var favorites: [FavoriteComic] = []
    var favoriteCategories: [LibraryCategory] = []
    var favoriteCategoryMemberships: [Int64: Set<String>] = [:]
    var history: [ReadingHistoryItem] = []
    var downloadChapters: [DownloadChapterItem] = []
    var offlineChapters: [OfflineChapterAsset] = []
    var status = "Ready"
    var pendingFavoriteKeys: Set<String> = []
    var todayReadingDurationSeconds: TimeInterval = 0

    private var core: CoreBootstrap?
    private var downloadManager: ComicDownloadManager?
    private var offlineIndexer: OfflineLibraryIndexer?

    init() {
        refreshTodayReadingDuration()
    }
    // MARK: - Setup

    func prepare(core: CoreBootstrap, downloadManager: ComicDownloadManager) async throws {
        self.core = core
        self.downloadManager = downloadManager
        if offlineIndexer == nil {
            offlineIndexer = OfflineLibraryIndexer(
                database: core.database,
                rootDirectory: core.baseDirectory.appendingPathComponent("downloads", isDirectory: true)
            )
        }
        refreshTodayReadingDuration()
        try await reloadAll()
        await reindexOfflineLibrary()
    }

    func reloadAll() async throws {
        guard let core else { return }
        favorites = try await core.database.listFavorites(limit: Limits.favorites)
        favoriteCategories = try await core.database.listFavoriteCategories()
        favoriteCategoryMemberships = try await core.database.listFavoriteCategoryMemberships()
        history = try await core.database.listHistory(limit: Limits.history)
        downloadChapters = try await core.database.listDownloadChapters(limit: Limits.downloads)
            .filter { $0.status != .completed }
        offlineChapters = try await core.database.listOfflineChapters(limit: Limits.downloads)
    }

    // MARK: - Favorites

    func favorite(_ item: ComicSummary) async {
        let operationKey = favoriteOperationKey(for: item)
        guard !pendingFavoriteKeys.contains(operationKey) else { return }
        pendingFavoriteKeys.insert(operationKey)
        defer { pendingFavoriteKeys.remove(operationKey) }
        guard let core else { return }

        let favorite = FavoriteComic(
            id: item.id,
            sourceKey: item.sourceKey,
            title: item.title,
            coverURL: item.coverURL,
            createdAt: Int64(Date().timeIntervalSince1970)
        )

        do {
            try await core.database.upsertFavorite(favorite)
            upsertFavoriteLocally(favorite)
            status = "Saved to bookmarks"
        } catch {
            status = "Bookmark failed: \(error.localizedDescription)"
        }
    }

    func removeBookmark(_ item: ComicSummary) async {
        let operationKey = favoriteOperationKey(for: item)
        guard !pendingFavoriteKeys.contains(operationKey) else { return }
        pendingFavoriteKeys.insert(operationKey)
        defer { pendingFavoriteKeys.remove(operationKey) }
        guard let core else { return }

        do {
            try await core.database.deleteFavorite(comicID: item.id, sourceKey: item.sourceKey)
            favorites.removeAll { $0.id == item.id && $0.sourceKey == item.sourceKey }
            for categoryID in favoriteCategoryMemberships.keys {
                favoriteCategoryMemberships[categoryID]?.remove(operationKey)
            }
            status = "Removed from bookmarks"
        } catch {
            status = "Remove bookmark failed: \(error.localizedDescription)"
        }
    }

    func toggleBookmark(_ item: ComicSummary) async {
        if isBookmarked(item) {
            await removeBookmark(item)
        } else {
            await favorite(item)
        }
    }

    func isFavoritePending(for item: ComicSummary) -> Bool {
        pendingFavoriteKeys.contains(favoriteOperationKey(for: item))
    }

    func isBookmarked(_ item: ComicSummary) -> Bool {
        favorites.contains { $0.id == item.id && $0.sourceKey == item.sourceKey }
    }

    // MARK: - History

    func recordReadingHistory(
        comicID: String,
        sourceKey: String,
        title: String,
        coverURL: String? = nil,
        author: String? = nil,
        tags: [String] = [],
        chapterID: String?,
        chapter: String?,
        page: Int
    ) async {
        guard let core, page > 0 else { return }
        do {
            let updatedItem = try await core.database.addHistoryAndFetch(
                comicID: comicID,
                sourceKey: sourceKey,
                title: title,
                coverURL: coverURL,
                author: author,
                tags: tags,
                chapterID: chapterID,
                chapter: chapter,
                page: page
            )
            upsertHistoryLocally(updatedItem)
        } catch {
            libDebugLog("recordReadingHistory failed: \(error.localizedDescription)", level: .warn)
        }
    }

    func clearHistory() async {
        guard let core else { return }
        do {
            try await core.database.clearHistory()
            history = []
            status = "History cleared"
        } catch {
            status = "Clear history failed: \(error.localizedDescription)"
        }
    }

    func deleteHistory(_ item: ReadingHistoryItem) async {
        guard let core else { return }
        do {
            try await core.database.deleteHistory(id: item.id)
            history.removeAll { $0.id == item.id }
            status = "Deleted history item"
        } catch {
            status = "Delete history failed: \(error.localizedDescription)"
        }
    }

    func latestHistoryForComic(sourceKey: String, comicID: String) -> ReadingHistoryItem? {
        history.first { $0.sourceKey == sourceKey && $0.comicID == comicID }
    }

    // MARK: - Downloads

    func refreshDownloadList() async {
        guard let core else { return }
        do {
            downloadChapters = try await core.database.listDownloadChapters(limit: Limits.downloads)
                .filter { $0.status != .completed }
            offlineChapters = try await core.database.listOfflineChapters(limit: Limits.downloads)
        } catch {
            libDebugLog("refreshDownloadList failed: \(error.localizedDescription)", level: .warn)
        }
    }

    func refreshOfflineLibrary() async {
        guard let core else { return }
        do {
            offlineChapters = try await core.database.listOfflineChapters(limit: Limits.downloads)
        } catch {
            libDebugLog("refreshOfflineLibrary failed: \(error.localizedDescription)", level: .warn)
        }
    }

    func reindexOfflineLibrary() async {
        do {
            try await offlineIndexer?.reindex()
            await refreshOfflineLibrary()
            status = "Offline library reindexed"
        } catch {
            libDebugLog("reindexOfflineLibrary failed: \(error.localizedDescription)", level: .warn)
            status = "Offline reindex failed: \(error.localizedDescription)"
        }
    }

    func importOfflineArchives(from urls: [URL]) async -> OfflineImportSummary {
        guard let core else {
            return OfflineImportSummary(importedCount: 0, failures: ["Library store is not initialized."])
        }

        let importer = OfflineImportService(
            rootDirectory: core.baseDirectory.appendingPathComponent("downloads", isDirectory: true)
        )
        let summary = await importer.importArchives(at: urls)

        if summary.importedCount > 0 {
            await reindexOfflineLibrary()
        }

        if summary.importedCount > 0 && summary.failures.isEmpty {
            status = "Imported \(summary.importedCount) offline archive\(summary.importedCount == 1 ? "" : "s")"
        } else if summary.importedCount > 0 {
            status = "Imported \(summary.importedCount) archive\(summary.importedCount == 1 ? "" : "s") with issues"
        } else if let firstFailure = summary.failures.first {
            status = "Import failed: \(firstFailure)"
        }

        return summary
    }

    func enqueueChapterDownload(
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        comicDescription: String? = nil,
        requests: [ImageRequest]
    ) async {
        guard let downloadManager else { return }
        guard !requests.isEmpty else {
            status = "No downloadable pages"
            return
        }
        do {
            try await downloadManager.enqueue(
                .init(
                    sourceKey: item.sourceKey,
                    comicID: item.id,
                    comicTitle: item.title,
                    coverURL: item.coverURL,
                    comicDescription: comicDescription,
                    chapterID: chapterID,
                    chapterTitle: chapterTitle.isEmpty ? chapterID : chapterTitle,
                    requests: requests
                )
            )
            status = "Download queued: \(chapterTitle.isEmpty ? chapterID : chapterTitle)"
        } catch {
            status = "Queue download failed: \(error.localizedDescription)"
        }
    }

    func deleteDownload(_ item: DownloadChapterItem) async {
        guard let core else { return }
        do {
            let path = try await core.database.deleteDownloadChapter(id: item.id)
            if let path {
                try? FileManager.default.removeItem(atPath: path)
            }
            downloadChapters.removeAll { $0.id == item.id }
            status = "Deleted download: \(item.chapterTitle)"
        } catch {
            status = "Delete download failed: \(error.localizedDescription)"
        }
    }

    func deleteDownloads(_ items: [DownloadChapterItem]) async {
        guard let core else { return }
        let ids = Array(Set(items.map(\.id)))
        guard !ids.isEmpty else { return }
        do {
            let paths = try await core.database.deleteDownloadChapters(ids: ids)
            for path in Set(paths) {
                try? FileManager.default.removeItem(atPath: path)
            }
            let idSet = Set(ids)
            downloadChapters.removeAll { idSet.contains($0.id) }
            status = "Deleted \(ids.count) downloads"
        } catch {
            status = "Delete downloads failed: \(error.localizedDescription)"
        }
    }

    func deleteOfflineChapters(_ items: [OfflineChapterAsset]) async {
        guard let core else { return }
        let ids = Array(Set(items.map(\.id)))
        guard !ids.isEmpty else { return }
        do {
            let paths = try await core.database.deleteOfflineChapters(ids: ids)
            for path in Set(paths) {
                try? FileManager.default.removeItem(atPath: path)
            }
            let idSet = Set(ids)
            offlineChapters.removeAll { idSet.contains($0.id) }
            status = "Deleted \(ids.count) offline chapters"
        } catch {
            status = "Delete offline chapters failed: \(error.localizedDescription)"
        }
    }

    func clearAllDownloads() async {
        guard let core else { return }
        do {
            let paths = try await core.database.clearDownloadChapters()
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }
            downloadChapters = []
            status = "All downloads cleared"
        } catch {
            status = "Clear downloads failed: \(error.localizedDescription)"
        }
    }

    func clearOfflineLibrary() async {
        guard let core else { return }
        do {
            let paths = try await core.database.clearOfflineChapters()
            for path in Set(paths) {
                try? FileManager.default.removeItem(atPath: path)
            }
            offlineChapters = []
            status = "Offline library cleared"
        } catch {
            status = "Clear offline library failed: \(error.localizedDescription)"
        }
    }

    func offlineChapter(sourceKey: String, comicID: String, chapterID: String) -> OfflineChapterAsset? {
        offlineChapters.first {
            $0.sourceKey == sourceKey &&
            $0.comicID == comicID &&
            $0.chapterID == chapterID
        }
    }

    func renameImportedOfflineComic(sourceKey: String, comicID: String, to title: String) async {
        guard let core else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Rename failed: title cannot be empty"
            return
        }

        let items = offlineChapters.filter { $0.sourceKey == sourceKey && $0.comicID == comicID }
        guard !items.isEmpty else {
            status = "Rename failed: offline comic not found"
            return
        }

        do {
            try await core.database.renameOfflineComic(sourceKey: sourceKey, comicID: comicID, comicTitle: trimmed)
            for item in items {
                try updateOfflineMetadataTitle(at: item.directoryPath, title: trimmed)
            }
            await refreshOfflineLibrary()
            status = "Offline comic renamed"
        } catch {
            status = "Rename offline comic failed: \(error.localizedDescription)"
        }
    }

    func createBackupPayload() -> AppBackupPayload {
        AppBackupService.makePayload(
            favorites: favorites,
            categories: favoriteCategories,
            categoryMemberships: favoriteCategoryMemberships,
            history: history
        )
    }

    func restore(from payload: AppBackupPayload, sourceManager: SourceManagerViewModel) async throws {
        guard let core else {
            throw SQLiteStoreError.execute("Library store is not initialized")
        }

        try await core.database.replaceFavorites(with: payload.library.favorites)
        try await core.database.replaceFavoriteCategories(
            with: payload.library.categories,
            memberships: payload.library.categoryMemberships.reduce(into: [:]) { partialResult, entry in
                guard let categoryID = Int64(entry.key) else { return }
                partialResult[categoryID] = Set(entry.value)
            }
        )
        try await core.database.replaceHistory(with: payload.library.history)

        AppBackupService.applyPreferences(payload.preferences)
        AppBackupService.applySourceRuntime(payload.sourceRuntime, to: sourceManager)

        favorites = payload.library.favorites.sorted { $0.createdAt > $1.createdAt }
        favoriteCategories = payload.library.categories.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.createdAt < $1.createdAt
        }
        favoriteCategoryMemberships = payload.library.categoryMemberships.reduce(into: [:]) { partialResult, entry in
            guard let categoryID = Int64(entry.key) else { return }
            partialResult[categoryID] = Set(entry.value)
        }
        history = payload.library.history.sorted { $0.updatedAt > $1.updatedAt }
        refreshTodayReadingDuration()
        status = "Backup restored"
    }

    // MARK: - Library Categories

    func createBookmarkShelf(name: String) async {
        guard let core else { return }
        do {
            let category = try await core.database.createBookmarkShelf(name: name)
            favoriteCategories.append(category)
            favoriteCategories.sort(by: categorySort)
            status = "Shelf created"
        } catch {
            status = "Create category failed: \(error.localizedDescription)"
        }
    }

    func renameBookmarkShelf(_ category: LibraryCategory, name: String) async {
        guard let core else { return }
        do {
            try await core.database.renameBookmarkShelf(id: category.id, name: name)
            if let index = favoriteCategories.firstIndex(where: { $0.id == category.id }) {
                favoriteCategories[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            favoriteCategories.sort(by: categorySort)
            status = "Shelf renamed"
        } catch {
            status = "Rename category failed: \(error.localizedDescription)"
        }
    }

    func deleteBookmarkShelf(_ category: LibraryCategory) async {
        guard let core else { return }
        do {
            try await core.database.deleteBookmarkShelf(id: category.id)
            favoriteCategories.removeAll { $0.id == category.id }
            favoriteCategoryMemberships.removeValue(forKey: category.id)
            status = "Shelf deleted"
        } catch {
            status = "Delete category failed: \(error.localizedDescription)"
        }
    }

    func reorderBookmarkShelves(_ categories: [LibraryCategory]) async {
        guard let core else { return }
        let reordered = categories.enumerated().map { index, category in
            var copy = category
            copy.sortOrder = index
            return copy
        }
        do {
            try await core.database.reorderBookmarkShelves(reordered)
            favoriteCategories = reordered
            favoriteCategories.sort(by: categorySort)
            status = "Shelves reordered"
        } catch {
            status = "Reorder shelves failed: \(error.localizedDescription)"
        }
    }

    func addBookmarks(_ favorites: [FavoriteComic], to shelf: LibraryCategory) async {
        guard let core else { return }
        let comicKeys = favorites.map(favoriteComicKey(for:))
        guard !comicKeys.isEmpty else { return }
        do {
            try await core.database.addBookmarks(comicKeys: comicKeys, toShelfID: shelf.id)
            favoriteCategoryMemberships[shelf.id, default: []].formUnion(comicKeys)
            status = "Added to \(shelf.name)"
        } catch {
            status = "Add to shelf failed: \(error.localizedDescription)"
        }
    }

    func removeBookmark(_ favorite: FavoriteComic, from shelf: LibraryCategory) async {
        guard let core else { return }
        do {
            try await core.database.removeBookmark(
                comicKey: favoriteComicKey(for: favorite),
                fromShelfID: shelf.id
            )
            favoriteCategoryMemberships[shelf.id]?.remove(favoriteComicKey(for: favorite))
            status = "Removed from \(shelf.name)"
        } catch {
            status = "Remove from shelf failed: \(error.localizedDescription)"
        }
    }

    func bookmarks(in shelf: LibraryCategory) -> [FavoriteComic] {
        guard let memberships = favoriteCategoryMemberships[shelf.id], !memberships.isEmpty else { return [] }
        return favorites.filter { memberships.contains(favoriteComicKey(for: $0)) }
    }

    func bookmarkCount(in shelf: LibraryCategory) -> Int {
        favoriteCategoryMemberships[shelf.id]?.count ?? 0
    }

    // MARK: - Cache

    func clearReaderCache() async {
        await ReaderImagePipeline.shared.clearAllCache()
        status = "Reader cache cleared"
    }

    func readerCacheSizeText() async -> String {
        let bytes = await ReaderImagePipeline.shared.diskCacheSizeBytes()
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    func readerCacheMetrics() async -> ReaderImageCacheMetrics {
        var metrics = await ReaderImagePipeline.shared.cacheMetrics()
        metrics.diskBytes = await ReaderImagePipeline.shared.diskCacheSizeBytes()
        return metrics
    }

    func addReadingDuration(_ seconds: TimeInterval) {
        let boundedSeconds = min(max(seconds, 0), 4 * 60 * 60)
        guard boundedSeconds >= 3 else { return }
        normalizeReadingDurationStorage()
        todayReadingDurationSeconds += boundedSeconds
        persistTodayReadingDuration()
    }

    func refreshTodayReadingDuration() {
        normalizeReadingDurationStorage()
        todayReadingDurationSeconds = UserDefaults.standard.double(forKey: PersistKey.readingDurationSeconds)
    }

    func applyDownloadUpdate(_ item: DownloadChapterItem?) {
        guard let item else { return }
        downloadChapters.removeAll {
            $0.sourceKey == item.sourceKey &&
            $0.comicID == item.comicID &&
            $0.chapterID == item.chapterID
        }
        guard item.status != .completed else { return }
        downloadChapters.insert(item, at: 0)
        downloadChapters.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.id > rhs.id
        }
        if downloadChapters.count > Limits.downloads {
            downloadChapters.removeLast(downloadChapters.count - Limits.downloads)
        }
    }

    private func upsertFavoriteLocally(_ favorite: FavoriteComic) {
        favorites.removeAll { $0.id == favorite.id && $0.sourceKey == favorite.sourceKey }
        favorites.insert(favorite, at: 0)
        if favorites.count > Limits.favorites {
            favorites.removeLast(favorites.count - Limits.favorites)
        }
    }

    private func favoriteOperationKey(for item: ComicSummary) -> String {
        "\(item.sourceKey)::\(item.id)"
    }

    private func favoriteComicKey(for favorite: FavoriteComic) -> String {
        "\(favorite.sourceKey)::\(favorite.id)"
    }

    private func upsertHistoryLocally(_ item: ReadingHistoryItem) {
        history.removeAll {
            $0.id == item.id ||
            (
                $0.comicID == item.comicID &&
                $0.sourceKey == item.sourceKey &&
                $0.chapter == item.chapter
            )
        }
        history.insert(item, at: 0)
        if history.count > Limits.history {
            history.removeLast(history.count - Limits.history)
        }
    }

    private func normalizeReadingDurationStorage(now: Date = Date()) {
        let defaults = UserDefaults.standard
        let todayIdentifier = dayIdentifier(for: now)
        let storedDay = defaults.string(forKey: PersistKey.readingDurationDay)
        if storedDay != todayIdentifier {
            defaults.set(todayIdentifier, forKey: PersistKey.readingDurationDay)
            defaults.set(0.0, forKey: PersistKey.readingDurationSeconds)
        }
    }

    private func persistTodayReadingDuration() {
        let defaults = UserDefaults.standard
        defaults.set(dayIdentifier(for: Date()), forKey: PersistKey.readingDurationDay)
        defaults.set(todayReadingDurationSeconds, forKey: PersistKey.readingDurationSeconds)
    }

    private func dayIdentifier(for date: Date) -> String {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func categorySort(lhs: LibraryCategory, rhs: LibraryCategory) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    private func updateOfflineMetadataTitle(at directoryPath: String, title: String) throws {
        let metadataURL = URL(fileURLWithPath: directoryPath, isDirectory: true).appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else { return }
        let data = try Data(contentsOf: metadataURL)
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["comicTitle"] = title
        let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: metadataURL, options: .atomic)
    }
}
