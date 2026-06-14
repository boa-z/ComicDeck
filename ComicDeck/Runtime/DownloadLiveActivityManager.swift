import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

@available(iOS 16.1, *)
nonisolated struct ComicDownloadActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var comicTitle: String
        var chapterTitle: String
        var status: String
        var downloadedPages: Int
        var totalPages: Int
        var updatedAt: Date
    }

    var chapterKey: String
}

@available(iOS 16.1, *)
actor DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()
    private var trackedChapterKeys: Set<String> = []
    private let displayGraceSeconds: TimeInterval = 90

    func upsert(
        chapterKey: String,
        comicTitle: String,
        chapterTitle: String,
        status: String,
        downloadedPages: Int,
        totalPages: Int
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = ComicDownloadActivityAttributes.ContentState(
            comicTitle: comicTitle,
            chapterTitle: chapterTitle,
            status: status,
            downloadedPages: downloadedPages,
            totalPages: totalPages,
            updatedAt: Date()
        )

        if trackedChapterKeys.contains(chapterKey),
           await Self.updateExisting(chapterKey: chapterKey, state: state) {
            return
        }

        if await Self.updateExisting(chapterKey: chapterKey, state: state) {
            trackedChapterKeys.insert(chapterKey)
            return
        }

        if await Self.requestActivity(chapterKey: chapterKey, state: state) {
            trackedChapterKeys.insert(chapterKey)
        }
    }

    func end(chapterKey: String, finalStatus: String, comicTitle: String, chapterTitle: String, downloadedPages: Int, totalPages: Int) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = ComicDownloadActivityAttributes.ContentState(
            comicTitle: comicTitle,
            chapterTitle: chapterTitle,
            status: finalStatus,
            downloadedPages: downloadedPages,
            totalPages: totalPages,
            updatedAt: Date()
        )

        let dismissalAt = Date().addingTimeInterval(displayGraceSeconds)
        await Self.endExisting(chapterKey: chapterKey, state: state, dismissalAt: dismissalAt)
        trackedChapterKeys.remove(chapterKey)
    }

    private nonisolated static func updateExisting(
        chapterKey: String,
        state: ComicDownloadActivityAttributes.ContentState
    ) async -> Bool {
        guard let activity = Activity<ComicDownloadActivityAttributes>.activities.first(where: { $0.attributes.chapterKey == chapterKey }) else {
            return false
        }
        await activity.update(ActivityContent(state: state, staleDate: nil))
        return true
    }

    private nonisolated static func requestActivity(
        chapterKey: String,
        state: ComicDownloadActivityAttributes.ContentState
    ) async -> Bool {
        let attributes = ComicDownloadActivityAttributes(chapterKey: chapterKey)
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func endExisting(
        chapterKey: String,
        state: ComicDownloadActivityAttributes.ContentState,
        dismissalAt: Date
    ) async {
        guard let activity = Activity<ComicDownloadActivityAttributes>.activities.first(where: { $0.attributes.chapterKey == chapterKey }) else {
            return
        }
        await activity.end(ActivityContent(state: state, staleDate: dismissalAt), dismissalPolicy: .after(dismissalAt))
    }
}

#else

actor DownloadLiveActivityManager {
    static let shared = DownloadLiveActivityManager()

    func upsert(
        chapterKey: String,
        comicTitle: String,
        chapterTitle: String,
        status: String,
        downloadedPages: Int,
        totalPages: Int
    ) async {
    }

    func end(chapterKey: String, finalStatus: String, comicTitle: String, chapterTitle: String, downloadedPages: Int, totalPages: Int) async {
    }
}

#endif
