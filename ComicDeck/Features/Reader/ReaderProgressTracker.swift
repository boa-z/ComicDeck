import Foundation

@MainActor
@Observable
final class ReaderProgressTracker {
    struct HistoryPayload: Equatable {
        let comicID: String
        let sourceKey: String
        let title: String
        let coverURL: String?
        let author: String?
        let tags: [String]
        let chapterID: String?
        let chapter: String?
        let page: Int
    }

    private var readingSessionStartedAt: Date?

    func markVisible(now: Date = Date()) {
        if readingSessionStartedAt == nil {
            readingSessionStartedAt = now
        }
    }

    func finishReadingSession(totalPages: Int, now: Date = Date()) -> TimeInterval? {
        guard let readingSessionStartedAt else { return nil }
        self.readingSessionStartedAt = nil
        guard totalPages > 0 else { return nil }
        return now.timeIntervalSince(readingSessionStartedAt)
    }

    func historyPayload(
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        totalPages: Int,
        canRenderReader: Bool,
        displayedPage: Int
    ) -> HistoryPayload? {
        guard totalPages > 0 else { return nil }
        guard canRenderReader else { return nil }
        let chapterValue = chapterTitle.isEmpty ? chapterID : chapterTitle
        return HistoryPayload(
            comicID: item.id,
            sourceKey: item.sourceKey,
            title: item.title,
            coverURL: item.coverURL,
            author: item.author,
            tags: item.tags,
            chapterID: chapterID,
            chapter: chapterValue,
            page: max(1, displayedPage)
        )
    }

    func completedChapterProgress(
        totalPages: Int,
        resolvedPageCount: Int,
        lastDisplayedPage: Int,
        lastPageIsResolved: Bool,
        currentChapterIndex: Int?,
        chapterCount: Int
    ) -> (progress: Int, status: TrackerReadingStatus)? {
        guard totalPages > 0 else { return nil }
        guard resolvedPageCount >= totalPages else { return nil }
        guard lastPageIsResolved else { return nil }
        guard lastDisplayedPage >= totalPages else { return nil }
        guard let currentChapterIndex else { return nil }
        let progress = currentChapterIndex + 1
        let status: TrackerReadingStatus = progress >= chapterCount ? .completed : .current
        return (progress, status)
    }
}
