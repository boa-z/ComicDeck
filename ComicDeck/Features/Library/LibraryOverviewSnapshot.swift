import Foundation

struct LibraryOverviewSnapshot: Hashable {
    let recentHistory: [ReadingHistoryItem]
    let recentHistoryIDs: [ReadingHistoryItem.ID]
    let offlinePreview: OfflineChapterPreviewSnapshot
    let recentOfflineChapterIDs: [OfflineChapterAsset.ID]

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
        let offlinePreview = OfflineChapterPreviewBuilder.snapshot(
            from: offlineChapters,
            limit: offlineLimit
        )
        self.offlinePreview = offlinePreview
        self.recentOfflineChapterIDs = offlinePreview.recentChapters.map(\.id)
    }
}
