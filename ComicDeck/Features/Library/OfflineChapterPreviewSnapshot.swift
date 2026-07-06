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
        items
            .filter {
                $0.sourceKey == item.sourceKey &&
                $0.comicID == item.comicID &&
                $0.integrityStatus == .complete
            }
            .sorted { lhs, rhs in
                if lhs.downloadedAt != rhs.downloadedAt { return lhs.downloadedAt < rhs.downloadedAt }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
            }
            .map {
                ComicChapter(
                    id: $0.chapterID,
                    title: $0.chapterTitle.isEmpty ? $0.chapterID : $0.chapterTitle
                )
            }
    }
}
