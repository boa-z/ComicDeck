import Foundation
import GRDB

public enum SQLiteStoreError: Error, LocalizedError {
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case bind(String)

    public var errorDescription: String? {
        switch self {
        case let .openDatabase(message): return "open database failed: \(message)"
        case let .execute(message): return "execute SQL failed: \(message)"
        case let .prepare(message): return "prepare SQL failed: \(message)"
        case let .bind(message): return "bind SQL values failed: \(message)"
        }
    }
}

public actor SQLiteStore {
    private let dbQueue: DatabaseQueue

    public init(databaseURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            configuration.busyMode = .timeout(3)
            configuration.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL;")
                try db.execute(sql: "PRAGMA synchronous = NORMAL;")
                try db.execute(sql: "PRAGMA temp_store = MEMORY;")
                try db.execute(sql: "PRAGMA foreign_keys = ON;")
                try db.execute(sql: "PRAGMA busy_timeout = 3000;")
            }

            let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
            try Self.makeMigrator().migrate(queue)
            self.dbQueue = queue
        } catch {
            throw Self.openDatabaseError(error)
        }
    }

    // MARK: - Favorites

    public func upsertFavorite(_ comic: FavoriteComic) throws {
        try write { db in
            try db.execute(
                sql: """
                INSERT INTO favorites (id, source_key, title, cover_url, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id, source_key)
                DO UPDATE SET title = excluded.title, cover_url = excluded.cover_url;
                """,
                arguments: [comic.id, comic.sourceKey, comic.title, comic.coverURL, comic.createdAt]
            )
        }
    }

    public func listFavorites(limit: Int = 100) throws -> [FavoriteComic] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, source_key, title, cover_url, created_at
                FROM favorites
                ORDER BY created_at DESC
                LIMIT ?;
                """,
                arguments: [limit]
            ).map(Self.favoriteComic(from:))
        }
    }

    public func replaceFavorites(with items: [FavoriteComic]) throws {
        try immediateTransaction { db in
            try db.execute(sql: "DELETE FROM favorites;")
            for item in items {
                try db.execute(
                    sql: """
                    INSERT INTO favorites (id, source_key, title, cover_url, created_at)
                    VALUES (?, ?, ?, ?, ?);
                    """,
                    arguments: [item.id, item.sourceKey, item.title, item.coverURL, item.createdAt]
                )
            }
        }
    }

    public func deleteFavorite(comicID: String, sourceKey: String) throws {
        try immediateTransaction { db in
            try db.execute(
                sql: """
                DELETE FROM favorite_category_memberships
                WHERE comic_id = ? AND source_key = ?;
                """,
                arguments: [comicID, sourceKey]
            )
            try db.execute(
                sql: """
                DELETE FROM favorites
                WHERE id = ? AND source_key = ?;
                """,
                arguments: [comicID, sourceKey]
            )
        }
    }

    public func listFavoriteCategories() throws -> [LibraryCategory] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, name, sort_order, created_at
                FROM favorite_categories
                ORDER BY sort_order ASC, created_at ASC, id ASC;
                """
            ).map(Self.libraryCategory(from:))
        }
    }

    public func listFavoriteCategoryMemberships() throws -> [Int64: Set<String>] {
        try read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT category_id, comic_id, source_key
                FROM favorite_category_memberships;
                """
            )
            var memberships: [Int64: Set<String>] = [:]
            for row in rows {
                let categoryID: Int64 = row["category_id"]
                let comicID: String = row["comic_id"]
                let sourceKey: String = row["source_key"]
                memberships[categoryID, default: []].insert("\(sourceKey)::\(comicID)")
            }
            return memberships
        }
    }

    public func createBookmarkShelf(name: String) throws -> LibraryCategory {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SQLiteStoreError.execute("Category name cannot be empty")
        }

        return try write { db in
            let nextSortOrder = ((try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM favorite_categories;")) ?? -1) + 1
            let createdAt = Int64(Date().timeIntervalSince1970)
            try db.execute(
                sql: """
                INSERT INTO favorite_categories (name, sort_order, created_at)
                VALUES (?, ?, ?);
                """,
                arguments: [trimmedName, nextSortOrder, createdAt]
            )
            return LibraryCategory(
                id: db.lastInsertedRowID,
                name: trimmedName,
                sortOrder: nextSortOrder,
                createdAt: createdAt
            )
        }
    }

    public func renameBookmarkShelf(id: Int64, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SQLiteStoreError.execute("Category name cannot be empty")
        }

        try write { db in
            try db.execute(
                sql: """
                UPDATE favorite_categories
                SET name = ?
                WHERE id = ?;
                """,
                arguments: [trimmedName, id]
            )
        }
    }

    public func deleteBookmarkShelf(id: Int64) throws {
        try write { db in
            try db.execute(
                sql: "DELETE FROM favorite_categories WHERE id = ?;",
                arguments: [id]
            )
        }
    }

    public func reorderBookmarkShelves(_ categories: [LibraryCategory]) throws {
        try immediateTransaction { db in
            for (index, category) in categories.enumerated() {
                try db.execute(
                    sql: """
                    UPDATE favorite_categories
                    SET sort_order = ?
                    WHERE id = ?;
                    """,
                    arguments: [index, category.id]
                )
            }
        }
    }

    public func replaceFavoriteCategories(
        with categories: [LibraryCategory],
        memberships: [Int64: Set<String>]
    ) throws {
        try immediateTransaction { db in
            try db.execute(sql: "DELETE FROM favorite_category_memberships;")
            try db.execute(sql: "DELETE FROM favorite_categories;")

            for category in categories {
                try db.execute(
                    sql: """
                    INSERT INTO favorite_categories (id, name, sort_order, created_at)
                    VALUES (?, ?, ?, ?);
                    """,
                    arguments: [category.id, category.name, category.sortOrder, category.createdAt]
                )
            }

            let now = Int64(Date().timeIntervalSince1970)
            for (categoryID, comicKeys) in memberships {
                for comicKey in comicKeys {
                    guard let split = Self.splitFavoriteComicKey(comicKey) else { continue }
                    try db.execute(
                        sql: """
                        INSERT INTO favorite_category_memberships (category_id, comic_id, source_key, created_at)
                        VALUES (?, ?, ?, ?);
                        """,
                        arguments: [categoryID, split.comicID, split.sourceKey, now]
                    )
                }
            }
        }
    }

    public func addBookmarks(
        comicKeys: [String],
        toShelfID categoryID: Int64
    ) throws {
        let uniqueKeys = Array(Set(comicKeys))
        guard !uniqueKeys.isEmpty else { return }

        try write { db in
            let now = Int64(Date().timeIntervalSince1970)
            for comicKey in uniqueKeys {
                guard let split = Self.splitFavoriteComicKey(comicKey) else { continue }
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO favorite_category_memberships (category_id, comic_id, source_key, created_at)
                    VALUES (?, ?, ?, ?);
                    """,
                    arguments: [categoryID, split.comicID, split.sourceKey, now]
                )
            }
        }
    }

    public func removeBookmark(
        comicKey: String,
        fromShelfID categoryID: Int64
    ) throws {
        guard let split = Self.splitFavoriteComicKey(comicKey) else { return }
        try write { db in
            try db.execute(
                sql: """
                DELETE FROM favorite_category_memberships
                WHERE category_id = ? AND comic_id = ? AND source_key = ?;
                """,
                arguments: [categoryID, split.comicID, split.sourceKey]
            )
        }
    }

    // MARK: - Tracking

    public func upsertTrackerAccount(_ account: TrackerAccount) throws {
        try write { db in
            try db.execute(
                sql: """
                INSERT INTO tracker_accounts (provider, display_name, remote_user_id, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(provider)
                DO UPDATE SET
                    display_name = excluded.display_name,
                    remote_user_id = excluded.remote_user_id,
                    updated_at = excluded.updated_at;
                """,
                arguments: [account.provider.rawValue, account.displayName, account.remoteUserID, account.updatedAt]
            )
        }
    }

    public func listTrackerAccounts() throws -> [TrackerAccount] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT provider, display_name, remote_user_id, updated_at
                FROM tracker_accounts
                ORDER BY provider ASC;
                """
            ).compactMap(Self.trackerAccount(from:))
        }
    }

    public func deleteTrackerAccount(provider: TrackerProvider) throws {
        try write { db in
            try db.execute(
                sql: "DELETE FROM tracker_accounts WHERE provider = ?;",
                arguments: [provider.rawValue]
            )
        }
    }

    public func upsertTrackerBinding(
        provider: TrackerProvider,
        sourceKey: String,
        comicID: String,
        remoteMediaID: String,
        remoteTitle: String,
        remoteCoverURL: String?,
        lastSyncedProgress: Int,
        lastSyncedStatus: TrackerReadingStatus?
    ) throws -> TrackerBinding {
        try write { db in
            let now = Int64(Date().timeIntervalSince1970)
            try db.execute(
                sql: """
                INSERT INTO tracker_bindings (
                    provider, source_key, comic_id, remote_media_id, remote_title, remote_cover_url,
                    last_synced_progress, last_synced_status, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider, source_key, comic_id)
                DO UPDATE SET
                    remote_media_id = excluded.remote_media_id,
                    remote_title = excluded.remote_title,
                    remote_cover_url = excluded.remote_cover_url,
                    last_synced_progress = excluded.last_synced_progress,
                    last_synced_status = excluded.last_synced_status,
                    updated_at = excluded.updated_at;
                """,
                arguments: [
                    provider.rawValue,
                    sourceKey,
                    comicID,
                    remoteMediaID,
                    remoteTitle,
                    Self.normalizedOptionalString(remoteCoverURL),
                    lastSyncedProgress,
                    lastSyncedStatus?.rawValue,
                    now,
                ]
            )
            guard let binding = try Self.fetchTrackerBinding(db: db, provider: provider, sourceKey: sourceKey, comicID: comicID) else {
                throw SQLiteStoreError.execute("tracker binding not found after upsert")
            }
            return binding
        }
    }

    public func getTrackerBinding(
        provider: TrackerProvider,
        sourceKey: String,
        comicID: String
    ) throws -> TrackerBinding? {
        try read { db in
            try Self.fetchTrackerBinding(db: db, provider: provider, sourceKey: sourceKey, comicID: comicID)
        }
    }

    public func listTrackerBindings() throws -> [TrackerBinding] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, remote_title, remote_cover_url,
                       last_synced_progress, last_synced_status, updated_at
                FROM tracker_bindings
                ORDER BY updated_at DESC;
                """
            ).compactMap(Self.trackerBinding(from:))
        }
    }

    public func deleteTrackerBinding(provider: TrackerProvider, sourceKey: String, comicID: String) throws {
        try immediateTransaction { db in
            try db.execute(
                sql: "DELETE FROM tracker_sync_events WHERE provider = ? AND source_key = ? AND comic_id = ?;",
                arguments: [provider.rawValue, sourceKey, comicID]
            )
            try db.execute(
                sql: "DELETE FROM tracker_bindings WHERE provider = ? AND source_key = ? AND comic_id = ?;",
                arguments: [provider.rawValue, sourceKey, comicID]
            )
        }
    }

    public func enqueueTrackerSyncEvent(
        provider: TrackerProvider,
        sourceKey: String,
        comicID: String,
        remoteMediaID: String,
        targetProgress: Int,
        targetStatus: TrackerReadingStatus?
    ) throws -> TrackerSyncEvent {
        try write { db in
            let now = Int64(Date().timeIntervalSince1970)
            try db.execute(
                sql: """
                INSERT INTO tracker_sync_events (
                    provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                    state, retry_count, last_error, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
                ON CONFLICT(provider, source_key, comic_id)
                DO UPDATE SET
                    remote_media_id = excluded.remote_media_id,
                    target_progress = excluded.target_progress,
                    target_status = excluded.target_status,
                    state = excluded.state,
                    last_error = NULL,
                    updated_at = excluded.updated_at;
                """,
                arguments: [
                    provider.rawValue,
                    sourceKey,
                    comicID,
                    remoteMediaID,
                    targetProgress,
                    targetStatus?.rawValue,
                    TrackerSyncEventState.pending.rawValue,
                    now,
                    now,
                ]
            )
            guard let event = try Self.fetchTrackerSyncEvents(
                db: db,
                limit: 1,
                provider: provider,
                sourceKey: sourceKey,
                comicID: comicID
            ).first else {
                throw SQLiteStoreError.execute("tracker sync event not found after enqueue")
            }
            return event
        }
    }

    public func listTrackerSyncEvents(
        limit: Int = 100,
        provider: TrackerProvider? = nil,
        sourceKey: String? = nil,
        comicID: String? = nil
    ) throws -> [TrackerSyncEvent] {
        try read { db in
            try Self.fetchTrackerSyncEvents(
                db: db,
                limit: limit,
                provider: provider,
                sourceKey: sourceKey,
                comicID: comicID
            )
        }
    }

    public func markTrackerSyncEventFailed(id: Int64, errorMessage: String) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE tracker_sync_events
                SET state = ?, retry_count = retry_count + 1, last_error = ?, updated_at = ?
                WHERE id = ?;
                """,
                arguments: [TrackerSyncEventState.failed.rawValue, errorMessage, Int64(Date().timeIntervalSince1970), id]
            )
        }
    }

    public func deleteTrackerSyncEvent(id: Int64) throws {
        try write { db in
            try db.execute(
                sql: "DELETE FROM tracker_sync_events WHERE id = ?;",
                arguments: [id]
            )
        }
    }

    // MARK: - History

    public func addHistory(
        comicID: String,
        sourceKey: String,
        title: String,
        coverURL: String?,
        author: String? = nil,
        tags: [String] = [],
        chapterID: String?,
        chapter: String?,
        page: Int
    ) throws {
        _ = try write { db in
            try Self.upsertHistory(
                db: db,
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
        }
    }

    public func addHistoryAndFetch(
        comicID: String,
        sourceKey: String,
        title: String,
        coverURL: String?,
        author: String? = nil,
        tags: [String] = [],
        chapterID: String?,
        chapter: String?,
        page: Int
    ) throws -> ReadingHistoryItem {
        try write { db in
            try Self.upsertHistory(
                db: db,
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
        }
    }

    public func listHistory(limit: Int = 100) throws -> [ReadingHistoryItem] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, comic_id, source_key, title, cover_url, author, tags_json, chapter_id, chapter, page, updated_at
                FROM history
                ORDER BY updated_at DESC
                LIMIT ?;
                """,
                arguments: [limit]
            ).map(Self.readingHistoryItem(from:))
        }
    }

    public func replaceHistory(with items: [ReadingHistoryItem]) throws {
        try immediateTransaction { db in
            try db.execute(sql: "DELETE FROM history;")
            for item in items {
                try db.execute(
                    sql: """
                    INSERT INTO history (
                        id, comic_id, source_key, title, cover_url, author, tags_json, chapter_id, chapter, page, updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """,
                    arguments: [
                        item.id,
                        item.comicID,
                        item.sourceKey,
                        item.title,
                        item.coverURL,
                        Self.normalizedOptionalString(item.author),
                        Self.encodeTagsJSON(item.tags),
                        Self.normalizedOptionalString(item.chapterID),
                        Self.normalizedOptionalString(item.chapter),
                        item.page,
                        item.updatedAt,
                    ]
                )
            }
        }
    }

    public func clearHistory() throws {
        try write { db in
            try db.execute(sql: "DELETE FROM history;")
        }
    }

    public func deleteHistory(id: Int64) throws {
        try write { db in
            try db.execute(
                sql: "DELETE FROM history WHERE id = ?;",
                arguments: [id]
            )
        }
    }

    // MARK: - Reader Translation

    public func getReaderPageTranslationDocument(
        sourceKey: String,
        comicID: String,
        chapterID: String,
        pageIndex: Int,
        targetLanguage: ReaderTranslationLanguage,
        imageRequestKey: String,
        pipelineVersion: String,
        providerConfigHash: String
    ) throws -> ReaderPageTranslationDocument? {
        try read { db in
            try Self.fetchReaderPageTranslationDocument(
                db: db,
                sourceKey: sourceKey,
                comicID: comicID,
                chapterID: chapterID,
                pageIndex: pageIndex,
                targetLanguage: targetLanguage,
                imageRequestKey: imageRequestKey,
                pipelineVersion: pipelineVersion,
                providerConfigHash: providerConfigHash
            )
        }
    }

    public func upsertReaderPageTranslationDocument(_ document: ReaderPageTranslationDocument) throws -> ReaderPageTranslationDocument {
        try write { db in
            let now = Int64(Date().timeIntervalSince1970)
            let updated = ReaderPageTranslationDocument(
                id: document.id,
                sourceKey: document.sourceKey,
                comicID: document.comicID,
                chapterID: document.chapterID,
                pageIndex: document.pageIndex,
                sourceLanguage: document.sourceLanguage,
                targetLanguage: document.targetLanguage,
                provider: document.provider,
                status: document.status,
                currentStage: document.currentStage,
                imageRequestKey: document.imageRequestKey,
                imageFingerprint: document.imageFingerprint,
                pipelineVersion: document.pipelineVersion,
                providerConfigHash: document.providerConfigHash,
                blocks: document.blocks,
                cleanupRegions: document.cleanupRegions,
                renderedAsset: document.renderedAsset,
                errorText: document.errorText,
                updatedAt: now
            )
            try db.execute(
                sql: """
                INSERT INTO reader_page_translation_documents (
                    source_key, comic_id, chapter_id, page_index, source_language, target_language,
                    provider, status, current_stage, image_request_key, image_fingerprint,
                    pipeline_version, provider_config_hash, document_json, rendered_asset_path, error_text, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_key, comic_id, chapter_id, page_index, target_language, image_request_key, pipeline_version, provider_config_hash)
                DO UPDATE SET
                    source_language = excluded.source_language,
                    provider = excluded.provider,
                    status = excluded.status,
                    current_stage = excluded.current_stage,
                    image_fingerprint = excluded.image_fingerprint,
                    document_json = excluded.document_json,
                    rendered_asset_path = excluded.rendered_asset_path,
                    error_text = excluded.error_text,
                    updated_at = excluded.updated_at;
                """,
                arguments: [
                    updated.sourceKey,
                    updated.comicID,
                    updated.chapterID,
                    updated.pageIndex,
                    updated.sourceLanguage?.rawValue,
                    updated.targetLanguage.rawValue,
                    updated.provider,
                    updated.status.rawValue,
                    updated.currentStage.rawValue,
                    updated.imageRequestKey,
                    updated.imageFingerprint,
                    updated.pipelineVersion,
                    updated.providerConfigHash,
                    Self.encodeReaderPageTranslationDocumentJSON(updated),
                    updated.renderedAsset?.localFilePath,
                    Self.normalizedOptionalString(updated.errorText),
                    updated.updatedAt,
                ]
            )
            return try Self.fetchReaderPageTranslationDocument(
                db: db,
                sourceKey: updated.sourceKey,
                comicID: updated.comicID,
                chapterID: updated.chapterID,
                pageIndex: updated.pageIndex,
                targetLanguage: updated.targetLanguage,
                imageRequestKey: updated.imageRequestKey,
                pipelineVersion: updated.pipelineVersion,
                providerConfigHash: updated.providerConfigHash
            ) ?? updated
        }
    }

    // MARK: - Downloads

    public func upsertDownloadChapter(
        sourceKey: String,
        comicID: String,
        comicTitle: String,
        coverURL: String?,
        comicDescription: String?,
        chapterID: String,
        chapterTitle: String,
        status: DownloadStatus,
        totalPages: Int,
        downloadedPages: Int,
        directoryPath: String,
        errorMessage: String?
    ) throws {
        try write { db in
            let now = Int64(Date().timeIntervalSince1970)
            try db.execute(
                sql: """
                INSERT INTO downloads (
                    source_key, comic_id, comic_title, cover_url, chapter_id, chapter_title,
                    comic_description, status, total_pages, downloaded_pages, directory_path, error_message, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_key, comic_id, chapter_id)
                DO UPDATE SET
                    comic_title = excluded.comic_title,
                    cover_url = excluded.cover_url,
                    comic_description = excluded.comic_description,
                    chapter_title = excluded.chapter_title,
                    status = excluded.status,
                    total_pages = excluded.total_pages,
                    downloaded_pages = excluded.downloaded_pages,
                    directory_path = excluded.directory_path,
                    error_message = excluded.error_message,
                    updated_at = excluded.updated_at;
                """,
                arguments: [
                    sourceKey,
                    comicID,
                    comicTitle,
                    coverURL,
                    chapterID,
                    chapterTitle,
                    Self.normalizedOptionalString(comicDescription),
                    status.rawValue,
                    totalPages,
                    downloadedPages,
                    directoryPath,
                    errorMessage,
                    now,
                    now,
                ]
            )
        }
    }

    public func updateDownloadProgress(
        sourceKey: String,
        comicID: String,
        chapterID: String,
        status: DownloadStatus,
        downloadedPages: Int,
        totalPages: Int,
        errorMessage: String?
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE downloads
                SET status = ?, downloaded_pages = ?, total_pages = ?, error_message = ?, updated_at = ?
                WHERE source_key = ? AND comic_id = ? AND chapter_id = ?;
                """,
                arguments: [
                    status.rawValue,
                    downloadedPages,
                    totalPages,
                    errorMessage,
                    Int64(Date().timeIntervalSince1970),
                    sourceKey,
                    comicID,
                    chapterID,
                ]
            )
        }
    }

    public func listDownloadChapters(limit: Int = 300) throws -> [DownloadChapterItem] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id, chapter_title,
                       status, total_pages, downloaded_pages, directory_path, error_message, created_at, updated_at
                FROM downloads
                ORDER BY updated_at DESC
                LIMIT ?;
                """,
                arguments: [limit]
            ).map(Self.downloadChapterItem(from:))
        }
    }

    public func getDownloadChapter(
        sourceKey: String,
        comicID: String,
        chapterID: String
    ) throws -> DownloadChapterItem? {
        try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id, chapter_title,
                       status, total_pages, downloaded_pages, directory_path, error_message, created_at, updated_at
                FROM downloads
                WHERE source_key = ? AND comic_id = ? AND chapter_id = ?
                LIMIT 1;
                """,
                arguments: [sourceKey, comicID, chapterID]
            ) else {
                return nil
            }
            return Self.downloadChapterItem(from: row)
        }
    }

    public func upsertOfflineChapter(
        sourceKey: String,
        comicID: String,
        comicTitle: String,
        coverURL: String?,
        comicDescription: String?,
        chapterID: String,
        chapterTitle: String,
        pageCount: Int,
        verifiedPageCount: Int,
        integrityStatus: OfflineChapterIntegrityStatus,
        directoryPath: String,
        downloadedAt: Int64? = nil,
        lastVerifiedAt: Int64? = nil
    ) throws {
        try write { db in
            try Self.upsertOfflineChapter(
                db: db,
                sourceKey: sourceKey,
                comicID: comicID,
                comicTitle: comicTitle,
                coverURL: coverURL,
                comicDescription: comicDescription,
                chapterID: chapterID,
                chapterTitle: chapterTitle,
                pageCount: pageCount,
                verifiedPageCount: verifiedPageCount,
                integrityStatus: integrityStatus,
                directoryPath: directoryPath,
                downloadedAt: downloadedAt,
                lastVerifiedAt: lastVerifiedAt
            )
        }
    }

    public func listOfflineChapters(limit: Int = 600) throws -> [OfflineChapterAsset] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id,
                       chapter_title, page_count, verified_page_count, integrity_status, directory_path,
                       downloaded_at, last_verified_at, updated_at
                FROM offline_chapters
                ORDER BY updated_at DESC
                LIMIT ?;
                """,
                arguments: [limit]
            ).map(Self.offlineChapterAsset(from:))
        }
    }

    public func getOfflineChapter(
        sourceKey: String,
        comicID: String,
        chapterID: String
    ) throws -> OfflineChapterAsset? {
        try read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id,
                       chapter_title, page_count, verified_page_count, integrity_status, directory_path,
                       downloaded_at, last_verified_at, updated_at
                FROM offline_chapters
                WHERE source_key = ? AND comic_id = ? AND chapter_id = ?
                LIMIT 1;
                """,
                arguments: [sourceKey, comicID, chapterID]
            ) else {
                return nil
            }
            return Self.offlineChapterAsset(from: row)
        }
    }

    public func renameOfflineComic(sourceKey: String, comicID: String, comicTitle: String) throws {
        try write { db in
            try db.execute(
                sql: """
                UPDATE offline_chapters
                SET comic_title = ?, updated_at = ?
                WHERE source_key = ? AND comic_id = ?;
                """,
                arguments: [comicTitle, Int64(Date().timeIntervalSince1970), sourceKey, comicID]
            )
        }
    }

    public func replaceOfflineChapters(with items: [OfflineChapterAsset]) throws {
        try immediateTransaction { db in
            try db.execute(sql: "DELETE FROM offline_chapters;")
            for item in items {
                try Self.upsertOfflineChapter(
                    db: db,
                    sourceKey: item.sourceKey,
                    comicID: item.comicID,
                    comicTitle: item.comicTitle,
                    coverURL: item.coverURL,
                    comicDescription: item.comicDescription,
                    chapterID: item.chapterID,
                    chapterTitle: item.chapterTitle,
                    pageCount: item.pageCount,
                    verifiedPageCount: item.verifiedPageCount,
                    integrityStatus: item.integrityStatus,
                    directoryPath: item.directoryPath,
                    downloadedAt: item.downloadedAt,
                    lastVerifiedAt: item.lastVerifiedAt
                )
            }
        }
    }

    public func deleteOfflineChapters(ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        return try immediateTransaction { db in
            var paths: [String] = []
            for id in ids {
                if let path = try String.fetchOne(
                    db,
                    sql: "SELECT directory_path FROM offline_chapters WHERE id = ? LIMIT 1;",
                    arguments: [id]
                ) {
                    paths.append(path)
                }
                try db.execute(
                    sql: "DELETE FROM offline_chapters WHERE id = ?;",
                    arguments: [id]
                )
            }
            return paths
        }
    }

    public func clearOfflineChapters() throws -> [String] {
        try write { db in
            let paths = try String.fetchAll(db, sql: "SELECT directory_path FROM offline_chapters;")
            try db.execute(sql: "DELETE FROM offline_chapters;")
            return paths
        }
    }

    public func deleteDownloadTask(
        sourceKey: String,
        comicID: String,
        chapterID: String
    ) throws {
        try write { db in
            try db.execute(
                sql: "DELETE FROM downloads WHERE source_key = ? AND comic_id = ? AND chapter_id = ?;",
                arguments: [sourceKey, comicID, chapterID]
            )
        }
    }

    public func deleteDownloadChapters(ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        return try immediateTransaction { db in
            var paths: [String] = []
            for id in ids {
                if let path = try String.fetchOne(
                    db,
                    sql: "SELECT directory_path FROM downloads WHERE id = ? LIMIT 1;",
                    arguments: [id]
                ) {
                    paths.append(path)
                }
                try db.execute(
                    sql: "DELETE FROM downloads WHERE id = ?;",
                    arguments: [id]
                )
            }
            return paths
        }
    }

    public func deleteDownloadChapter(id: Int64) throws -> String? {
        try write { db in
            let directoryPath = try String.fetchOne(
                db,
                sql: "SELECT directory_path FROM downloads WHERE id = ? LIMIT 1;",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM downloads WHERE id = ?;",
                arguments: [id]
            )
            return directoryPath
        }
    }

    public func clearDownloadChapters() throws -> [String] {
        try write { db in
            let paths = try String.fetchAll(db, sql: "SELECT directory_path FROM downloads;")
            try db.execute(sql: "DELETE FROM downloads;")
            return paths
        }
    }

    // MARK: - Private Helpers

    private func read<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try dbQueue.read(body)
        } catch {
            throw Self.executeError(error)
        }
    }

    private func write<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try dbQueue.writeWithoutTransaction(body)
        } catch {
            throw Self.executeError(error)
        }
    }

    private func immediateTransaction<T>(_ body: (Database) throws -> T) throws -> T {
        do {
            return try dbQueue.writeWithoutTransaction { db in
                var result: Result<T, Error>?
                try db.inTransaction(.immediate) {
                    do {
                        result = .success(try body(db))
                        return .commit
                    } catch {
                        result = .failure(error)
                        return .rollback
                    }
                }
                guard let result else {
                    throw SQLiteStoreError.execute("transaction did not produce a result")
                }
                return try result.get()
            }
        } catch {
            throw Self.executeError(error)
        }
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_tables") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS favorites (
                    id TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    cover_url TEXT,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (id, source_key)
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS favorite_categories (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE,
                    sort_order INTEGER NOT NULL,
                    created_at INTEGER NOT NULL
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS favorite_category_memberships (
                    category_id INTEGER NOT NULL,
                    comic_id TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY (category_id, comic_id, source_key),
                    FOREIGN KEY (category_id) REFERENCES favorite_categories(id) ON DELETE CASCADE
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    comic_id TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    cover_url TEXT,
                    author TEXT,
                    tags_json TEXT,
                    chapter_id TEXT,
                    chapter TEXT,
                    page INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS downloads (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_key TEXT NOT NULL,
                    comic_id TEXT NOT NULL,
                    comic_title TEXT NOT NULL,
                    cover_url TEXT,
                    comic_description TEXT,
                    chapter_id TEXT NOT NULL,
                    chapter_title TEXT NOT NULL,
                    status TEXT NOT NULL,
                    total_pages INTEGER NOT NULL,
                    downloaded_pages INTEGER NOT NULL,
                    directory_path TEXT NOT NULL,
                    error_message TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (source_key, comic_id, chapter_id)
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS offline_chapters (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_key TEXT NOT NULL,
                    comic_id TEXT NOT NULL,
                    comic_title TEXT NOT NULL,
                    cover_url TEXT,
                    comic_description TEXT,
                    chapter_id TEXT NOT NULL,
                    chapter_title TEXT NOT NULL,
                    page_count INTEGER NOT NULL,
                    verified_page_count INTEGER NOT NULL DEFAULT 0,
                    integrity_status TEXT NOT NULL DEFAULT 'incomplete',
                    directory_path TEXT NOT NULL,
                    downloaded_at INTEGER NOT NULL,
                    last_verified_at INTEGER NOT NULL DEFAULT 0,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (source_key, comic_id, chapter_id)
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS tracker_accounts (
                    provider TEXT PRIMARY KEY,
                    display_name TEXT NOT NULL,
                    remote_user_id TEXT NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS tracker_bindings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    provider TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    comic_id TEXT NOT NULL,
                    remote_media_id TEXT NOT NULL,
                    remote_title TEXT NOT NULL,
                    remote_cover_url TEXT,
                    last_synced_progress INTEGER NOT NULL DEFAULT 0,
                    last_synced_status TEXT,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (provider, source_key, comic_id)
                );
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS tracker_sync_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    provider TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    comic_id TEXT NOT NULL,
                    remote_media_id TEXT NOT NULL,
                    target_progress INTEGER NOT NULL,
                    target_status TEXT,
                    state TEXT NOT NULL,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (provider, source_key, comic_id)
                );
                """
            )
        }

        migrator.registerMigration("v2_history_compat") { db in
            try ensureHistorySchema(db: db)
        }

        migrator.registerMigration("v3_downloads_compat") { db in
            try ensureDownloadsSchema(db: db)
        }

        migrator.registerMigration("v4_create_indexes") { db in
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_favorites_created_at ON favorites(created_at DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_favorite_categories_sort_order ON favorite_categories(sort_order ASC, created_at ASC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_favorite_category_memberships_category_id ON favorite_category_memberships(category_id);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_favorite_category_memberships_comic_lookup ON favorite_category_memberships(comic_id, source_key);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_history_updated_at ON history(updated_at DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_history_lookup ON history(comic_id, source_key, chapter_id, updated_at DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_downloads_updated_at ON downloads(updated_at DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_offline_chapters_updated_at ON offline_chapters(updated_at DESC);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracker_bindings_lookup ON tracker_bindings(provider, source_key, comic_id);")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_tracker_sync_events_state ON tracker_sync_events(state, updated_at DESC);")
        }

        migrator.registerMigration("v5_reader_page_translations") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS reader_page_translations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_key TEXT NOT NULL,
                    comic_id TEXT NOT NULL,
                    chapter_id TEXT NOT NULL,
                    page_index INTEGER NOT NULL,
                    target_language TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    status TEXT NOT NULL,
                    image_request_key TEXT NOT NULL,
                    image_fingerprint TEXT NOT NULL,
                    overlays_json TEXT,
                    error_text TEXT,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (source_key, comic_id, chapter_id, page_index, target_language, image_request_key)
                );
                """
            )
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_reader_page_translations_lookup ON reader_page_translations(source_key, comic_id, chapter_id, target_language, updated_at DESC);"
            )
        }

        migrator.registerMigration("v6_reader_page_translation_documents") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS reader_page_translation_documents (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_key TEXT NOT NULL,
                    comic_id TEXT NOT NULL,
                    chapter_id TEXT NOT NULL,
                    page_index INTEGER NOT NULL,
                    source_language TEXT,
                    target_language TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    status TEXT NOT NULL,
                    current_stage TEXT NOT NULL,
                    image_request_key TEXT NOT NULL,
                    image_fingerprint TEXT NOT NULL,
                    pipeline_version TEXT NOT NULL,
                    provider_config_hash TEXT NOT NULL,
                    document_json TEXT NOT NULL,
                    rendered_asset_path TEXT,
                    error_text TEXT,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (source_key, comic_id, chapter_id, page_index, target_language, image_request_key, pipeline_version, provider_config_hash)
                );
                """
            )
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_reader_page_translation_documents_lookup ON reader_page_translation_documents(source_key, comic_id, chapter_id, target_language, updated_at DESC);"
            )
        }

        return migrator
    }

    private static func ensureHistorySchema(db: Database) throws {
        let requiredColumns: Set<String> = [
            "id", "comic_id", "source_key", "title", "cover_url", "chapter", "page", "updated_at",
        ]
        let copyableRequiredColumns: Set<String> = [
            "comic_id", "source_key", "title", "page", "updated_at",
        ]
        let existingColumns = try tableColumns("history", db: db)
        guard !existingColumns.isEmpty else { return }

        guard requiredColumns.isSubset(of: existingColumns) else {
            try db.execute(sql: "DROP TABLE IF EXISTS history_compat;")
            try db.execute(
                sql: """
                CREATE TABLE history_compat (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    comic_id TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    cover_url TEXT,
                    author TEXT,
                    tags_json TEXT,
                    chapter_id TEXT,
                    chapter TEXT,
                    page INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """
            )

            if copyableRequiredColumns.isSubset(of: existingColumns) {
                let preferredCopyOrder = [
                    "id",
                    "comic_id",
                    "source_key",
                    "title",
                    "cover_url",
                    "author",
                    "tags_json",
                    "chapter_id",
                    "chapter",
                    "page",
                    "updated_at",
                ]
                let copyColumns = preferredCopyOrder.filter(existingColumns.contains)
                if !copyColumns.isEmpty {
                    let columnsSQL = copyColumns.joined(separator: ", ")
                    try db.execute(sql: "INSERT INTO history_compat (\(columnsSQL)) SELECT \(columnsSQL) FROM history;")
                }
            }

            try db.execute(sql: "DROP TABLE history;")
            try db.execute(sql: "ALTER TABLE history_compat RENAME TO history;")
            return
        }

        if !existingColumns.contains("author") {
            try db.execute(sql: "ALTER TABLE history ADD COLUMN author TEXT;")
        }
        if !existingColumns.contains("tags_json") {
            try db.execute(sql: "ALTER TABLE history ADD COLUMN tags_json TEXT;")
        }
        if !existingColumns.contains("chapter_id") {
            try db.execute(sql: "ALTER TABLE history ADD COLUMN chapter_id TEXT;")
        }
    }

    private static func ensureDownloadsSchema(db: Database) throws {
        let existingColumns = try tableColumns("downloads", db: db)
        guard !existingColumns.isEmpty else { return }
        if !existingColumns.contains("comic_description") {
            try db.execute(sql: "ALTER TABLE downloads ADD COLUMN comic_description TEXT;")
        }

        let offlineColumns = try tableColumns("offline_chapters", db: db)
        guard !offlineColumns.isEmpty else { return }
        if !offlineColumns.contains("verified_page_count") {
            try db.execute(sql: "ALTER TABLE offline_chapters ADD COLUMN verified_page_count INTEGER NOT NULL DEFAULT 0;")
        }
        if !offlineColumns.contains("integrity_status") {
            try db.execute(sql: "ALTER TABLE offline_chapters ADD COLUMN integrity_status TEXT NOT NULL DEFAULT 'incomplete';")
        }
        if !offlineColumns.contains("last_verified_at") {
            try db.execute(sql: "ALTER TABLE offline_chapters ADD COLUMN last_verified_at INTEGER NOT NULL DEFAULT 0;")
        }
    }

    private static func tableColumns(_ tableName: String, db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName));")
        return Set(rows.compactMap { row in
            let name: String? = row["name"]
            return name
        })
    }

    private static func fetchReaderPageTranslationDocument(
        db: Database,
        sourceKey: String,
        comicID: String,
        chapterID: String,
        pageIndex: Int,
        targetLanguage: ReaderTranslationLanguage,
        imageRequestKey: String,
        pipelineVersion: String,
        providerConfigHash: String
    ) throws -> ReaderPageTranslationDocument? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, source_key, comic_id, chapter_id, page_index, source_language, target_language,
                   provider, status, current_stage, image_request_key, image_fingerprint,
                   pipeline_version, provider_config_hash, document_json, rendered_asset_path, error_text, updated_at
            FROM reader_page_translation_documents
            WHERE source_key = ? AND comic_id = ? AND chapter_id = ? AND page_index = ?
              AND target_language = ? AND image_request_key = ?
              AND pipeline_version = ? AND provider_config_hash = ?
            LIMIT 1;
            """,
            arguments: [
                sourceKey,
                comicID,
                chapterID,
                pageIndex,
                targetLanguage.rawValue,
                imageRequestKey,
                pipelineVersion,
                providerConfigHash,
            ]
        ) else {
            return nil
        }
        return try readerPageTranslationDocument(from: row)
    }

    private static func fetchTrackerBinding(
        db: Database,
        provider: TrackerProvider,
        sourceKey: String,
        comicID: String
    ) throws -> TrackerBinding? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, provider, source_key, comic_id, remote_media_id, remote_title, remote_cover_url,
                   last_synced_progress, last_synced_status, updated_at
            FROM tracker_bindings
            WHERE provider = ? AND source_key = ? AND comic_id = ?
            LIMIT 1;
            """,
            arguments: [provider.rawValue, sourceKey, comicID]
        ) else {
            return nil
        }
        return trackerBinding(from: row)
    }

    private static func fetchTrackerSyncEvents(
        db: Database,
        limit: Int,
        provider: TrackerProvider?,
        sourceKey: String?,
        comicID: String?
    ) throws -> [TrackerSyncEvent] {
        let rows: [Row]
        switch (provider, sourceKey, comicID) {
        case let (.some(provider), .some(sourceKey), .some(comicID)):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                       state, retry_count, last_error, created_at, updated_at
                FROM tracker_sync_events
                WHERE provider = ? AND source_key = ? AND comic_id = ?
                ORDER BY updated_at ASC
                LIMIT ?;
                """,
                arguments: [provider.rawValue, sourceKey, comicID, limit]
            )
        case let (.some(provider), .some(sourceKey), .none):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                       state, retry_count, last_error, created_at, updated_at
                FROM tracker_sync_events
                WHERE provider = ? AND source_key = ?
                ORDER BY updated_at ASC
                LIMIT ?;
                """,
                arguments: [provider.rawValue, sourceKey, limit]
            )
        case let (.some(provider), .none, .some(comicID)):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                       state, retry_count, last_error, created_at, updated_at
                FROM tracker_sync_events
                WHERE provider = ? AND comic_id = ?
                ORDER BY updated_at ASC
                LIMIT ?;
                """,
                arguments: [provider.rawValue, comicID, limit]
            )
        case let (.some(provider), .none, .none):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                       state, retry_count, last_error, created_at, updated_at
                FROM tracker_sync_events
                WHERE provider = ?
                ORDER BY updated_at ASC
                LIMIT ?;
                """,
                arguments: [provider.rawValue, limit]
            )
        case let (.none, .some(sourceKey), .some(comicID)):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                       state, retry_count, last_error, created_at, updated_at
                FROM tracker_sync_events
                WHERE source_key = ? AND comic_id = ?
                ORDER BY updated_at ASC
                LIMIT ?;
                """,
                arguments: [sourceKey, comicID, limit]
            )
        case let (.none, .some(sourceKey), .none):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                       state, retry_count, last_error, created_at, updated_at
                FROM tracker_sync_events
                WHERE source_key = ?
                ORDER BY updated_at ASC
                LIMIT ?;
                """,
                arguments: [sourceKey, limit]
            )
        case let (.none, .none, .some(comicID)):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                       state, retry_count, last_error, created_at, updated_at
                FROM tracker_sync_events
                WHERE comic_id = ?
                ORDER BY updated_at ASC
                LIMIT ?;
                """,
                arguments: [comicID, limit]
            )
        case (.none, .none, .none):
            rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
                       state, retry_count, last_error, created_at, updated_at
                FROM tracker_sync_events
                ORDER BY updated_at ASC
                LIMIT ?;
                """,
                arguments: [limit]
            )
        }
        return rows.compactMap(trackerSyncEvent(from:))
    }

    private static func upsertHistory(
        db: Database,
        comicID: String,
        sourceKey: String,
        title: String,
        coverURL: String?,
        author: String?,
        tags: [String],
        chapterID: String?,
        chapter: String?,
        page: Int
    ) throws -> ReadingHistoryItem {
        let now = Int64(Date().timeIntervalSince1970)
        let normalizedAuthor = normalizedOptionalString(author)
        let normalizedChapterID = normalizedOptionalString(chapterID)
        let normalizedChapter = normalizedOptionalString(chapter)
        let tagsJSON = encodeTagsJSON(tags)

        try db.execute(
            sql: """
            UPDATE history
            SET title = ?, cover_url = ?, author = ?, tags_json = ?, chapter_id = ?, chapter = ?, page = ?, updated_at = ?
            WHERE comic_id = ? AND source_key = ? AND (
                (chapter_id IS NULL AND ? IS NULL) OR chapter_id = ? OR
                ((chapter_id IS NULL OR ? IS NULL) AND ((chapter IS NULL AND ? IS NULL) OR chapter = ?))
            );
            """,
            arguments: [
                title,
                coverURL,
                normalizedAuthor,
                tagsJSON,
                normalizedChapterID,
                normalizedChapter,
                page,
                now,
                comicID,
                sourceKey,
                normalizedChapterID,
                normalizedChapterID,
                normalizedChapterID,
                normalizedChapter,
                normalizedChapter,
            ]
        )

        if let existing = try fetchHistoryItem(
            db: db,
            comicID: comicID,
            sourceKey: sourceKey,
            chapterID: normalizedChapterID,
            chapter: normalizedChapter
        ) {
            return existing
        }

        try db.execute(
            sql: """
            INSERT INTO history (comic_id, source_key, title, cover_url, author, tags_json, chapter_id, chapter, page, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            arguments: [
                comicID,
                sourceKey,
                title,
                coverURL,
                normalizedAuthor,
                tagsJSON,
                normalizedChapterID,
                normalizedChapter,
                page,
                now,
            ]
        )

        guard let inserted = try fetchHistoryItem(
            db: db,
            comicID: comicID,
            sourceKey: sourceKey,
            chapterID: normalizedChapterID,
            chapter: normalizedChapter
        ) else {
            throw SQLiteStoreError.execute("history row not found after upsert")
        }
        return inserted
    }

    private static func fetchHistoryItem(
        db: Database,
        comicID: String,
        sourceKey: String,
        chapterID: String?,
        chapter: String?
    ) throws -> ReadingHistoryItem? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT id, comic_id, source_key, title, cover_url, author, tags_json, chapter_id, chapter, page, updated_at
            FROM history
            WHERE comic_id = ? AND source_key = ? AND (
                (chapter_id IS NULL AND ? IS NULL) OR chapter_id = ? OR
                ((chapter_id IS NULL OR ? IS NULL) AND ((chapter IS NULL AND ? IS NULL) OR chapter = ?))
            )
            ORDER BY updated_at DESC, id DESC
            LIMIT 1;
            """,
            arguments: [comicID, sourceKey, chapterID, chapterID, chapterID, chapter, chapter]
        ) else {
            return nil
        }
        return readingHistoryItem(from: row)
    }

    private static func upsertOfflineChapter(
        db: Database,
        sourceKey: String,
        comicID: String,
        comicTitle: String,
        coverURL: String?,
        comicDescription: String?,
        chapterID: String,
        chapterTitle: String,
        pageCount: Int,
        verifiedPageCount: Int,
        integrityStatus: OfflineChapterIntegrityStatus,
        directoryPath: String,
        downloadedAt: Int64?,
        lastVerifiedAt: Int64?
    ) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let effectiveDownloadedAt = downloadedAt ?? now
        let effectiveLastVerifiedAt = lastVerifiedAt ?? now
        try db.execute(
            sql: """
            INSERT INTO offline_chapters (
                source_key, comic_id, comic_title, cover_url, comic_description, chapter_id,
                chapter_title, page_count, verified_page_count, integrity_status, directory_path,
                downloaded_at, last_verified_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_key, comic_id, chapter_id)
            DO UPDATE SET
                comic_title = excluded.comic_title,
                cover_url = excluded.cover_url,
                comic_description = excluded.comic_description,
                chapter_title = excluded.chapter_title,
                page_count = excluded.page_count,
                verified_page_count = excluded.verified_page_count,
                integrity_status = excluded.integrity_status,
                directory_path = excluded.directory_path,
                downloaded_at = excluded.downloaded_at,
                last_verified_at = excluded.last_verified_at,
                updated_at = excluded.updated_at;
            """,
            arguments: [
                sourceKey,
                comicID,
                comicTitle,
                Self.normalizedOptionalString(coverURL),
                Self.normalizedOptionalString(comicDescription),
                chapterID,
                chapterTitle,
                pageCount,
                verifiedPageCount,
                integrityStatus.rawValue,
                directoryPath,
                effectiveDownloadedAt,
                effectiveLastVerifiedAt,
                now,
            ]
        )
    }

    private static func favoriteComic(from row: Row) -> FavoriteComic {
        FavoriteComic(
            id: row["id"],
            sourceKey: row["source_key"],
            title: row["title"],
            coverURL: row["cover_url"],
            createdAt: row["created_at"]
        )
    }

    private static func libraryCategory(from row: Row) -> LibraryCategory {
        let sortOrder: Int = row["sort_order"]
        return LibraryCategory(
            id: row["id"],
            name: row["name"],
            sortOrder: sortOrder,
            createdAt: row["created_at"]
        )
    }

    private static func trackerAccount(from row: Row) -> TrackerAccount? {
        let providerRaw: String = row["provider"]
        guard let provider = TrackerProvider(rawValue: providerRaw) else { return nil }
        return TrackerAccount(
            provider: provider,
            displayName: row["display_name"],
            remoteUserID: row["remote_user_id"],
            updatedAt: row["updated_at"]
        )
    }

    private static func trackerBinding(from row: Row) -> TrackerBinding? {
        let providerRaw: String = row["provider"]
        guard let provider = TrackerProvider(rawValue: providerRaw) else { return nil }
        let lastSyncedStatusRaw: String? = row["last_synced_status"]
        return TrackerBinding(
            id: row["id"],
            provider: provider,
            sourceKey: row["source_key"],
            comicID: row["comic_id"],
            remoteMediaID: row["remote_media_id"],
            remoteTitle: row["remote_title"],
            remoteCoverURL: row["remote_cover_url"],
            lastSyncedProgress: row["last_synced_progress"],
            lastSyncedStatus: lastSyncedStatusRaw.flatMap(TrackerReadingStatus.init(rawValue:)),
            updatedAt: row["updated_at"]
        )
    }

    private static func trackerSyncEvent(from row: Row) -> TrackerSyncEvent? {
        let providerRaw: String = row["provider"]
        let stateRaw: String = row["state"]
        guard let provider = TrackerProvider(rawValue: providerRaw),
              let state = TrackerSyncEventState(rawValue: stateRaw)
        else {
            return nil
        }
        let targetStatusRaw: String? = row["target_status"]
        return TrackerSyncEvent(
            id: row["id"],
            provider: provider,
            sourceKey: row["source_key"],
            comicID: row["comic_id"],
            remoteMediaID: row["remote_media_id"],
            targetProgress: row["target_progress"],
            targetStatus: targetStatusRaw.flatMap(TrackerReadingStatus.init(rawValue:)),
            state: state,
            retryCount: row["retry_count"],
            lastError: row["last_error"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func readingHistoryItem(from row: Row) -> ReadingHistoryItem {
        let tagsJSON: String? = row["tags_json"]
        let page: Int = row["page"]
        return ReadingHistoryItem(
            id: row["id"],
            comicID: row["comic_id"],
            sourceKey: row["source_key"],
            title: row["title"],
            coverURL: row["cover_url"],
            author: row["author"],
            tags: decodeTagsJSON(tagsJSON),
            chapterID: row["chapter_id"],
            chapter: row["chapter"],
            page: page,
            updatedAt: row["updated_at"]
        )
    }

    private static func downloadChapterItem(from row: Row) -> DownloadChapterItem {
        let statusRaw: String = row["status"]
        return DownloadChapterItem(
            id: row["id"],
            sourceKey: row["source_key"],
            comicID: row["comic_id"],
            comicTitle: row["comic_title"],
            coverURL: row["cover_url"],
            comicDescription: row["comic_description"],
            chapterID: row["chapter_id"],
            chapterTitle: row["chapter_title"],
            status: DownloadStatus(rawValue: statusRaw) ?? .failed,
            totalPages: row["total_pages"],
            downloadedPages: row["downloaded_pages"],
            directoryPath: row["directory_path"],
            errorMessage: row["error_message"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func offlineChapterAsset(from row: Row) -> OfflineChapterAsset {
        let integrityStatusRaw: String = row["integrity_status"]
        return OfflineChapterAsset(
            id: row["id"],
            sourceKey: row["source_key"],
            comicID: row["comic_id"],
            comicTitle: row["comic_title"],
            coverURL: row["cover_url"],
            comicDescription: row["comic_description"],
            chapterID: row["chapter_id"],
            chapterTitle: row["chapter_title"],
            pageCount: row["page_count"],
            verifiedPageCount: row["verified_page_count"],
            integrityStatus: OfflineChapterIntegrityStatus(rawValue: integrityStatusRaw) ?? .incomplete,
            directoryPath: row["directory_path"],
            downloadedAt: row["downloaded_at"],
            lastVerifiedAt: row["last_verified_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func readerPageTranslationDocument(from row: Row) throws -> ReaderPageTranslationDocument {
        let targetLanguageRaw: String = row["target_language"]
        let statusRaw: String = row["status"]
        let currentStageRaw: String = row["current_stage"]
        let documentJSON: String = row["document_json"]
        guard let targetLanguage = ReaderTranslationLanguage(rawValue: targetLanguageRaw),
              let status = ReaderPageTranslationStatus(rawValue: statusRaw),
              let currentStage = ReaderPageTranslationStage(rawValue: currentStageRaw)
        else {
            throw SQLiteStoreError.execute("invalid reader translation document row")
        }

        let decoded = try decodeReaderPageTranslationDocumentJSON(documentJSON)
        let sourceLanguageRaw: String? = row["source_language"]
        let sourceLanguage = sourceLanguageRaw.flatMap(ReaderTranslationLanguage.init(rawValue:))
        return ReaderPageTranslationDocument(
            id: row["id"],
            sourceKey: row["source_key"],
            comicID: row["comic_id"],
            chapterID: row["chapter_id"],
            pageIndex: row["page_index"],
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            provider: row["provider"],
            status: status,
            currentStage: currentStage,
            imageRequestKey: row["image_request_key"],
            imageFingerprint: row["image_fingerprint"],
            pipelineVersion: row["pipeline_version"],
            providerConfigHash: row["provider_config_hash"],
            blocks: decoded.blocks,
            cleanupRegions: decoded.cleanupRegions,
            renderedAsset: decoded.renderedAsset,
            errorText: row["error_text"],
            updatedAt: row["updated_at"]
        )
    }

    private static func encodeReaderPageTranslationDocumentJSON(_ document: ReaderPageTranslationDocument) -> String {
        do {
            let data = try JSONEncoder().encode(document)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SQLiteStoreError.execute("reader translation document encoding failed")
            }
            return text
        } catch let error as SQLiteStoreError {
            fatalError(error.localizedDescription)
        } catch {
            fatalError("reader translation document encoding failed: \(error.localizedDescription)")
        }
    }

    private static func decodeReaderPageTranslationDocumentJSON(_ text: String) throws -> ReaderPageTranslationDocument {
        guard let data = text.data(using: .utf8) else {
            throw SQLiteStoreError.execute("reader translation document decode failed")
        }
        do {
            return try JSONDecoder().decode(ReaderPageTranslationDocument.self, from: data)
        } catch {
            throw SQLiteStoreError.execute("reader translation document decode failed: \(error.localizedDescription)")
        }
    }

    private static func encodeTagsJSON(_ tags: [String]) -> String? {
        let normalized = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: normalized, options: []),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private static func decodeTagsJSON(_ text: String?) -> [String] {
        guard let text,
              let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any]
        else {
            return []
        }
        return raw.map { String(describing: $0) }.filter { !$0.isEmpty }
    }

    private static func normalizedOptionalString(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func splitFavoriteComicKey(_ key: String) -> (sourceKey: String, comicID: String)? {
        let parts = key.components(separatedBy: "::")
        guard parts.count == 2 else { return nil }
        return (sourceKey: parts[0], comicID: parts[1])
    }

    private static func openDatabaseError(_ error: Error) -> SQLiteStoreError {
        if let storeError = error as? SQLiteStoreError {
            return storeError
        }
        if let dbError = error as? DatabaseError {
            return .openDatabase(dbError.description)
        }
        return .openDatabase(error.localizedDescription)
    }

    private static func executeError(_ error: Error) -> SQLiteStoreError {
        if let storeError = error as? SQLiteStoreError {
            return storeError
        }
        if let dbError = error as? DatabaseError {
            return .execute(dbError.description)
        }
        return .execute(error.localizedDescription)
    }
}
