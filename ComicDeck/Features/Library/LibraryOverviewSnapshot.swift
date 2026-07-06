import Foundation

struct LibraryOverviewSnapshot: Hashable {
    let recentHistory: [ReadingHistoryItem]
    let recentHistoryIDs: [ReadingHistoryItem.ID]
    let offlinePreview: OfflineChapterPreviewSnapshot
    let recentOfflineChapterIDs: [OfflineChapterAsset.ID]
    private let recentHistoryByID: [ReadingHistoryItem.ID: ReadingHistoryItem]
    private let recentOfflineChapterByID: [OfflineChapterAsset.ID: OfflineChapterAsset]

    var readyOfflineCount: Int { offlinePreview.readyCount }
    var recentOfflineChapters: [OfflineChapterAsset] { offlinePreview.recentChapters }

    init(
        history: [ReadingHistoryItem],
        offlineChapters: [OfflineChapterAsset],
        historyLimit: Int,
        offlineLimit: Int
    ) {
        let clampedHistoryLimit = max(historyLimit, 0)
        let recentHistory = clampedHistoryLimit == 0
            ? []
            : Array(history.prefix(clampedHistoryLimit))
        self.recentHistory = recentHistory
        self.recentHistoryIDs = recentHistory.map(\.id)
        var recentHistoryByID: [ReadingHistoryItem.ID: ReadingHistoryItem] = [:]
        recentHistoryByID.reserveCapacity(recentHistory.count)
        for item in recentHistory {
            recentHistoryByID[item.id] = item
        }
        self.recentHistoryByID = recentHistoryByID
        let offlinePreview = OfflineChapterPreviewBuilder.snapshot(
            from: offlineChapters,
            limit: offlineLimit
        )
        self.offlinePreview = offlinePreview
        self.recentOfflineChapterIDs = offlinePreview.recentChapters.map(\.id)
        var recentOfflineChapterByID: [OfflineChapterAsset.ID: OfflineChapterAsset] = [:]
        recentOfflineChapterByID.reserveCapacity(offlinePreview.recentChapters.count)
        for item in offlinePreview.recentChapters {
            recentOfflineChapterByID[item.id] = item
        }
        self.recentOfflineChapterByID = recentOfflineChapterByID
    }

    func recentHistoryItem(matching id: ReadingHistoryItem.ID?) -> ReadingHistoryItem? {
        guard let id else { return nil }
        return recentHistoryByID[id]
    }

    func recentOfflineChapter(matching id: OfflineChapterAsset.ID?) -> OfflineChapterAsset? {
        guard let id else { return nil }
        return recentOfflineChapterByID[id]
    }
}
