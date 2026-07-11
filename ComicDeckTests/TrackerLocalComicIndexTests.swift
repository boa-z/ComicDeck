import XCTest
@testable import ComicDeck

@MainActor
final class TrackerLocalComicIndexTests: XCTestCase {
    func testIndexPreservesFavoriteHistoryOfflinePriority() throws {
        let index = TrackerLocalComicIndex(
            favorites: [favorite(title: "Favorite", coverURL: "favorite.jpg")],
            history: [history(title: "History", coverURL: "history.jpg")],
            offlineChapters: [offline(title: "Offline", coverURL: "offline.jpg")]
        )

        let comic = try XCTUnwrap(index.comic(sourceKey: "source-a", comicID: "comic-1"))

        XCTAssertEqual(comic.title, "Favorite")
        XCTAssertEqual(comic.coverURL, "favorite.jpg")

        let historyIndex = TrackerLocalComicIndex(
            favorites: [],
            history: [history(title: "History", coverURL: "history.jpg")],
            offlineChapters: [offline(title: "Offline", coverURL: "offline.jpg")]
        )
        XCTAssertEqual(
            historyIndex.comic(sourceKey: "source-a", comicID: "comic-1")?.title,
            "History"
        )
    }

    func testIndexKeepsFirstMatchWithinTierAndSeparatesSources() throws {
        let index = TrackerLocalComicIndex(
            favorites: [],
            history: [],
            offlineChapters: [
                offline(title: "First", coverURL: "first.jpg"),
                offline(title: "Later", coverURL: "later.jpg"),
                offline(sourceKey: "source-b", title: "Other Source", coverURL: "other.jpg")
            ]
        )

        let first = try XCTUnwrap(index.comic(sourceKey: "source-a", comicID: "comic-1"))
        let otherSource = try XCTUnwrap(index.comic(sourceKey: "source-b", comicID: "comic-1"))

        XCTAssertEqual(first.title, "First")
        XCTAssertEqual(otherSource.title, "Other Source")
        XCTAssertNil(index.comic(sourceKey: "source-a", comicID: "missing"))
    }

    private func favorite(title: String, coverURL: String) -> FavoriteComic {
        FavoriteComic(
            id: "comic-1",
            sourceKey: "source-a",
            title: title,
            coverURL: coverURL,
            createdAt: 1
        )
    }

    private func history(title: String, coverURL: String) -> ReadingHistoryItem {
        ReadingHistoryItem(
            id: 1,
            comicID: "comic-1",
            sourceKey: "source-a",
            title: title,
            coverURL: coverURL,
            chapter: "Chapter 1",
            page: 1,
            updatedAt: 1
        )
    }

    private func offline(
        sourceKey: String = "source-a",
        title: String,
        coverURL: String
    ) -> OfflineChapterAsset {
        OfflineChapterAsset(
            id: 1,
            sourceKey: sourceKey,
            comicID: "comic-1",
            comicTitle: title,
            coverURL: coverURL,
            comicDescription: nil,
            chapterID: "chapter-\(sourceKey)-\(title)",
            chapterTitle: "Chapter 1",
            pageCount: 1,
            verifiedPageCount: 1,
            integrityStatus: .complete,
            directoryPath: "/tmp/comic-1",
            downloadedAt: 1,
            lastVerifiedAt: 1,
            updatedAt: 1
        )
    }
}
