import Foundation
import SQLite3

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
    private var db: OpaquePointer?

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        if sqlite3_open(databaseURL.path, &handle) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_close(handle)
            throw SQLiteStoreError.openDatabase(message)
        }

        self.db = handle
        try Self.exec(db: handle, "PRAGMA journal_mode = WAL;")
        try Self.exec(db: handle, "PRAGMA synchronous = NORMAL;")
        try Self.exec(db: handle, "PRAGMA temp_store = MEMORY;")
        try Self.exec(db: handle, "PRAGMA foreign_keys = ON;")
        try Self.exec(db: handle, "PRAGMA busy_timeout = 3000;")
        try Self.exec(
            db: handle,
            """
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
        try Self.exec(
            db: handle,
            """
            CREATE TABLE IF NOT EXISTS favorite_categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                sort_order INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            );
            """
        )
        try Self.exec(
            db: handle,
            """
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

        try Self.exec(
            db: handle,
            """
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
        try Self.ensureHistorySchema(db: handle)
        try Self.exec(
            db: handle,
            """
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
        try Self.exec(
            db: handle,
            """
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
        try Self.exec(
            db: handle,
            """
            CREATE TABLE IF NOT EXISTS tracker_accounts (
                provider TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                remote_user_id TEXT NOT NULL,
                updated_at INTEGER NOT NULL
            );
            """
        )
        try Self.exec(
            db: handle,
            """
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
        try Self.exec(
            db: handle,
            """
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
        try Self.ensureDownloadsSchema(db: handle)
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_favorites_created_at ON favorites(created_at DESC);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_favorite_categories_sort_order ON favorite_categories(sort_order ASC, created_at ASC);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_favorite_category_memberships_category_id ON favorite_category_memberships(category_id);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_favorite_category_memberships_comic_lookup ON favorite_category_memberships(comic_id, source_key);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_history_updated_at ON history(updated_at DESC);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_history_lookup ON history(comic_id, source_key, chapter_id, updated_at DESC);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_downloads_updated_at ON downloads(updated_at DESC);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_offline_chapters_updated_at ON offline_chapters(updated_at DESC);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_tracker_bindings_lookup ON tracker_bindings(provider, source_key, comic_id);")
        try Self.exec(db: handle, "CREATE INDEX IF NOT EXISTS idx_tracker_sync_events_state ON tracker_sync_events(state, updated_at DESC);")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    // MARK: - Favorites

    public func upsertFavorite(_ comic: FavoriteComic) throws {
        let sql = """
        INSERT INTO favorites (id, source_key, title, cover_url, created_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id, source_key)
        DO UPDATE SET title = excluded.title, cover_url = excluded.cover_url;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bind(text: comic.id, at: 1, to: stmt)
        try bind(text: comic.sourceKey, at: 2, to: stmt)
        try bind(text: comic.title, at: 3, to: stmt)
        if let coverURL = comic.coverURL {
            try bind(text: coverURL, at: 4, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        try bind(int64: comic.createdAt, at: 5, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func listFavorites(limit: Int = 100) throws -> [FavoriteComic] {
        let sql = """
        SELECT id, source_key, title, cover_url, created_at
        FROM favorites
        ORDER BY created_at DESC
        LIMIT ?;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bind(int64: Int64(limit), at: 1, to: stmt)

        var items: [FavoriteComic] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            let sourceKey = String(cString: sqlite3_column_text(stmt, 1))
            let title = String(cString: sqlite3_column_text(stmt, 2))
            let coverURL = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let createdAt = sqlite3_column_int64(stmt, 4)

            items.append(
                FavoriteComic(
                    id: id,
                    sourceKey: sourceKey,
                    title: title,
                    coverURL: coverURL,
                    createdAt: createdAt
                )
            )
        }
        return items
    }

    public func replaceFavorites(with items: [FavoriteComic]) throws {
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try Self.exec(db: db, "DELETE FROM favorites;")
            let sql = """
            INSERT INTO favorites (id, source_key, title, cover_url, created_at)
            VALUES (?, ?, ?, ?, ?);
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }

            for item in items {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bind(text: item.id, at: 1, to: stmt)
                try bind(text: item.sourceKey, at: 2, to: stmt)
                try bind(text: item.title, at: 3, to: stmt)
                if let coverURL = item.coverURL {
                    try bind(text: coverURL, at: 4, to: stmt)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                try bind(int64: item.createdAt, at: 5, to: stmt)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
                }
            }
            try Self.exec(db: db, "COMMIT;")
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
        }
    }

    public func deleteFavorite(comicID: String, sourceKey: String) throws {
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let membershipSQL = """
            DELETE FROM favorite_category_memberships
            WHERE comic_id = ? AND source_key = ?;
            """
            let membershipStmt = try prepare(membershipSQL)
            defer { sqlite3_finalize(membershipStmt) }
            try bind(text: comicID, at: 1, to: membershipStmt)
            try bind(text: sourceKey, at: 2, to: membershipStmt)
            guard sqlite3_step(membershipStmt) == SQLITE_DONE else {
                throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
            }

            let favoriteSQL = """
            DELETE FROM favorites
            WHERE id = ? AND source_key = ?;
            """
            let favoriteStmt = try prepare(favoriteSQL)
            defer { sqlite3_finalize(favoriteStmt) }
            try bind(text: comicID, at: 1, to: favoriteStmt)
            try bind(text: sourceKey, at: 2, to: favoriteStmt)
            guard sqlite3_step(favoriteStmt) == SQLITE_DONE else {
                throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
            }

            try Self.exec(db: db, "COMMIT;")
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
        }
    }

    public func listFavoriteCategories() throws -> [LibraryCategory] {
        let sql = """
        SELECT id, name, sort_order, created_at
        FROM favorite_categories
        ORDER BY sort_order ASC, created_at ASC, id ASC;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var items: [LibraryCategory] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(
                LibraryCategory(
                    id: sqlite3_column_int64(stmt, 0),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    sortOrder: Int(sqlite3_column_int(stmt, 2)),
                    createdAt: sqlite3_column_int64(stmt, 3)
                )
            )
        }
        return items
    }

    public func listFavoriteCategoryMemberships() throws -> [Int64: Set<String>] {
        let sql = """
        SELECT category_id, comic_id, source_key
        FROM favorite_category_memberships;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        var memberships: [Int64: Set<String>] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let categoryID = sqlite3_column_int64(stmt, 0)
            let comicID = String(cString: sqlite3_column_text(stmt, 1))
            let sourceKey = String(cString: sqlite3_column_text(stmt, 2))
            memberships[categoryID, default: []].insert("\(sourceKey)::\(comicID)")
        }
        return memberships
    }

    public func createBookmarkShelf(name: String) throws -> LibraryCategory {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SQLiteStoreError.execute("Category name cannot be empty")
        }

        let nextSortOrder = (try listFavoriteCategories().map(\.sortOrder).max() ?? -1) + 1
        let createdAt = Int64(Date().timeIntervalSince1970)
        let sql = """
        INSERT INTO favorite_categories (name, sort_order, created_at)
        VALUES (?, ?, ?);
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: trimmedName, at: 1, to: stmt)
        try bind(int64: Int64(nextSortOrder), at: 2, to: stmt)
        try bind(int64: createdAt, at: 3, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }

        return LibraryCategory(
            id: sqlite3_last_insert_rowid(db),
            name: trimmedName,
            sortOrder: nextSortOrder,
            createdAt: createdAt
        )
    }

    public func renameBookmarkShelf(id: Int64, name: String) throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw SQLiteStoreError.execute("Category name cannot be empty")
        }

        let sql = """
        UPDATE favorite_categories
        SET name = ?
        WHERE id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: trimmedName, at: 1, to: stmt)
        try bind(int64: id, at: 2, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func deleteBookmarkShelf(id: Int64) throws {
        let sql = "DELETE FROM favorite_categories WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(int64: id, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func reorderBookmarkShelves(_ categories: [LibraryCategory]) throws {
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let sql = """
            UPDATE favorite_categories
            SET sort_order = ?
            WHERE id = ?;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }

            for (index, category) in categories.enumerated() {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bind(int64: Int64(index), at: 1, to: stmt)
                try bind(int64: category.id, at: 2, to: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
                }
            }

            try Self.exec(db: db, "COMMIT;")
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
        }
    }

    public func replaceFavoriteCategories(
        with categories: [LibraryCategory],
        memberships: [Int64: Set<String>]
    ) throws {
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try Self.exec(db: db, "DELETE FROM favorite_category_memberships;")
            try Self.exec(db: db, "DELETE FROM favorite_categories;")

            let categorySQL = """
            INSERT INTO favorite_categories (id, name, sort_order, created_at)
            VALUES (?, ?, ?, ?);
            """
            let categoryStmt = try prepare(categorySQL)
            defer { sqlite3_finalize(categoryStmt) }

            for category in categories {
                sqlite3_reset(categoryStmt)
                sqlite3_clear_bindings(categoryStmt)
                try bind(int64: category.id, at: 1, to: categoryStmt)
                try bind(text: category.name, at: 2, to: categoryStmt)
                try bind(int64: Int64(category.sortOrder), at: 3, to: categoryStmt)
                try bind(int64: category.createdAt, at: 4, to: categoryStmt)
                guard sqlite3_step(categoryStmt) == SQLITE_DONE else {
                    throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
                }
            }

            let membershipSQL = """
            INSERT INTO favorite_category_memberships (category_id, comic_id, source_key, created_at)
            VALUES (?, ?, ?, ?);
            """
            let membershipStmt = try prepare(membershipSQL)
            defer { sqlite3_finalize(membershipStmt) }
            let now = Int64(Date().timeIntervalSince1970)

            for (categoryID, comicKeys) in memberships {
                for comicKey in comicKeys {
                    guard let split = Self.splitFavoriteComicKey(comicKey) else { continue }
                    sqlite3_reset(membershipStmt)
                    sqlite3_clear_bindings(membershipStmt)
                    try bind(int64: categoryID, at: 1, to: membershipStmt)
                    try bind(text: split.comicID, at: 2, to: membershipStmt)
                    try bind(text: split.sourceKey, at: 3, to: membershipStmt)
                    try bind(int64: now, at: 4, to: membershipStmt)
                    guard sqlite3_step(membershipStmt) == SQLITE_DONE else {
                        throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
                    }
                }
            }

            try Self.exec(db: db, "COMMIT;")
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
        }
    }

    public func addBookmarks(
        comicKeys: [String],
        toShelfID categoryID: Int64
    ) throws {
        let uniqueKeys = Array(Set(comicKeys))
        guard !uniqueKeys.isEmpty else { return }

        let sql = """
        INSERT OR REPLACE INTO favorite_category_memberships (category_id, comic_id, source_key, created_at)
        VALUES (?, ?, ?, ?);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        let now = Int64(Date().timeIntervalSince1970)

        for comicKey in uniqueKeys {
            guard let split = Self.splitFavoriteComicKey(comicKey) else { continue }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            try bind(int64: categoryID, at: 1, to: stmt)
            try bind(text: split.comicID, at: 2, to: stmt)
            try bind(text: split.sourceKey, at: 3, to: stmt)
            try bind(int64: now, at: 4, to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
            }
        }
    }

    public func removeBookmark(
        comicKey: String,
        fromShelfID categoryID: Int64
    ) throws {
        guard let split = Self.splitFavoriteComicKey(comicKey) else { return }
        let sql = """
        DELETE FROM favorite_category_memberships
        WHERE category_id = ? AND comic_id = ? AND source_key = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(int64: categoryID, at: 1, to: stmt)
        try bind(text: split.comicID, at: 2, to: stmt)
        try bind(text: split.sourceKey, at: 3, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    // MARK: - Tracking

    public func upsertTrackerAccount(_ account: TrackerAccount) throws {
        let sql = """
        INSERT INTO tracker_accounts (provider, display_name, remote_user_id, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(provider)
        DO UPDATE SET
            display_name = excluded.display_name,
            remote_user_id = excluded.remote_user_id,
            updated_at = excluded.updated_at;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: account.provider.rawValue, at: 1, to: stmt)
        try bind(text: account.displayName, at: 2, to: stmt)
        try bind(text: account.remoteUserID, at: 3, to: stmt)
        try bind(int64: account.updatedAt, at: 4, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func listTrackerAccounts() throws -> [TrackerAccount] {
        let sql = """
        SELECT provider, display_name, remote_user_id, updated_at
        FROM tracker_accounts
        ORDER BY provider ASC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var items: [TrackerAccount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let provider = TrackerProvider(rawValue: String(cString: sqlite3_column_text(stmt, 0))) else { continue }
            items.append(
                TrackerAccount(
                    provider: provider,
                    displayName: String(cString: sqlite3_column_text(stmt, 1)),
                    remoteUserID: String(cString: sqlite3_column_text(stmt, 2)),
                    updatedAt: sqlite3_column_int64(stmt, 3)
                )
            )
        }
        return items
    }

    public func deleteTrackerAccount(provider: TrackerProvider) throws {
        let stmt = try prepare("DELETE FROM tracker_accounts WHERE provider = ?;")
        defer { sqlite3_finalize(stmt) }
        try bind(text: provider.rawValue, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
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
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
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
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: provider.rawValue, at: 1, to: stmt)
        try bind(text: sourceKey, at: 2, to: stmt)
        try bind(text: comicID, at: 3, to: stmt)
        try bind(text: remoteMediaID, at: 4, to: stmt)
        try bind(text: remoteTitle, at: 5, to: stmt)
        if let remoteCoverURL, !remoteCoverURL.isEmpty {
            try bind(text: remoteCoverURL, at: 6, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        try bind(int64: Int64(lastSyncedProgress), at: 7, to: stmt)
        if let lastSyncedStatus {
            try bind(text: lastSyncedStatus.rawValue, at: 8, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        try bind(int64: now, at: 9, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
        guard let binding = try getTrackerBinding(provider: provider, sourceKey: sourceKey, comicID: comicID) else {
            throw SQLiteStoreError.execute("tracker binding not found after upsert")
        }
        return binding
    }

    public func getTrackerBinding(
        provider: TrackerProvider,
        sourceKey: String,
        comicID: String
    ) throws -> TrackerBinding? {
        let sql = """
        SELECT id, provider, source_key, comic_id, remote_media_id, remote_title, remote_cover_url,
               last_synced_progress, last_synced_status, updated_at
        FROM tracker_bindings
        WHERE provider = ? AND source_key = ? AND comic_id = ?
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: provider.rawValue, at: 1, to: stmt)
        try bind(text: sourceKey, at: 2, to: stmt)
        try bind(text: comicID, at: 3, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return TrackerBinding(
            id: sqlite3_column_int64(stmt, 0),
            provider: provider,
            sourceKey: String(cString: sqlite3_column_text(stmt, 2)),
            comicID: String(cString: sqlite3_column_text(stmt, 3)),
            remoteMediaID: String(cString: sqlite3_column_text(stmt, 4)),
            remoteTitle: String(cString: sqlite3_column_text(stmt, 5)),
            remoteCoverURL: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
            lastSyncedProgress: Int(sqlite3_column_int(stmt, 7)),
            lastSyncedStatus: sqlite3_column_text(stmt, 8).flatMap { TrackerReadingStatus(rawValue: String(cString: $0)) },
            updatedAt: sqlite3_column_int64(stmt, 9)
        )
    }

    public func listTrackerBindings() throws -> [TrackerBinding] {
        let sql = """
        SELECT id, provider, source_key, comic_id, remote_media_id, remote_title, remote_cover_url,
               last_synced_progress, last_synced_status, updated_at
        FROM tracker_bindings
        ORDER BY updated_at DESC;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var items: [TrackerBinding] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let provider = TrackerProvider(rawValue: String(cString: sqlite3_column_text(stmt, 1))) else { continue }
            items.append(
                TrackerBinding(
                    id: sqlite3_column_int64(stmt, 0),
                    provider: provider,
                    sourceKey: String(cString: sqlite3_column_text(stmt, 2)),
                    comicID: String(cString: sqlite3_column_text(stmt, 3)),
                    remoteMediaID: String(cString: sqlite3_column_text(stmt, 4)),
                    remoteTitle: String(cString: sqlite3_column_text(stmt, 5)),
                    remoteCoverURL: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                    lastSyncedProgress: Int(sqlite3_column_int(stmt, 7)),
                    lastSyncedStatus: sqlite3_column_text(stmt, 8).flatMap { TrackerReadingStatus(rawValue: String(cString: $0)) },
                    updatedAt: sqlite3_column_int64(stmt, 9)
                )
            )
        }
        return items
    }

    public func deleteTrackerBinding(provider: TrackerProvider, sourceKey: String, comicID: String) throws {
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let eventStmt = try prepare("DELETE FROM tracker_sync_events WHERE provider = ? AND source_key = ? AND comic_id = ?;")
            defer { sqlite3_finalize(eventStmt) }
            try bind(text: provider.rawValue, at: 1, to: eventStmt)
            try bind(text: sourceKey, at: 2, to: eventStmt)
            try bind(text: comicID, at: 3, to: eventStmt)
            guard sqlite3_step(eventStmt) == SQLITE_DONE else {
                throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
            }

            let bindingStmt = try prepare("DELETE FROM tracker_bindings WHERE provider = ? AND source_key = ? AND comic_id = ?;")
            defer { sqlite3_finalize(bindingStmt) }
            try bind(text: provider.rawValue, at: 1, to: bindingStmt)
            try bind(text: sourceKey, at: 2, to: bindingStmt)
            try bind(text: comicID, at: 3, to: bindingStmt)
            guard sqlite3_step(bindingStmt) == SQLITE_DONE else {
                throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
            }
            try Self.exec(db: db, "COMMIT;")
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
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
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
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
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: provider.rawValue, at: 1, to: stmt)
        try bind(text: sourceKey, at: 2, to: stmt)
        try bind(text: comicID, at: 3, to: stmt)
        try bind(text: remoteMediaID, at: 4, to: stmt)
        try bind(int64: Int64(targetProgress), at: 5, to: stmt)
        if let targetStatus {
            try bind(text: targetStatus.rawValue, at: 6, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        try bind(text: TrackerSyncEventState.pending.rawValue, at: 7, to: stmt)
        try bind(int64: now, at: 8, to: stmt)
        try bind(int64: now, at: 9, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
        guard let event = try listTrackerSyncEvents(limit: 1, provider: provider, sourceKey: sourceKey, comicID: comicID).first else {
            throw SQLiteStoreError.execute("tracker sync event not found after enqueue")
        }
        return event
    }

    public func listTrackerSyncEvents(
        limit: Int = 100,
        provider: TrackerProvider? = nil,
        sourceKey: String? = nil,
        comicID: String? = nil
    ) throws -> [TrackerSyncEvent] {
        var sql = """
        SELECT id, provider, source_key, comic_id, remote_media_id, target_progress, target_status,
               state, retry_count, last_error, created_at, updated_at
        FROM tracker_sync_events
        WHERE 1 = 1
        """
        if provider != nil { sql += " AND provider = ?" }
        if sourceKey != nil { sql += " AND source_key = ?" }
        if comicID != nil { sql += " AND comic_id = ?" }
        sql += " ORDER BY updated_at ASC LIMIT ?;"

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var bindIndex: Int32 = 1
        if let provider {
            try bind(text: provider.rawValue, at: bindIndex, to: stmt)
            bindIndex += 1
        }
        if let sourceKey {
            try bind(text: sourceKey, at: bindIndex, to: stmt)
            bindIndex += 1
        }
        if let comicID {
            try bind(text: comicID, at: bindIndex, to: stmt)
            bindIndex += 1
        }
        try bind(int64: Int64(limit), at: bindIndex, to: stmt)

        var items: [TrackerSyncEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let provider = TrackerProvider(rawValue: String(cString: sqlite3_column_text(stmt, 1))),
                  let state = TrackerSyncEventState(rawValue: String(cString: sqlite3_column_text(stmt, 7))) else {
                continue
            }
            items.append(
                TrackerSyncEvent(
                    id: sqlite3_column_int64(stmt, 0),
                    provider: provider,
                    sourceKey: String(cString: sqlite3_column_text(stmt, 2)),
                    comicID: String(cString: sqlite3_column_text(stmt, 3)),
                    remoteMediaID: String(cString: sqlite3_column_text(stmt, 4)),
                    targetProgress: Int(sqlite3_column_int(stmt, 5)),
                    targetStatus: sqlite3_column_text(stmt, 6).flatMap { TrackerReadingStatus(rawValue: String(cString: $0)) },
                    state: state,
                    retryCount: Int(sqlite3_column_int(stmt, 8)),
                    lastError: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
                    createdAt: sqlite3_column_int64(stmt, 10),
                    updatedAt: sqlite3_column_int64(stmt, 11)
                )
            )
        }
        return items
    }

    public func markTrackerSyncEventFailed(id: Int64, errorMessage: String) throws {
        let sql = """
        UPDATE tracker_sync_events
        SET state = ?, retry_count = retry_count + 1, last_error = ?, updated_at = ?
        WHERE id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: TrackerSyncEventState.failed.rawValue, at: 1, to: stmt)
        try bind(text: errorMessage, at: 2, to: stmt)
        try bind(int64: Int64(Date().timeIntervalSince1970), at: 3, to: stmt)
        try bind(int64: id, at: 4, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func deleteTrackerSyncEvent(id: Int64) throws {
        let stmt = try prepare("DELETE FROM tracker_sync_events WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bind(int64: id, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
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
        let now = Int64(Date().timeIntervalSince1970)

        let updateSQL = """
        UPDATE history
        SET title = ?, cover_url = ?, author = ?, tags_json = ?, chapter_id = ?, chapter = ?, page = ?, updated_at = ?
        WHERE comic_id = ? AND source_key = ? AND (
            (chapter_id IS NULL AND ? IS NULL) OR chapter_id = ? OR
            ((chapter_id IS NULL OR ? IS NULL) AND ((chapter IS NULL AND ? IS NULL) OR chapter = ?))
        );
        """

        let updateStmt = try prepare(updateSQL)
        defer { sqlite3_finalize(updateStmt) }

        try bind(text: title, at: 1, to: updateStmt)
        if let coverURL {
            try bind(text: coverURL, at: 2, to: updateStmt)
        } else {
            sqlite3_bind_null(updateStmt, 2)
        }
        if let author, !author.isEmpty {
            try bind(text: author, at: 3, to: updateStmt)
        } else {
            sqlite3_bind_null(updateStmt, 3)
        }
        let tagsJSON = Self.encodeTagsJSON(tags)
        if let tagsJSON {
            try bind(text: tagsJSON, at: 4, to: updateStmt)
        } else {
            sqlite3_bind_null(updateStmt, 4)
        }
        if let chapterID, !chapterID.isEmpty {
            try bind(text: chapterID, at: 5, to: updateStmt)
        } else {
            sqlite3_bind_null(updateStmt, 5)
        }
        if let chapter, !chapter.isEmpty {
            try bind(text: chapter, at: 6, to: updateStmt)
        } else {
            sqlite3_bind_null(updateStmt, 6)
        }
        try bind(int64: Int64(page), at: 7, to: updateStmt)
        try bind(int64: now, at: 8, to: updateStmt)
        try bind(text: comicID, at: 9, to: updateStmt)
        try bind(text: sourceKey, at: 10, to: updateStmt)
        if let chapterID, !chapterID.isEmpty {
            try bind(text: chapterID, at: 11, to: updateStmt)
            try bind(text: chapterID, at: 12, to: updateStmt)
            try bind(text: chapterID, at: 13, to: updateStmt)
        } else {
            sqlite3_bind_null(updateStmt, 11)
            sqlite3_bind_null(updateStmt, 12)
            sqlite3_bind_null(updateStmt, 13)
        }
        if let chapter, !chapter.isEmpty {
            try bind(text: chapter, at: 14, to: updateStmt)
            try bind(text: chapter, at: 15, to: updateStmt)
        } else {
            sqlite3_bind_null(updateStmt, 14)
            sqlite3_bind_null(updateStmt, 15)
        }

        guard sqlite3_step(updateStmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }

        let changedRows = sqlite3_changes(db)
        if changedRows > 0 {
            return
        }

        let insertSQL = """
        INSERT INTO history (comic_id, source_key, title, cover_url, author, tags_json, chapter_id, chapter, page, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

        let insertStmt = try prepare(insertSQL)
        defer { sqlite3_finalize(insertStmt) }

        try bind(text: comicID, at: 1, to: insertStmt)
        try bind(text: sourceKey, at: 2, to: insertStmt)
        try bind(text: title, at: 3, to: insertStmt)
        if let coverURL {
            try bind(text: coverURL, at: 4, to: insertStmt)
        } else {
            sqlite3_bind_null(insertStmt, 4)
        }
        if let author, !author.isEmpty {
            try bind(text: author, at: 5, to: insertStmt)
        } else {
            sqlite3_bind_null(insertStmt, 5)
        }
        let tagsJSONForInsert = Self.encodeTagsJSON(tags)
        if let tagsJSONForInsert {
            try bind(text: tagsJSONForInsert, at: 6, to: insertStmt)
        } else {
            sqlite3_bind_null(insertStmt, 6)
        }
        if let chapterID, !chapterID.isEmpty {
            try bind(text: chapterID, at: 7, to: insertStmt)
        } else {
            sqlite3_bind_null(insertStmt, 7)
        }
        if let chapter, !chapter.isEmpty {
            try bind(text: chapter, at: 8, to: insertStmt)
        } else {
            sqlite3_bind_null(insertStmt, 8)
        }
        try bind(int64: Int64(page), at: 9, to: insertStmt)
        try bind(int64: now, at: 10, to: insertStmt)

        guard sqlite3_step(insertStmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
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
        try addHistory(
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

        let sql = """
        SELECT id, comic_id, source_key, title, cover_url, author, tags_json, chapter_id, chapter, page, updated_at
        FROM history
        WHERE comic_id = ? AND source_key = ? AND (
            (chapter_id IS NULL AND ? IS NULL) OR chapter_id = ? OR
            ((chapter_id IS NULL OR ? IS NULL) AND ((chapter IS NULL AND ? IS NULL) OR chapter = ?))
        )
        ORDER BY updated_at DESC, id DESC
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: comicID, at: 1, to: stmt)
        try bind(text: sourceKey, at: 2, to: stmt)
        if let chapterID, !chapterID.isEmpty {
            try bind(text: chapterID, at: 3, to: stmt)
            try bind(text: chapterID, at: 4, to: stmt)
            try bind(text: chapterID, at: 5, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 3)
            sqlite3_bind_null(stmt, 4)
            sqlite3_bind_null(stmt, 5)
        }
        if let chapter, !chapter.isEmpty {
            try bind(text: chapter, at: 6, to: stmt)
            try bind(text: chapter, at: 7, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 6)
            sqlite3_bind_null(stmt, 7)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw SQLiteStoreError.execute("history row not found after upsert")
        }

        return ReadingHistoryItem(
            id: sqlite3_column_int64(stmt, 0),
            comicID: String(cString: sqlite3_column_text(stmt, 1)),
            sourceKey: String(cString: sqlite3_column_text(stmt, 2)),
            title: String(cString: sqlite3_column_text(stmt, 3)),
            coverURL: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            author: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            tags: Self.decodeTagsJSON(sqlite3_column_text(stmt, 6).map { String(cString: $0) }),
            chapterID: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
            chapter: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
            page: Int(sqlite3_column_int(stmt, 9)),
            updatedAt: sqlite3_column_int64(stmt, 10)
        )
    }

    public func listHistory(limit: Int = 100) throws -> [ReadingHistoryItem] {
        let sql = """
        SELECT id, comic_id, source_key, title, cover_url, author, tags_json, chapter_id, chapter, page, updated_at
        FROM history
        ORDER BY updated_at DESC
        LIMIT ?;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bind(int64: Int64(limit), at: 1, to: stmt)

        var items: [ReadingHistoryItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(
                ReadingHistoryItem(
                    id: sqlite3_column_int64(stmt, 0),
                    comicID: String(cString: sqlite3_column_text(stmt, 1)),
                    sourceKey: String(cString: sqlite3_column_text(stmt, 2)),
                    title: String(cString: sqlite3_column_text(stmt, 3)),
                    coverURL: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    author: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                    tags: Self.decodeTagsJSON(sqlite3_column_text(stmt, 6).map { String(cString: $0) }),
                    chapterID: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
                    chapter: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
                    page: Int(sqlite3_column_int(stmt, 9)),
                    updatedAt: sqlite3_column_int64(stmt, 10)
                )
            )
        }

        return items
    }

    public func replaceHistory(with items: [ReadingHistoryItem]) throws {
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try Self.exec(db: db, "DELETE FROM history;")
            let sql = """
            INSERT INTO history (
                id, comic_id, source_key, title, cover_url, author, tags_json, chapter_id, chapter, page, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }

            for item in items {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                try bind(int64: item.id, at: 1, to: stmt)
                try bind(text: item.comicID, at: 2, to: stmt)
                try bind(text: item.sourceKey, at: 3, to: stmt)
                try bind(text: item.title, at: 4, to: stmt)
                if let coverURL = item.coverURL {
                    try bind(text: coverURL, at: 5, to: stmt)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                if let author = item.author, !author.isEmpty {
                    try bind(text: author, at: 6, to: stmt)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                if let tagsJSON = Self.encodeTagsJSON(item.tags) {
                    try bind(text: tagsJSON, at: 7, to: stmt)
                } else {
                    sqlite3_bind_null(stmt, 7)
                }
                if let chapterID = item.chapterID, !chapterID.isEmpty {
                    try bind(text: chapterID, at: 8, to: stmt)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                if let chapter = item.chapter, !chapter.isEmpty {
                    try bind(text: chapter, at: 9, to: stmt)
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
                try bind(int64: Int64(item.page), at: 10, to: stmt)
                try bind(int64: item.updatedAt, at: 11, to: stmt)

                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
                }
            }
            try Self.exec(db: db, "COMMIT;")
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
        }
    }

    public func clearHistory() throws {
        try Self.exec(db: db, "DELETE FROM history;")
    }

    public func deleteHistory(id: Int64) throws {
        let sql = "DELETE FROM history WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(int64: id, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
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
        let now = Int64(Date().timeIntervalSince1970)
        let sql = """
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
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bind(text: sourceKey, at: 1, to: stmt)
        try bind(text: comicID, at: 2, to: stmt)
        try bind(text: comicTitle, at: 3, to: stmt)
        if let coverURL {
            try bind(text: coverURL, at: 4, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let comicDescription, !comicDescription.isEmpty {
            try bind(text: comicDescription, at: 5, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        try bind(text: chapterID, at: 6, to: stmt)
        try bind(text: chapterTitle, at: 7, to: stmt)
        try bind(text: status.rawValue, at: 8, to: stmt)
        try bind(int64: Int64(totalPages), at: 9, to: stmt)
        try bind(int64: Int64(downloadedPages), at: 10, to: stmt)
        try bind(text: directoryPath, at: 11, to: stmt)
        if let errorMessage {
            try bind(text: errorMessage, at: 12, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        try bind(int64: now, at: 13, to: stmt)
        try bind(int64: now, at: 14, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
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
        let sql = """
        UPDATE downloads
        SET status = ?, downloaded_pages = ?, total_pages = ?, error_message = ?, updated_at = ?
        WHERE source_key = ? AND comic_id = ? AND chapter_id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bind(text: status.rawValue, at: 1, to: stmt)
        try bind(int64: Int64(downloadedPages), at: 2, to: stmt)
        try bind(int64: Int64(totalPages), at: 3, to: stmt)
        if let errorMessage {
            try bind(text: errorMessage, at: 4, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        try bind(int64: Int64(Date().timeIntervalSince1970), at: 5, to: stmt)
        try bind(text: sourceKey, at: 6, to: stmt)
        try bind(text: comicID, at: 7, to: stmt)
        try bind(text: chapterID, at: 8, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func listDownloadChapters(limit: Int = 300) throws -> [DownloadChapterItem] {
        let sql = """
        SELECT id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id, chapter_title,
               status, total_pages, downloaded_pages, directory_path, error_message, created_at, updated_at
        FROM downloads
        ORDER BY updated_at DESC
        LIMIT ?;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(int64: Int64(limit), at: 1, to: stmt)

        var items: [DownloadChapterItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let statusRaw = String(cString: sqlite3_column_text(stmt, 8))
            let status = DownloadStatus(rawValue: statusRaw) ?? .failed
            items.append(
                DownloadChapterItem(
                    id: sqlite3_column_int64(stmt, 0),
                    sourceKey: String(cString: sqlite3_column_text(stmt, 1)),
                    comicID: String(cString: sqlite3_column_text(stmt, 2)),
                    comicTitle: String(cString: sqlite3_column_text(stmt, 3)),
                    coverURL: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    comicDescription: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                    chapterID: String(cString: sqlite3_column_text(stmt, 6)),
                    chapterTitle: String(cString: sqlite3_column_text(stmt, 7)),
                    status: status,
                    totalPages: Int(sqlite3_column_int(stmt, 9)),
                    downloadedPages: Int(sqlite3_column_int(stmt, 10)),
                    directoryPath: String(cString: sqlite3_column_text(stmt, 11)),
                    errorMessage: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
                    createdAt: sqlite3_column_int64(stmt, 13),
                    updatedAt: sqlite3_column_int64(stmt, 14)
                )
            )
        }
        return items
    }

    public func getDownloadChapter(
        sourceKey: String,
        comicID: String,
        chapterID: String
    ) throws -> DownloadChapterItem? {
        let sql = """
        SELECT id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id, chapter_title,
               status, total_pages, downloaded_pages, directory_path, error_message, created_at, updated_at
        FROM downloads
        WHERE source_key = ? AND comic_id = ? AND chapter_id = ?
        LIMIT 1;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: sourceKey, at: 1, to: stmt)
        try bind(text: comicID, at: 2, to: stmt)
        try bind(text: chapterID, at: 3, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }

        let statusRaw = String(cString: sqlite3_column_text(stmt, 8))
        let status = DownloadStatus(rawValue: statusRaw) ?? .failed
        return DownloadChapterItem(
            id: sqlite3_column_int64(stmt, 0),
            sourceKey: String(cString: sqlite3_column_text(stmt, 1)),
            comicID: String(cString: sqlite3_column_text(stmt, 2)),
            comicTitle: String(cString: sqlite3_column_text(stmt, 3)),
            coverURL: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            comicDescription: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            chapterID: String(cString: sqlite3_column_text(stmt, 6)),
            chapterTitle: String(cString: sqlite3_column_text(stmt, 7)),
            status: status,
            totalPages: Int(sqlite3_column_int(stmt, 9)),
            downloadedPages: Int(sqlite3_column_int(stmt, 10)),
            directoryPath: String(cString: sqlite3_column_text(stmt, 11)),
            errorMessage: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
            createdAt: sqlite3_column_int64(stmt, 13),
            updatedAt: sqlite3_column_int64(stmt, 14)
        )
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
        let now = Int64(Date().timeIntervalSince1970)
        let effectiveDownloadedAt = downloadedAt ?? now
        let effectiveLastVerifiedAt = lastVerifiedAt ?? now
        let sql = """
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
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }

        try bind(text: sourceKey, at: 1, to: stmt)
        try bind(text: comicID, at: 2, to: stmt)
        try bind(text: comicTitle, at: 3, to: stmt)
        if let coverURL, !coverURL.isEmpty {
            try bind(text: coverURL, at: 4, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let comicDescription, !comicDescription.isEmpty {
            try bind(text: comicDescription, at: 5, to: stmt)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        try bind(text: chapterID, at: 6, to: stmt)
        try bind(text: chapterTitle, at: 7, to: stmt)
        try bind(int64: Int64(pageCount), at: 8, to: stmt)
        try bind(int64: Int64(verifiedPageCount), at: 9, to: stmt)
        try bind(text: integrityStatus.rawValue, at: 10, to: stmt)
        try bind(text: directoryPath, at: 11, to: stmt)
        try bind(int64: effectiveDownloadedAt, at: 12, to: stmt)
        try bind(int64: effectiveLastVerifiedAt, at: 13, to: stmt)
        try bind(int64: now, at: 14, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func listOfflineChapters(limit: Int = 600) throws -> [OfflineChapterAsset] {
        let sql = """
        SELECT id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id,
               chapter_title, page_count, verified_page_count, integrity_status, directory_path,
               downloaded_at, last_verified_at, updated_at
        FROM offline_chapters
        ORDER BY updated_at DESC
        LIMIT ?;
        """

        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(int64: Int64(limit), at: 1, to: stmt)

        var items: [OfflineChapterAsset] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(
                OfflineChapterAsset(
                    id: sqlite3_column_int64(stmt, 0),
                    sourceKey: String(cString: sqlite3_column_text(stmt, 1)),
                    comicID: String(cString: sqlite3_column_text(stmt, 2)),
                    comicTitle: String(cString: sqlite3_column_text(stmt, 3)),
                    coverURL: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    comicDescription: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
                    chapterID: String(cString: sqlite3_column_text(stmt, 6)),
                    chapterTitle: String(cString: sqlite3_column_text(stmt, 7)),
                    pageCount: Int(sqlite3_column_int(stmt, 8)),
                    verifiedPageCount: Int(sqlite3_column_int(stmt, 9)),
                    integrityStatus: OfflineChapterIntegrityStatus(rawValue: String(cString: sqlite3_column_text(stmt, 10))) ?? .incomplete,
                    directoryPath: String(cString: sqlite3_column_text(stmt, 11)),
                    downloadedAt: sqlite3_column_int64(stmt, 12),
                    lastVerifiedAt: sqlite3_column_int64(stmt, 13),
                    updatedAt: sqlite3_column_int64(stmt, 14)
                )
            )
        }
        return items
    }

    public func getOfflineChapter(
        sourceKey: String,
        comicID: String,
        chapterID: String
    ) throws -> OfflineChapterAsset? {
        let sql = """
        SELECT id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id,
               chapter_title, page_count, verified_page_count, integrity_status, directory_path,
               downloaded_at, last_verified_at, updated_at
        FROM offline_chapters
        WHERE source_key = ? AND comic_id = ? AND chapter_id = ?
        LIMIT 1;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: sourceKey, at: 1, to: stmt)
        try bind(text: comicID, at: 2, to: stmt)
        try bind(text: chapterID, at: 3, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return OfflineChapterAsset(
            id: sqlite3_column_int64(stmt, 0),
            sourceKey: String(cString: sqlite3_column_text(stmt, 1)),
            comicID: String(cString: sqlite3_column_text(stmt, 2)),
            comicTitle: String(cString: sqlite3_column_text(stmt, 3)),
            coverURL: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            comicDescription: sqlite3_column_text(stmt, 5).map { String(cString: $0) },
            chapterID: String(cString: sqlite3_column_text(stmt, 6)),
            chapterTitle: String(cString: sqlite3_column_text(stmt, 7)),
            pageCount: Int(sqlite3_column_int(stmt, 8)),
            verifiedPageCount: Int(sqlite3_column_int(stmt, 9)),
            integrityStatus: OfflineChapterIntegrityStatus(rawValue: String(cString: sqlite3_column_text(stmt, 10))) ?? .incomplete,
            directoryPath: String(cString: sqlite3_column_text(stmt, 11)),
            downloadedAt: sqlite3_column_int64(stmt, 12),
            lastVerifiedAt: sqlite3_column_int64(stmt, 13),
            updatedAt: sqlite3_column_int64(stmt, 14)
        )
    }

    public func renameOfflineComic(sourceKey: String, comicID: String, comicTitle: String) throws {
        let sql = """
        UPDATE offline_chapters
        SET comic_title = ?, updated_at = ?
        WHERE source_key = ? AND comic_id = ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(text: comicTitle, at: 1, to: stmt)
        try bind(int64: Int64(Date().timeIntervalSince1970), at: 2, to: stmt)
        try bind(text: sourceKey, at: 3, to: stmt)
        try bind(text: comicID, at: 4, to: stmt)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func replaceOfflineChapters(with items: [OfflineChapterAsset]) throws {
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            try Self.exec(db: db, "DELETE FROM offline_chapters;")
            for item in items {
                try upsertOfflineChapter(
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
            try Self.exec(db: db, "COMMIT;")
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
        }
    }

    public func deleteOfflineChapters(ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        var paths: [String] = []
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let query = "SELECT directory_path FROM offline_chapters WHERE id = ? LIMIT 1;"
            let queryStmt = try prepare(query)
            defer { sqlite3_finalize(queryStmt) }

            let deleteSQL = "DELETE FROM offline_chapters WHERE id = ?;"
            let deleteStmt = try prepare(deleteSQL)
            defer { sqlite3_finalize(deleteStmt) }

            for id in ids {
                sqlite3_reset(queryStmt)
                sqlite3_clear_bindings(queryStmt)
                try bind(int64: id, at: 1, to: queryStmt)
                if sqlite3_step(queryStmt) == SQLITE_ROW,
                   let raw = sqlite3_column_text(queryStmt, 0) {
                    paths.append(String(cString: raw))
                }

                sqlite3_reset(deleteStmt)
                sqlite3_clear_bindings(deleteStmt)
                try bind(int64: id, at: 1, to: deleteStmt)
                guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                    throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
                }
            }
            try Self.exec(db: db, "COMMIT;")
            return paths
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
        }
    }

    public func clearOfflineChapters() throws -> [String] {
        let query = "SELECT directory_path FROM offline_chapters;"
        let queryStmt = try prepare(query)
        defer { sqlite3_finalize(queryStmt) }

        var paths: [String] = []
        while sqlite3_step(queryStmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(queryStmt, 0) {
                paths.append(String(cString: text))
            }
        }

        let stmt = try prepare("DELETE FROM offline_chapters;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
        return paths
    }

    public func deleteDownloadTask(
        sourceKey: String,
        comicID: String,
        chapterID: String
    ) throws {
        let stmt = try prepare("DELETE FROM downloads WHERE source_key = ? AND comic_id = ? AND chapter_id = ?;")
        defer { sqlite3_finalize(stmt) }
        try bind(text: sourceKey, at: 1, to: stmt)
        try bind(text: comicID, at: 2, to: stmt)
        try bind(text: chapterID, at: 3, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
    }

    public func deleteDownloadChapters(ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }

        var paths: [String] = []
        try Self.exec(db: db, "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let query = "SELECT directory_path FROM downloads WHERE id = ? LIMIT 1;"
            let queryStmt = try prepare(query)
            defer { sqlite3_finalize(queryStmt) }

            let deleteSQL = "DELETE FROM downloads WHERE id = ?;"
            let deleteStmt = try prepare(deleteSQL)
            defer { sqlite3_finalize(deleteStmt) }

            for id in ids {
                sqlite3_reset(queryStmt)
                sqlite3_clear_bindings(queryStmt)
                try bind(int64: id, at: 1, to: queryStmt)
                if sqlite3_step(queryStmt) == SQLITE_ROW,
                   let raw = sqlite3_column_text(queryStmt, 0) {
                    paths.append(String(cString: raw))
                }

                sqlite3_reset(deleteStmt)
                sqlite3_clear_bindings(deleteStmt)
                try bind(int64: id, at: 1, to: deleteStmt)
                guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                    throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
                }
            }
            try Self.exec(db: db, "COMMIT;")
            return paths
        } catch {
            try? Self.exec(db: db, "ROLLBACK;")
            throw error
        }
    }

    public func deleteDownloadChapter(id: Int64) throws -> String? {
        let query = "SELECT directory_path FROM downloads WHERE id = ? LIMIT 1;"
        let queryStmt = try prepare(query)
        defer { sqlite3_finalize(queryStmt) }
        try bind(int64: id, at: 1, to: queryStmt)

        var directoryPath: String?
        if sqlite3_step(queryStmt) == SQLITE_ROW {
            directoryPath = sqlite3_column_text(queryStmt, 0).map { String(cString: $0) }
        }

        let sql = "DELETE FROM downloads WHERE id = ?;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(int64: id, at: 1, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(Self.lastErrorMessage(db))
        }
        return directoryPath
    }

    public func clearDownloadChapters() throws -> [String] {
        let listSQL = "SELECT directory_path FROM downloads;"
        let listStmt = try prepare(listSQL)
        defer { sqlite3_finalize(listStmt) }
        var paths: [String] = []
        while sqlite3_step(listStmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(listStmt, 0) {
                paths.append(String(cString: text))
            }
        }

        try Self.exec(db: db, "DELETE FROM downloads;")
        return paths
    }

    // MARK: - Private Helpers

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepare(Self.lastErrorMessage(db))
        }
        return stmt
    }

    private func bind(text: String, at index: Int32, to stmt: OpaquePointer?) throws {
        let result = sqlite3_bind_text(stmt, index, text, -1, SQLITE_TRANSIENT)
        guard result == SQLITE_OK else {
            throw SQLiteStoreError.bind(Self.lastErrorMessage(db))
        }
    }

    private func bind(int64 value: Int64, at index: Int32, to stmt: OpaquePointer?) throws {
        let result = sqlite3_bind_int64(stmt, index, value)
        guard result == SQLITE_OK else {
            throw SQLiteStoreError.bind(Self.lastErrorMessage(db))
        }
    }

    private static func exec(db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteStoreError.execute(lastErrorMessage(db))
        }
    }

    private static func ensureHistorySchema(db: OpaquePointer?) throws {
        let requiredColumns: Set<String> = [
            "id", "comic_id", "source_key", "title", "cover_url", "chapter", "page", "updated_at"
        ]
        let existingColumns = try historyColumns(db: db)
        guard !existingColumns.isEmpty else { return }
        guard requiredColumns.isSubset(of: existingColumns) else {
            try exec(db: db, "DROP TABLE IF EXISTS history;")
            try exec(
                db: db,
                """
                CREATE TABLE history (
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
            return
        }

        if !existingColumns.contains("author") {
            try exec(db: db, "ALTER TABLE history ADD COLUMN author TEXT;")
        }
        if !existingColumns.contains("tags_json") {
            try exec(db: db, "ALTER TABLE history ADD COLUMN tags_json TEXT;")
        }
        if !existingColumns.contains("chapter_id") {
            try exec(db: db, "ALTER TABLE history ADD COLUMN chapter_id TEXT;")
        }
    }

    private static func ensureDownloadsSchema(db: OpaquePointer?) throws {
        let existingColumns = try tableColumns("downloads", db: db)
        guard !existingColumns.isEmpty else { return }
        if !existingColumns.contains("comic_description") {
            try exec(db: db, "ALTER TABLE downloads ADD COLUMN comic_description TEXT;")
        }

        let offlineColumns = try tableColumns("offline_chapters", db: db)
        guard !offlineColumns.isEmpty else { return }
        if !offlineColumns.contains("verified_page_count") {
            try exec(db: db, "ALTER TABLE offline_chapters ADD COLUMN verified_page_count INTEGER NOT NULL DEFAULT 0;")
        }
        if !offlineColumns.contains("integrity_status") {
            try exec(db: db, "ALTER TABLE offline_chapters ADD COLUMN integrity_status TEXT NOT NULL DEFAULT 'incomplete';")
        }
        if !offlineColumns.contains("last_verified_at") {
            try exec(db: db, "ALTER TABLE offline_chapters ADD COLUMN last_verified_at INTEGER NOT NULL DEFAULT 0;")
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
        guard let text, let data = text.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: []) as? [Any]
        else {
            return []
        }
        return raw.map { String(describing: $0) }.filter { !$0.isEmpty }
    }

    private static func historyColumns(db: OpaquePointer?) throws -> Set<String> {
        try tableColumns("history", db: db)
    }

    private static func tableColumns(_ tableName: String, db: OpaquePointer?) throws -> Set<String> {
        let sql = "PRAGMA table_info(\(tableName));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SQLiteStoreError.prepare(lastErrorMessage(db))
        }
        defer { sqlite3_finalize(stmt) }

        var columns: Set<String> = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 1) {
                columns.insert(String(cString: text))
            }
        }
        return columns
    }

    private static func splitFavoriteComicKey(_ key: String) -> (sourceKey: String, comicID: String)? {
        let parts = key.components(separatedBy: "::")
        guard parts.count == 2 else { return nil }
        return (sourceKey: parts[0], comicID: parts[1])
    }

    private static func lastErrorMessage(_ db: OpaquePointer?) -> String {
        if let db, let cString = sqlite3_errmsg(db) {
            return String(cString: cString)
        }
        return "unknown sqlite error"
    }
}

nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
