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
        let matchingOfflineChapters = offlineChapters.filter {
            $0.sourceKey == sourceKey && $0.comicID == comicID
        }
        let offlineByChapterID = Dictionary(
            matchingOfflineChapters.map { ($0.chapterID, $0) },
            uniquingKeysWith: { existing, replacement in
                replacement.updatedAt > existing.updatedAt ? replacement : existing
            }
        )
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
            chapters: detail.chapters,
            firstChapter: firstChapter,
            offlineChapters: matchingOfflineChapters
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
        chapters: [ComicChapter],
        firstChapter: ComicDetailChapterTarget,
        offlineChapters: [OfflineChapterAsset]
    ) -> ComicDetailChapterTarget {
        let chapterOrder = Dictionary(uniqueKeysWithValues: chapters.enumerated().map { ($1.id, $0) })
        let completed = offlineChapters
            .filter { $0.integrityStatus == .complete }
            .sorted { lhs, rhs in
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
        var items = chapters.filter { chapter in
            guard !normalized.isEmpty else { return true }
            return chapter.id.lowercased().contains(normalized) ||
                chapter.title.lowercased().contains(normalized)
        }
        if descending {
            items.reverse()
        }
        return items
    }
}
