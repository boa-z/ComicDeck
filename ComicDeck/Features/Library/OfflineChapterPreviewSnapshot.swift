import Foundation

struct OfflineChapterPreviewSnapshot: Hashable {
    let readyCount: Int
    let recentChapters: [OfflineChapterAsset]
}

enum OfflineChapterPreviewBuilder {
    static func snapshot(from items: [OfflineChapterAsset], limit: Int) -> OfflineChapterPreviewSnapshot {
        guard limit > 0 else {
            let readyCount = items.lazy.filter { $0.integrityStatus == .complete }.count
            return OfflineChapterPreviewSnapshot(readyCount: readyCount, recentChapters: [])
        }

        var readyCount = 0
        var recentChapters: [OfflineChapterAsset] = []
        recentChapters.reserveCapacity(min(limit, items.count))

        for item in items where item.integrityStatus == .complete {
            readyCount += 1
            insert(item, into: &recentChapters, limit: limit)
        }

        return OfflineChapterPreviewSnapshot(readyCount: readyCount, recentChapters: recentChapters)
    }

    private static func insert(_ item: OfflineChapterAsset, into recentChapters: inout [OfflineChapterAsset], limit: Int) {
        let insertionIndex = recentChapters.firstIndex { existing in
            isNewer(item, than: existing)
        } ?? recentChapters.endIndex
        if insertionIndex < limit {
            recentChapters.insert(item, at: insertionIndex)
            if recentChapters.count > limit {
                recentChapters.removeLast()
            }
        } else if recentChapters.count < limit {
            recentChapters.append(item)
        }
    }

    private static func isNewer(_ lhs: OfflineChapterAsset, than rhs: OfflineChapterAsset) -> Bool {
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.downloadedAt > rhs.downloadedAt
    }
}

enum OfflineChapterSequenceBuilder {
    static func sequence(for item: OfflineChapterAsset, in items: [OfflineChapterAsset]) -> [ComicChapter] {
        var chapters: [OfflineChapterAsset] = []
        chapters.reserveCapacity(items.count)
        for candidate in items where
            candidate.sourceKey == item.sourceKey &&
            candidate.comicID == item.comicID &&
            candidate.integrityStatus == .complete
        {
            chapters.append(candidate)
        }

        chapters.sort { lhs, rhs in
            if lhs.downloadedAt != rhs.downloadedAt { return lhs.downloadedAt < rhs.downloadedAt }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
        }

        var sequence: [ComicChapter] = []
        sequence.reserveCapacity(chapters.count)
        for chapter in chapters {
            sequence.append(ComicChapter(
                id: chapter.chapterID,
                title: chapter.chapterTitle.isEmpty ? chapter.chapterID : chapter.chapterTitle
            ))
        }
        return sequence
    }
}
