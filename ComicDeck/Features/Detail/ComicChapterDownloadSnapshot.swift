import Foundation

struct ComicChapterDownloadSnapshot: Hashable {
    let stateByChapterID: [String: DownloadStatus]
    let completedCount: Int

    init(
        sourceKey: String,
        comicID: String,
        downloads: [DownloadChapterItem],
        offlineChapters: [OfflineChapterAsset]
    ) {
        var state: [String: DownloadStatus] = [:]

        for chapter in downloads where chapter.sourceKey == sourceKey && chapter.comicID == comicID {
            state[chapter.chapterID] = chapter.status
        }

        for chapter in offlineChapters where chapter.sourceKey == sourceKey && chapter.comicID == comicID {
            state[chapter.chapterID] = chapter.integrityStatus == .complete ? .completed : .failed
        }

        self.stateByChapterID = state
        self.completedCount = state.values.reduce(into: 0) { count, status in
            if status == .completed {
                count += 1
            }
        }
    }
}
