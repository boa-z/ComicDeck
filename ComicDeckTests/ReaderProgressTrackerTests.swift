import XCTest
@testable import ComicDeck

@MainActor
final class ReaderProgressTrackerTests: XCTestCase {
    func testMarkVisibleOnlyRecordsStartTimeOnce() {
        let tracker = ReaderProgressTracker()
        let first = Date(timeIntervalSince1970: 100)
        let second = Date(timeIntervalSince1970: 120)
        let end = Date(timeIntervalSince1970: 160)

        tracker.markVisible(now: first)
        tracker.markVisible(now: second)
        let duration = tracker.finishReadingSession(totalPages: 5, now: end)

        XCTAssertNotNil(duration)
        XCTAssertEqual(duration ?? 0, 60, accuracy: 0.001)
    }

    func testFinishReadingSessionWithoutPagesClearsActiveSessionWithoutRecordingDuration() {
        let tracker = ReaderProgressTracker()
        tracker.markVisible(now: Date(timeIntervalSince1970: 100))

        let firstFinish = tracker.finishReadingSession(totalPages: 0, now: Date(timeIntervalSince1970: 160))
        let secondFinish = tracker.finishReadingSession(totalPages: 5, now: Date(timeIntervalSince1970: 220))

        XCTAssertNil(firstFinish)
        XCTAssertNil(secondFinish)
    }

    func testHistoryPayloadUsesFallbackChapterIDAndClampsDisplayedPage() {
        let tracker = ReaderProgressTracker()
        let item = ComicSummary(
            id: "comic-1",
            sourceKey: "source-a",
            title: "Test Comic",
            coverURL: "https://example.com/cover.jpg",
            author: "Author",
            tags: ["tag-1", "tag-2"]
        )

        let payload = tracker.historyPayload(
            item: item,
            chapterID: "chapter-1",
            chapterTitle: "",
            totalPages: 12,
            canRenderReader: true,
            displayedPage: 0
        )

        XCTAssertEqual(
            payload,
            ReaderProgressTracker.HistoryPayload(
                comicID: "comic-1",
                sourceKey: "source-a",
                title: "Test Comic",
                coverURL: "https://example.com/cover.jpg",
                author: "Author",
                tags: ["tag-1", "tag-2"],
                chapterID: "chapter-1",
                chapter: "chapter-1",
                page: 1
            )
        )
    }

    func testHistoryPayloadReturnsNilWhenReaderCannotRender() {
        let tracker = ReaderProgressTracker()
        let item = ComicSummary(id: "comic-1", sourceKey: "source-a", title: "Test Comic")

        let payload = tracker.historyPayload(
            item: item,
            chapterID: "chapter-1",
            chapterTitle: "Chapter 1",
            totalPages: 12,
            canRenderReader: false,
            displayedPage: 3
        )

        XCTAssertNil(payload)
    }

    func testCompletedChapterProgressReturnsCurrentStatusBeforeLastChapter() {
        let tracker = ReaderProgressTracker()

        let completion = tracker.completedChapterProgress(
            totalPages: 10,
            resolvedPageCount: 10,
            lastDisplayedPage: 10,
            lastPageIsResolved: true,
            currentChapterIndex: 1,
            chapterCount: 5
        )

        XCTAssertEqual(completion?.progress, 2)
        XCTAssertEqual(completion?.status, .current)
    }

    func testCompletedChapterProgressReturnsCompletedStatusOnLastChapter() {
        let tracker = ReaderProgressTracker()

        let completion = tracker.completedChapterProgress(
            totalPages: 10,
            resolvedPageCount: 10,
            lastDisplayedPage: 10,
            lastPageIsResolved: true,
            currentChapterIndex: 4,
            chapterCount: 5
        )

        XCTAssertEqual(completion?.progress, 5)
        XCTAssertEqual(completion?.status, .completed)
    }
}
