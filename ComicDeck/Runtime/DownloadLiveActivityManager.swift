import Foundation

#if canImport(ActivityKit)
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
    private var activitiesByKey: [String: Activity<ComicDownloadActivityAttributes>] = [:]
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

        if let activity = activitiesByKey[chapterKey] {
            await activity.update(ActivityContent(state: state, staleDate: nil))
            return
        }

        if let existing = Activity<ComicDownloadActivityAttributes>.activities.first(where: { $0.attributes.chapterKey == chapterKey }) {
            activitiesByKey[chapterKey] = existing
            await existing.update(ActivityContent(state: state, staleDate: nil))
            return
        }

        let attributes = ComicDownloadActivityAttributes(chapterKey: chapterKey)
        do {
            let created = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            activitiesByKey[chapterKey] = created
        } catch {
            return
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

        let target: Activity<ComicDownloadActivityAttributes>
        if let existing = activitiesByKey[chapterKey] {
            target = existing
        } else if let existing = Activity<ComicDownloadActivityAttributes>.activities.first(where: { $0.attributes.chapterKey == chapterKey }) {
            target = existing
        } else {
            return
        }

        let dismissalAt = Date().addingTimeInterval(displayGraceSeconds)
        await target.end(ActivityContent(state: state, staleDate: dismissalAt), dismissalPolicy: .after(dismissalAt))
        activitiesByKey.removeValue(forKey: chapterKey)
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
