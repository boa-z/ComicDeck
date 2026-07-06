import Foundation

struct ComicDetailChapterTarget: Hashable {
    let chapterID: String
    let chapterTitle: String
    let localDirectory: String?
}

struct ComicDetailContinueTarget: Hashable {
    let chapterID: String
    let chapterTitle: String
    let page: Int
    let localDirectory: String?
}

struct ComicDetailChapterSnapshot: Hashable {
    let displayedChapters: [ComicChapter]
    let firstChapter: ComicDetailChapterTarget
    let readTarget: ComicDetailChapterTarget
    let continueTarget: ComicDetailContinueTarget?
    let downloadStateByChapterID: [String: DownloadStatus]
    let offlineChapterCount: Int

    init(
        sourceKey: String,
        comicID: String,
        detail: ComicDetail,
        chapterQuery: String,
        chapterDescending: Bool,
        downloads: [DownloadChapterItem],
        offlineChapters: [OfflineChapterAsset],
        latestHistory: ReadingHistoryItem?
    ) {
        var matchingOfflineChapters: [OfflineChapterAsset] = []
        var completedOfflineChapters: [OfflineChapterAsset] = []
        var offlineByChapterID: [String: OfflineChapterAsset] = [:]
        matchingOfflineChapters.reserveCapacity(offlineChapters.count)
        completedOfflineChapters.reserveCapacity(offlineChapters.count)
        offlineByChapterID.reserveCapacity(offlineChapters.count)

        for offlineChapter in offlineChapters where offlineChapter.sourceKey == sourceKey && offlineChapter.comicID == comicID {
            matchingOfflineChapters.append(offlineChapter)
            if offlineChapter.integrityStatus == .complete {
                completedOfflineChapters.append(offlineChapter)
            }
            if let existing = offlineByChapterID[offlineChapter.chapterID] {
                if offlineChapter.updatedAt > existing.updatedAt {
                    offlineByChapterID[offlineChapter.chapterID] = offlineChapter
                }
            } else {
                offlineByChapterID[offlineChapter.chapterID] = offlineChapter
            }
        }

        var chapterOrder: [String: Int] = [:]
        chapterOrder.reserveCapacity(detail.chapters.count)
        for (index, chapter) in detail.chapters.enumerated() {
            chapterOrder[chapter.id] = index
        }

        let downloadSnapshot = ComicChapterDownloadSnapshot(
            sourceKey: sourceKey,
            comicID: comicID,
            downloads: downloads,
            offlineChapters: matchingOfflineChapters
        )

        let firstChapter = Self.firstChapter(from: detail.chapters)

        self.displayedChapters = Self.displayedChapters(
            from: detail.chapters,
            query: chapterQuery,
            descending: chapterDescending
        )
        self.firstChapter = firstChapter
        self.readTarget = Self.readTarget(
            firstChapter: firstChapter,
            chapterOrder: chapterOrder,
            completedOfflineChapters: completedOfflineChapters
        )
        self.continueTarget = Self.continueTarget(
            chapters: detail.chapters,
            firstChapter: firstChapter,
            offlineByChapterID: offlineByChapterID,
            latestHistory: latestHistory
        )
        self.downloadStateByChapterID = downloadSnapshot.stateByChapterID
        self.offlineChapterCount = downloadSnapshot.completedCount
    }

    private static func firstChapter(from chapters: [ComicChapter]) -> ComicDetailChapterTarget {
        if let first = chapters.first {
            return ComicDetailChapterTarget(
                chapterID: first.id,
                chapterTitle: first.title.isEmpty ? first.id : first.title,
                localDirectory: nil
            )
        }
        return ComicDetailChapterTarget(chapterID: "1", chapterTitle: "Chapter 1", localDirectory: nil)
    }

    private static func readTarget(
        firstChapter: ComicDetailChapterTarget,
        chapterOrder: [String: Int],
        completedOfflineChapters: [OfflineChapterAsset]
    ) -> ComicDetailChapterTarget {
        let completed = completedOfflineChapters.sorted { lhs, rhs in
            let leftIndex = chapterOrder[lhs.chapterID] ?? Int.max
            let rightIndex = chapterOrder[rhs.chapterID] ?? Int.max
            if leftIndex != rightIndex { return leftIndex < rightIndex }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.chapterID.localizedCompare(rhs.chapterID) == .orderedAscending
        }

        guard let preferred = completed.first else {
            return firstChapter
        }
        return ComicDetailChapterTarget(
            chapterID: preferred.chapterID,
            chapterTitle: preferred.chapterTitle.isEmpty ? preferred.chapterID : preferred.chapterTitle,
            localDirectory: preferred.directoryPath
        )
    }

    private static func continueTarget(
        chapters: [ComicChapter],
        firstChapter: ComicDetailChapterTarget,
        offlineByChapterID: [String: OfflineChapterAsset],
        latestHistory: ReadingHistoryItem?
    ) -> ComicDetailContinueTarget? {
        guard let latestHistory else { return nil }
        let chapter = resolveChapter(
            from: chapters,
            fallback: firstChapter,
            historyChapterID: latestHistory.chapterID,
            historyChapter: latestHistory.chapter
        )
        return ComicDetailContinueTarget(
            chapterID: chapter.chapterID,
            chapterTitle: chapter.chapterTitle,
            page: max(1, latestHistory.page),
            localDirectory: offlineByChapterID[chapter.chapterID]?.directoryPath
        )
    }

    private static func resolveChapter(
        from chapters: [ComicChapter],
        fallback: ComicDetailChapterTarget,
        historyChapterID: String?,
        historyChapter: String?
    ) -> ComicDetailChapterTarget {
        let candidates = [historyChapterID, historyChapter]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return fallback }

        for candidate in candidates {
            if let matched = chapters.first(where: { $0.id == candidate || $0.title == candidate }) {
                return ComicDetailChapterTarget(
                    chapterID: matched.id,
                    chapterTitle: matched.title.isEmpty ? matched.id : matched.title,
                    localDirectory: nil
                )
            }
        }

        for candidate in candidates {
            if let matched = chapters.first(where: {
                $0.id.localizedCaseInsensitiveCompare(candidate) == .orderedSame ||
                    $0.title.localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }) {
                return ComicDetailChapterTarget(
                    chapterID: matched.id,
                    chapterTitle: matched.title.isEmpty ? matched.id : matched.title,
                    localDirectory: nil
                )
            }
        }

        return fallback
    }

    private static func displayedChapters(
        from chapters: [ComicChapter],
        query: String,
        descending: Bool
    ) -> [ComicChapter] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return descending ? Array(chapters.reversed()) : chapters
        }

        var items: [ComicChapter] = []
        items.reserveCapacity(chapters.count)
        for chapter in chapters {
            if chapter.id.lowercased().contains(normalized) ||
                chapter.title.lowercased().contains(normalized) {
                items.append(chapter)
            }
        }
        if descending {
            items.reverse()
        }
        return items
    }
}
