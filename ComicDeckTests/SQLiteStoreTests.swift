import XCTest
import SQLite3
@testable import ComicDeck

@MainActor
final class SQLiteStoreTests: XCTestCase {
    func testFreshBootstrapSupportsLibraryDownloadOfflineAndTrackerFlows() async throws {
        let store = try makeStore()

        let favorite = FavoriteComic(
            id: "comic-1",
            sourceKey: "source-a",
            title: "Comic One",
            coverURL: "https://example.com/cover-1.jpg",
            createdAt: 100
        )
        try await store.upsertFavorite(favorite)

        let favorites = try await store.listFavorites(limit: 10)
        XCTAssertEqual(favorites, [favorite])

        let shelf = try await store.createBookmarkShelf(name: "Reading")
        let shelfID = shelf.id
        try await store.addBookmarks(comicKeys: ["source-a::comic-1"], toShelfID: shelfID)

        let categories = try await store.listFavoriteCategories()
        let memberships = try await store.listFavoriteCategoryMemberships()
        XCTAssertEqual(categories, [shelf])
        XCTAssertEqual(memberships, [shelfID: Set(["source-a::comic-1"])])

        let firstHistory = try await store.addHistoryAndFetch(
            comicID: "comic-1",
            sourceKey: "source-a",
            title: "Comic One",
            coverURL: "https://example.com/cover-1.jpg",
            author: "Author",
            tags: ["Action", "Drama"],
            chapterID: "chapter-1",
            chapter: "Chapter 1",
            page: 3
        )
        let updatedHistory = try await store.addHistoryAndFetch(
            comicID: "comic-1",
            sourceKey: "source-a",
            title: "Comic One",
            coverURL: "https://example.com/cover-1.jpg",
            author: "Author",
            tags: ["Action", "Drama"],
            chapterID: "chapter-1",
            chapter: "Chapter 1",
            page: 9
        )
        let updatedHistoryID = updatedHistory.id
        let updatedHistoryPage = updatedHistory.page
        let updatedHistoryTags = updatedHistory.tags
        let history = try await store.listHistory(limit: 10)
        XCTAssertEqual(updatedHistoryID, firstHistory.id)
        XCTAssertEqual(updatedHistoryPage, 9)
        XCTAssertEqual(updatedHistoryTags, ["Action", "Drama"])
        XCTAssertEqual(history.count, 1)

        try await store.upsertDownloadChapter(
            sourceKey: "source-a",
            comicID: "comic-1",
            comicTitle: "Comic One",
            coverURL: "https://example.com/cover-1.jpg",
            comicDescription: "Description",
            chapterID: "chapter-1",
            chapterTitle: "Chapter 1",
            status: .pending,
            totalPages: 12,
            downloadedPages: 0,
            directoryPath: "/tmp/comicdeck-download-1",
            errorMessage: nil
        )
        try await store.updateDownloadProgress(
            sourceKey: "source-a",
            comicID: "comic-1",
            chapterID: "chapter-1",
            status: .downloading,
            downloadedPages: 4,
            totalPages: 12,
            errorMessage: nil
        )
        let maybeDownload = try await store.getDownloadChapter(
            sourceKey: "source-a",
            comicID: "comic-1",
            chapterID: "chapter-1"
        )
        let download = try XCTUnwrap(maybeDownload)
        let downloadStatus = download.status
        let downloadDownloadedPages = download.downloadedPages
        let downloadTotalPages = download.totalPages
        let downloadDescription = download.comicDescription
        XCTAssertEqual(downloadStatus, .downloading)
        XCTAssertEqual(downloadDownloadedPages, 4)
        XCTAssertEqual(downloadTotalPages, 12)
        XCTAssertEqual(downloadDescription, "Description")

        try await store.upsertOfflineChapter(
            sourceKey: "source-a",
            comicID: "comic-1",
            comicTitle: "Comic One",
            coverURL: "https://example.com/cover-1.jpg",
            comicDescription: "Description",
            chapterID: "chapter-1",
            chapterTitle: "Chapter 1",
            pageCount: 12,
            verifiedPageCount: 12,
            integrityStatus: .complete,
            directoryPath: "/tmp/comicdeck-offline-1",
            downloadedAt: 111,
            lastVerifiedAt: 222
        )
        let maybeOffline = try await store.getOfflineChapter(
            sourceKey: "source-a",
            comicID: "comic-1",
            chapterID: "chapter-1"
        )
        let offline = try XCTUnwrap(maybeOffline)
        let offlineVerifiedPageCount = offline.verifiedPageCount
        let offlineIntegrityStatus = offline.integrityStatus
        let offlineDownloadedAt = offline.downloadedAt
        let offlineLastVerifiedAt = offline.lastVerifiedAt
        XCTAssertEqual(offlineVerifiedPageCount, 12)
        XCTAssertEqual(offlineIntegrityStatus, .complete)
        XCTAssertEqual(offlineDownloadedAt, 111)
        XCTAssertEqual(offlineLastVerifiedAt, 222)

        let account = TrackerAccount(
            provider: .aniList,
            displayName: "Tester",
            remoteUserID: "user-1",
            updatedAt: 333
        )
        try await store.upsertTrackerAccount(account)

        let trackerAccounts = try await store.listTrackerAccounts()
        XCTAssertEqual(trackerAccounts, [account])

        let binding = try await store.upsertTrackerBinding(
            provider: .aniList,
            sourceKey: "source-a",
            comicID: "comic-1",
            remoteMediaID: "remote-1",
            remoteTitle: "Remote Comic",
            remoteCoverURL: "https://example.com/remote-cover.jpg",
            lastSyncedProgress: 9,
            lastSyncedStatus: .current
        )
        let storedBinding = try await store.getTrackerBinding(
            provider: .aniList,
            sourceKey: "source-a",
            comicID: "comic-1"
        )
        XCTAssertEqual(storedBinding, binding)

        let event = try await store.enqueueTrackerSyncEvent(
            provider: .aniList,
            sourceKey: "source-a",
            comicID: "comic-1",
            remoteMediaID: "remote-1",
            targetProgress: 10,
            targetStatus: .completed
        )
        let queuedEvents = try await store.listTrackerSyncEvents(limit: 10)
        XCTAssertEqual(queuedEvents.count, 1)

        try await store.markTrackerSyncEventFailed(id: event.id, errorMessage: "network")
        let failedEvents = try await store.listTrackerSyncEvents(
            limit: 10,
            provider: .aniList,
            sourceKey: "source-a",
            comicID: "comic-1"
        )
        let failedEvent = try XCTUnwrap(failedEvents.first)
        let failedState = failedEvent.state
        let failedRetryCount = failedEvent.retryCount
        let failedLastError = failedEvent.lastError
        XCTAssertEqual(failedState, .failed)
        XCTAssertEqual(failedRetryCount, 1)
        XCTAssertEqual(failedLastError, "network")

        let deletedDownloadPath = try await store.deleteDownloadChapter(id: download.id)
        let remainingDownloads = try await store.listDownloadChapters(limit: 10)
        XCTAssertEqual(deletedDownloadPath, "/tmp/comicdeck-download-1")
        XCTAssertEqual(remainingDownloads, [])

        let deletedOfflinePaths = try await store.deleteOfflineChapters(ids: [offline.id])
        let remainingOffline = try await store.listOfflineChapters(limit: 10)
        XCTAssertEqual(deletedOfflinePaths, ["/tmp/comicdeck-offline-1"])
        XCTAssertEqual(remainingOffline, [])

        try await store.deleteTrackerBinding(provider: .aniList, sourceKey: "source-a", comicID: "comic-1")
        let deletedBinding = try await store.getTrackerBinding(provider: .aniList, sourceKey: "source-a", comicID: "comic-1")
        let remainingTrackerEvents = try await store.listTrackerSyncEvents(
            limit: 10,
            provider: .aniList,
            sourceKey: "source-a",
            comicID: "comic-1"
        )
        XCTAssertNil(deletedBinding)
        XCTAssertEqual(remainingTrackerEvents, [])
    }

