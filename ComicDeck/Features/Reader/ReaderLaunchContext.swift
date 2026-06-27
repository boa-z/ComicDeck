import Foundation

struct ReaderLaunchContext: Identifiable, Hashable, Codable {
    let id: UUID
    let item: ComicSummary
    let chapterID: String
    let chapterTitle: String
    let localDirectory: String?
    let initialPage: Int
    let chapterSequence: [ComicChapter]?

    init(
        id: UUID = UUID(),
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        localDirectory: String?,
        initialPage: Int,
        chapterSequence: [ComicChapter]?
    ) {
        self.id = id
        self.item = item
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.localDirectory = localDirectory
        self.initialPage = initialPage
        self.chapterSequence = chapterSequence
    }

    static func fromHistory(_ history: ReadingHistoryItem, using library: LibraryViewModel) -> ReaderLaunchContext? {
        guard let chapterID = history.chapterID?.trimmingCharacters(in: .whitespacesAndNewlines), !chapterID.isEmpty else {
            return nil
        }

        let summary = ComicSummary(
            id: history.comicID,
            sourceKey: history.sourceKey,
            title: history.title,
            coverURL: history.coverURL,
            author: history.author,
            tags: history.tags
        )
        let chapterTitle = history.chapter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (history.chapter ?? chapterID)
            : chapterID
        let offline = library.offlineChapter(
            sourceKey: history.sourceKey,
            comicID: history.comicID,
            chapterID: chapterID
        ).flatMap { $0.integrityStatus == .complete ? $0 : nil }

        return ReaderLaunchContext(
            item: summary,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            localDirectory: offline?.directoryPath,
            initialPage: max(1, history.page),
            chapterSequence: nil
        )
    }

    static func fromChapter(
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        initialPage: Int = 1,
        chapterSequence: [ComicChapter]? = nil,
        using library: LibraryViewModel
    ) -> ReaderLaunchContext {
        let normalizedTitle = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let offline = library.offlineChapter(
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapterID
        ).flatMap { $0.integrityStatus == .complete ? $0 : nil }

        return ReaderLaunchContext(
            item: item,
            chapterID: chapterID,
            chapterTitle: normalizedTitle.isEmpty ? chapterID : normalizedTitle,
            localDirectory: offline?.directoryPath,
            initialPage: max(1, initialPage),
            chapterSequence: chapterSequence
        )
    }
}