    func testLegacyHistoryMigrationPreservesRowsFromOlderSchemas() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("legacy-history.sqlite3")

        try seedLegacyDatabase(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    comic_id TEXT NOT NULL,
                    source_key TEXT NOT NULL,
                    title TEXT NOT NULL,
                    page INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """,
                """
                INSERT INTO history (id, comic_id, source_key, title, page, updated_at)
                VALUES (1, 'legacy-comic', 'legacy-source', 'Legacy Title', 7, 555);
                """,
            ]
        )

        let store = try SQLiteStore(databaseURL: databaseURL)
        let historyItems = try await store.listHistory(limit: 10)
        let item = try XCTUnwrap(historyItems.first)
        let itemID = item.id
        let itemComicID = item.comicID
        let itemSourceKey = item.sourceKey
        let itemTitle = item.title
        let itemCoverURL = item.coverURL
        let itemAuthor = item.author
        let itemTags = item.tags
        let itemChapterID = item.chapterID
        let itemChapter = item.chapter
        let itemPage = item.page
        let itemUpdatedAt = item.updatedAt
        XCTAssertEqual(itemID, 1)
        XCTAssertEqual(itemComicID, "legacy-comic")
        XCTAssertEqual(itemSourceKey, "legacy-source")
        XCTAssertEqual(itemTitle, "Legacy Title")
        XCTAssertNil(itemCoverURL)
        XCTAssertNil(itemAuthor)
        XCTAssertEqual(itemTags, [])
        XCTAssertNil(itemChapterID)
        XCTAssertNil(itemChapter)
        XCTAssertEqual(itemPage, 7)
        XCTAssertEqual(itemUpdatedAt, 555)

        let updated = try await store.addHistoryAndFetch(
            comicID: "legacy-comic",
            sourceKey: "legacy-source",
            title: "Legacy Title Updated",
            coverURL: nil,
            author: "Restored Author",
            tags: ["legacy"],
            chapterID: nil,
            chapter: nil,
            page: 8
        )
        let updatedID = updated.id
        let updatedAuthor = updated.author
        let updatedTags = updated.tags
        let updatedPage = updated.page
        XCTAssertEqual(updatedID, 1)
        XCTAssertEqual(updatedAuthor, "Restored Author")
        XCTAssertEqual(updatedTags, ["legacy"])
        XCTAssertEqual(updatedPage, 8)
    }

    func testLegacyDownloadAndOfflineMigrationAddsMissingColumnsWithoutDroppingRows() async throws {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("legacy-downloads.sqlite3")

        try seedLegacyDatabase(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE downloads (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_key TEXT NOT NULL,
                    comic_id TEXT NOT NULL,
                    comic_title TEXT NOT NULL,
                    cover_url TEXT,
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
                """,
                """
                INSERT INTO downloads (
                    id, source_key, comic_id, comic_title, cover_url, chapter_id, chapter_title,
                    status, total_pages, downloaded_pages, directory_path, error_message, created_at, updated_at
                )
                VALUES (
                    1, 'legacy-source', 'legacy-comic', 'Legacy Comic', 'https://example.com/legacy.jpg',
                    'chapter-1', 'Chapter 1', 'downloading', 12, 5, '/tmp/legacy-download', NULL, 100, 200
                );
                """,
                """
                CREATE TABLE offline_chapters (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_key TEXT NOT NULL,
                    comic_id TEXT NOT NULL,
                    comic_title TEXT NOT NULL,
                    cover_url TEXT,
                    comic_description TEXT,
                    chapter_id TEXT NOT NULL,
                    chapter_title TEXT NOT NULL,
                    page_count INTEGER NOT NULL,
                    directory_path TEXT NOT NULL,
                    downloaded_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (source_key, comic_id, chapter_id)
                );
                """,
                """
                INSERT INTO offline_chapters (
                    id, source_key, comic_id, comic_title, cover_url, comic_description, chapter_id,
                    chapter_title, page_count, directory_path, downloaded_at, updated_at
                )
                VALUES (
                    1, 'legacy-source', 'legacy-comic', 'Legacy Comic', 'https://example.com/legacy.jpg',
                    'Legacy Description', 'chapter-1', 'Chapter 1', 12, '/tmp/legacy-offline', 300, 400
                );
                """,
            ]
        )

        let store = try SQLiteStore(databaseURL: databaseURL)

        let maybeDownload = try await store.getDownloadChapter(
            sourceKey: "legacy-source",
            comicID: "legacy-comic",
            chapterID: "chapter-1"
        )
        let download = try XCTUnwrap(maybeDownload)
        let legacyDownloadID = download.id
        let legacyDownloadStatus = download.status
        let legacyDownloadDownloadedPages = download.downloadedPages
        let legacyDownloadTotalPages = download.totalPages
        let legacyDownloadDescription = download.comicDescription
        XCTAssertEqual(legacyDownloadID, 1)
        XCTAssertEqual(legacyDownloadStatus, .downloading)
        XCTAssertEqual(legacyDownloadDownloadedPages, 5)
        XCTAssertEqual(legacyDownloadTotalPages, 12)
        XCTAssertNil(legacyDownloadDescription)

        let maybeOffline = try await store.getOfflineChapter(
            sourceKey: "legacy-source",
            comicID: "legacy-comic",
            chapterID: "chapter-1"
        )
        let offline = try XCTUnwrap(maybeOffline)
        let legacyOfflineID = offline.id
        let legacyOfflinePageCount = offline.pageCount
        let legacyOfflineVerifiedPageCount = offline.verifiedPageCount
        let legacyOfflineIntegrityStatus = offline.integrityStatus
        let legacyOfflineLastVerifiedAt = offline.lastVerifiedAt
        let legacyOfflineDescription = offline.comicDescription
        XCTAssertEqual(legacyOfflineID, 1)
        XCTAssertEqual(legacyOfflinePageCount, 12)
        XCTAssertEqual(legacyOfflineVerifiedPageCount, 0)
        XCTAssertEqual(legacyOfflineIntegrityStatus, .incomplete)
        XCTAssertEqual(legacyOfflineLastVerifiedAt, 0)
        XCTAssertEqual(legacyOfflineDescription, "Legacy Description")
    }

    func testBackupPayloadRoundTripsLibraryDataIntoFreshStore() async throws {
        let sourceStore = try makeStore()

        let favorite = FavoriteComic(
            id: "comic-restore",
            sourceKey: "source-restore",
            title: "Restore Comic",
            coverURL: nil,
            createdAt: 123
        )
        try await sourceStore.upsertFavorite(favorite)

        let shelf = try await sourceStore.createBookmarkShelf(name: "Saved")
        try await sourceStore.addBookmarks(comicKeys: ["source-restore::comic-restore"], toShelfID: shelf.id)
        _ = try await sourceStore.addHistoryAndFetch(
            comicID: "comic-restore",
            sourceKey: "source-restore",
            title: "Restore Comic",
            coverURL: nil,
            author: "Restore Author",
            tags: ["restore", "backup"],
            chapterID: "chapter-restore",
            chapter: "Chapter Restore",
            page: 11
        )

        let sourceFavorites = try await sourceStore.listFavorites(limit: 10)
        let sourceCategories = try await sourceStore.listFavoriteCategories()
        let sourceMemberships = try await sourceStore.listFavoriteCategoryMemberships()
        let sourceHistory = try await sourceStore.listHistory(limit: 10)

        let payload = AppBackupService.makePayload(
            favorites: sourceFavorites,
            categories: sourceCategories,
            categoryMemberships: sourceMemberships,
            history: sourceHistory
        )
        let encoded = try AppBackupService.encodePayload(payload)
        let decoded = try AppBackupService.decodePayload(data: encoded)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("offline_chapters"))
        XCTAssertFalse(encodedText.contains("tracker_sync_events"))
        XCTAssertFalse(encodedText.contains("downloads"))

        let restoredStore = try makeStore()
        try await restoredStore.replaceFavorites(with: decoded.library.favorites)
        try await restoredStore.replaceFavoriteCategories(
            with: decoded.library.categories,
            memberships: decodedMemberships(from: decoded)
        )
        try await restoredStore.replaceHistory(with: decoded.library.history)

        let restoredFavorites = try await restoredStore.listFavorites(limit: 10)
        let restoredCategories = try await restoredStore.listFavoriteCategories()
        let restoredMemberships = try await restoredStore.listFavoriteCategoryMemberships()
        let restoredHistory = try await restoredStore.listHistory(limit: 10)
        XCTAssertEqual(restoredFavorites, sourceFavorites)
        XCTAssertEqual(restoredCategories, sourceCategories)
        XCTAssertEqual(restoredMemberships, sourceMemberships)
        XCTAssertEqual(restoredHistory, sourceHistory)
    }

    func testOfflineIndexerRebuildsOfflineProjectionFromDiskMetadata() async throws {
        let baseDirectory = try makeTemporaryDirectory()
        let databaseURL = baseDirectory.appendingPathComponent("database/source_runtime.sqlite3")
        let downloadsRoot = baseDirectory.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadsRoot, withIntermediateDirectories: true)

        let store = try SQLiteStore(databaseURL: databaseURL)
        try await store.upsertOfflineChapter(
            sourceKey: "stale-source",
            comicID: "stale-comic",
            comicTitle: "Stale Comic",
            coverURL: nil,
            comicDescription: nil,
            chapterID: "stale-chapter",
            chapterTitle: "Stale Chapter",
            pageCount: 1,
            verifiedPageCount: 1,
            integrityStatus: .complete,
            directoryPath: "/tmp/stale",
            downloadedAt: 1,
            lastVerifiedAt: 1
        )

        let chapterDirectory = downloadsRoot
            .appendingPathComponent("source-a", isDirectory: true)
            .appendingPathComponent("comic-1", isDirectory: true)
            .appendingPathComponent("chapter-1", isDirectory: true)
        try FileManager.default.createDirectory(at: chapterDirectory, withIntermediateDirectories: true)

        let metadata = OfflineMetadata(
            sourceKey: "source-a",
            comicID: "comic-1",
            comicTitle: "Indexed Comic",
            coverURL: "https://example.com/indexed.jpg",
            comicDescription: "Indexed Description",
            chapterID: "chapter-1",
            chapterTitle: "Indexed Chapter",
            totalPages: 3,
            downloadedAt: 777
        )
        let metadataURL = chapterDirectory.appendingPathComponent("metadata.json")
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: metadataURL, options: .atomic)
        try Data([0x00]).write(to: chapterDirectory.appendingPathComponent("001.jpg"), options: .atomic)
        try Data([0x00]).write(to: chapterDirectory.appendingPathComponent("002.png"), options: .atomic)
        try Data("ignore".utf8).write(to: chapterDirectory.appendingPathComponent("note.txt"), options: .atomic)

        let indexer = OfflineLibraryIndexer(database: store, rootDirectory: downloadsRoot)
        try await indexer.reindex()

        let items = try await store.listOfflineChapters(limit: 10)
        XCTAssertEqual(items.count, 1)

        let item = try XCTUnwrap(items.first)
        let indexedSourceKey = item.sourceKey
        let indexedComicID = item.comicID
        let indexedComicTitle = item.comicTitle
        let indexedChapterID = item.chapterID
        let indexedPageCount = item.pageCount
        let indexedVerifiedPageCount = item.verifiedPageCount
        let indexedIntegrityStatus = item.integrityStatus
        let indexedDirectoryPath = item.directoryPath
        let indexedDownloadedAt = item.downloadedAt
        XCTAssertEqual(indexedSourceKey, "source-a")
        XCTAssertEqual(indexedComicID, "comic-1")
        XCTAssertEqual(indexedComicTitle, "Indexed Comic")
        XCTAssertEqual(indexedChapterID, "chapter-1")
        XCTAssertEqual(indexedPageCount, 3)
        XCTAssertEqual(indexedVerifiedPageCount, 2)
        XCTAssertEqual(indexedIntegrityStatus, .incomplete)
        XCTAssertEqual(indexedDirectoryPath, chapterDirectory.path)
        XCTAssertEqual(indexedDownloadedAt, 777)
    }

    func testReaderPageTranslationDocumentRoundTripsThroughSQLiteStore() async throws {
        let store = try makeStore()
        let document = ReaderPageTranslationDocument(
            id: 0,
            sourceKey: "source-a",
            comicID: "comic-1",
            chapterID: "chapter-1",
            pageIndex: 4,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            provider: "custom-http",
            status: .ready,
            currentStage: .ready,
            imageRequestKey: "GET|https://example.com/page-4.jpg",
            imageFingerprint: "fp-4",
            pipelineVersion: "reader-page-translation-v1",
            providerConfigHash: "provider-hash-4",
            blocks: [
                ReaderTextBlock(
                    id: "block-1",
                    sourceRect: ReaderNormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.15),
                    containerRect: nil,
                    readingDirection: .verticalRL,
                    sourceText: "原文",
                    translatedText: "Translation",
                    styleHints: nil,
                    zIndex: 0,
                    confidence: 0.8
                )
            ],
            cleanupRegions: [],
            renderedAsset: ReaderRenderedPageAsset(
                localFilePath: "/tmp/page-4.png",
                pixelWidth: 1200,
                pixelHeight: 1800,
                renderMode: .translated,
                provider: "custom-http",
                updatedAt: 444
            ),
            errorText: nil,
            updatedAt: 444
        )

        let saved = try await store.upsertReaderPageTranslationDocument(document)
        let loaded = try await store.getReaderPageTranslationDocument(
            sourceKey: "source-a",
            comicID: "comic-1",
            chapterID: "chapter-1",
            pageIndex: 4,
            targetLanguage: .english,
            imageRequestKey: "GET|https://example.com/page-4.jpg",
            pipelineVersion: "reader-page-translation-v1",
            providerConfigHash: "provider-hash-4"
        )

        let unwrapped = try XCTUnwrap(loaded)
        XCTAssertEqual(unwrapped.blocks, saved.blocks)
        XCTAssertEqual(unwrapped.renderedAsset, saved.renderedAsset)
        XCTAssertEqual(unwrapped.currentStage, .ready)
        XCTAssertEqual(unwrapped.provider, "custom-http")
    }

    func testReaderPageTranslationDocumentLookupPartitionsByProviderConfigHash() async throws {
        let store = try makeStore()
        let first = makeReaderPageTranslationDocument(providerConfigHash: "hash-a", translatedText: "First")
        let second = makeReaderPageTranslationDocument(providerConfigHash: "hash-b", translatedText: "Second")

        _ = try await store.upsertReaderPageTranslationDocument(first)
        _ = try await store.upsertReaderPageTranslationDocument(second)

        let loadedFirst = try await store.getReaderPageTranslationDocument(
            sourceKey: first.sourceKey,
            comicID: first.comicID,
            chapterID: first.chapterID,
            pageIndex: first.pageIndex,
            targetLanguage: first.targetLanguage,
            imageRequestKey: first.imageRequestKey,
            pipelineVersion: first.pipelineVersion,
            providerConfigHash: "hash-a"
        )
        let loadedSecond = try await store.getReaderPageTranslationDocument(
            sourceKey: second.sourceKey,
            comicID: second.comicID,
            chapterID: second.chapterID,
            pageIndex: second.pageIndex,
            targetLanguage: second.targetLanguage,
            imageRequestKey: second.imageRequestKey,
            pipelineVersion: second.pipelineVersion,
            providerConfigHash: "hash-b"
        )

        XCTAssertEqual(loadedFirst?.providerConfigHash, "hash-a")
        XCTAssertEqual(loadedFirst?.blocks.first?.translatedText, "First")
        XCTAssertEqual(loadedSecond?.providerConfigHash, "hash-b")
        XCTAssertEqual(loadedSecond?.blocks.first?.translatedText, "Second")
    }

    func testNormalizedEquivalentKoharuProviderConfigHashesMatch() throws {
        let lhs = try KoharuProviderConfigurationFingerprint.make(
            configuration: ReaderPageTranslationBackendConfiguration(
                kind: .koharu,
                koharuBaseURL: "  https://koharu.example.com/service/  ",
                requestTimeoutSeconds: 60,
                koharuLLM: ReaderKoharuLLMConfiguration(
                    mode: .provider,
                    providerID: " provider-a ",
                    modelID: " model-1 ",
                    temperature: 0.4,
                    maxTokens: 1024,
                    customSystemPrompt: " Translate naturally. "
                )
            )
        )
        let rhs = try KoharuProviderConfigurationFingerprint.make(
            configuration: ReaderPageTranslationBackendConfiguration(
                kind: .koharu,
                koharuBaseURL: "https://koharu.example.com/service/api/v1",
                requestTimeoutSeconds: 60,
                koharuLLM: ReaderKoharuLLMConfiguration(
                    mode: .provider,
                    providerID: "provider-a",
                    modelID: "model-1",
                    temperature: 0.4,
                    maxTokens: 1024,
                    customSystemPrompt: "Translate naturally."
                )
            )
        )

        XCTAssertEqual(lhs, rhs)
    }

    func testKoharuProviderFingerprintChangesWhenModeChanges() throws {
        try assertKoharuProviderFingerprintFieldChange(
            baseline: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            ),
            changed: ReaderKoharuLLMConfiguration(
                mode: .local,
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            )
        )
    }

    func testKoharuProviderFingerprintChangesWhenProviderIDChanges() throws {
        try assertKoharuProviderFingerprintFieldChange(
            baseline: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            ),
            changed: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-b",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            )
        )
    }

    func testKoharuProviderFingerprintChangesWhenModelIDChanges() throws {
        try assertKoharuProviderFingerprintFieldChange(
            baseline: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            ),
            changed: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-2",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            )
        )
    }

    func testKoharuProviderFingerprintChangesWhenTemperatureChanges() throws {
        try assertKoharuProviderFingerprintFieldChange(
            baseline: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            ),
            changed: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.6,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            )
        )
    }

    func testKoharuProviderFingerprintChangesWhenMaxTokensChanges() throws {
        try assertKoharuProviderFingerprintFieldChange(
            baseline: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            ),
            changed: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 2048,
                customSystemPrompt: "Translate naturally."
            )
        )
    }

    func testKoharuProviderFingerprintChangesWhenCustomSystemPromptChanges() throws {
        try assertKoharuProviderFingerprintFieldChange(
            baseline: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate naturally."
            ),
            changed: ReaderKoharuLLMConfiguration(
                mode: .provider,
                providerID: "provider-a",
                modelID: "model-1",
                temperature: 0.4,
                maxTokens: 1024,
                customSystemPrompt: "Translate literally."
            )
        )
    }

    private func makeStore() throws -> SQLiteStore {
        let directory = try makeTemporaryDirectory()
        let databaseURL = directory.appendingPathComponent("source_runtime.sqlite3")
        return try SQLiteStore(databaseURL: databaseURL)
    }

    private func assertKoharuProviderFingerprintFieldChange(
        baseline: ReaderKoharuLLMConfiguration,
        changed: ReaderKoharuLLMConfiguration,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let baselineFingerprint = try makeKoharuProviderFingerprint(koharuLLM: baseline)
        let changedFingerprint = try makeKoharuProviderFingerprint(koharuLLM: changed)

        XCTAssertNotEqual(baselineFingerprint, changedFingerprint, file: file, line: line)
    }

    private func makeKoharuProviderFingerprint(koharuLLM: ReaderKoharuLLMConfiguration) throws -> String {
        try KoharuProviderConfigurationFingerprint.make(
            configuration: ReaderPageTranslationBackendConfiguration(
                kind: .koharu,
                koharuBaseURL: "https://koharu.example.com/service/api/v1",
                requestTimeoutSeconds: 60,
                koharuLLM: koharuLLM
            )
        )
    }

    private func makeReaderPageTranslationDocument(
        providerConfigHash: String,
        translatedText: String
    ) -> ReaderPageTranslationDocument {
        ReaderPageTranslationDocument(
            id: 0,
            sourceKey: "source-a",
            comicID: "comic-1",
            chapterID: "chapter-1",
            pageIndex: 4,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            provider: "custom-http",
            status: .ready,
            currentStage: .ready,
            imageRequestKey: "GET|https://example.com/page-4.jpg",
            imageFingerprint: "fp-4",
            pipelineVersion: "reader-page-translation-v1",
            providerConfigHash: providerConfigHash,
            blocks: [
                ReaderTextBlock(
                    id: "block-1",
                    sourceRect: ReaderNormalizedRect(x: 0.1, y: 0.2, width: 0.2, height: 0.15),
                    containerRect: nil,
                    readingDirection: .verticalRL,
                    sourceText: "原文",
                    translatedText: translatedText,
                    styleHints: nil,
                    zIndex: 0,
                    confidence: 0.8
                )
            ],
            cleanupRegions: [],
            renderedAsset: ReaderRenderedPageAsset(
                localFilePath: "/tmp/page-4.png",
                pixelWidth: 1200,
                pixelHeight: 1800,
                renderMode: .translated,
                provider: "custom-http",
                updatedAt: 444
            ),
            errorText: nil,
            updatedAt: 444
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func decodedMemberships(from payload: AppBackupPayload) -> [Int64: Set<String>] {
        Dictionary(uniqueKeysWithValues: payload.library.categoryMemberships.compactMap { key, value in
            guard let id = Int64(key) else { return nil }
            return (id, Set(value))
        })
    }

    private func seedLegacyDatabase(at url: URL, statements: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw TestError.sqlite("open failed")
        }
        defer { sqlite3_close(database) }

        for statement in statements {
            var errorMessage: UnsafeMutablePointer<Int8>?
            guard sqlite3_exec(database, statement, nil, nil, &errorMessage) == SQLITE_OK else {
                let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
                sqlite3_free(errorMessage)
                throw TestError.sqlite(message)
            }
        }
    }

    private struct OfflineMetadata: Encodable {
        let sourceKey: String
        let comicID: String
        let comicTitle: String
        let coverURL: String?
        let comicDescription: String?
        let chapterID: String
        let chapterTitle: String
        let totalPages: Int
        let downloadedAt: Int64
    }

    private enum TestError: Error {
        case sqlite(String)
    }
}
