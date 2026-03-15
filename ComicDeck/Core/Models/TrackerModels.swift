import Foundation

public enum TrackerProvider: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case aniList = "anilist"
    case bangumi = "bangumi"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .aniList:
            return "AniList"
        case .bangumi:
            return "Bangumi"
        }
    }
}

public enum TrackerReadingStatus: String, Codable, Sendable, Hashable, CaseIterable {
    case current
    case completed
    case paused
    case planning
    case dropped

    var title: String {
        switch self {
        case .current: return "Current"
        case .completed: return "Completed"
        case .paused: return "Paused"
        case .planning: return "Planning"
        case .dropped: return "Dropped"
        }
    }
}

public enum TrackerSyncEventState: String, Codable, Sendable, Hashable {
    case pending
    case failed
}

public struct TrackerAccount: Codable, Sendable, Identifiable, Hashable {
    public var id: TrackerProvider { provider }
    public let provider: TrackerProvider
    public let displayName: String
    public let remoteUserID: String
    public let updatedAt: Int64

    public nonisolated init(provider: TrackerProvider, displayName: String, remoteUserID: String, updatedAt: Int64) {
        self.provider = provider
        self.displayName = displayName
        self.remoteUserID = remoteUserID
        self.updatedAt = updatedAt
    }
}

public struct TrackerBinding: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let provider: TrackerProvider
    public let sourceKey: String
    public let comicID: String
    public let remoteMediaID: String
    public let remoteTitle: String
    public let remoteCoverURL: String?
    public let lastSyncedProgress: Int
    public let lastSyncedStatus: TrackerReadingStatus?
    public let updatedAt: Int64

    public nonisolated init(
        id: Int64,
        provider: TrackerProvider,
        sourceKey: String,
        comicID: String,
        remoteMediaID: String,
        remoteTitle: String,
        remoteCoverURL: String?,
        lastSyncedProgress: Int,
        lastSyncedStatus: TrackerReadingStatus?,
        updatedAt: Int64
    ) {
        self.id = id
        self.provider = provider
        self.sourceKey = sourceKey
        self.comicID = comicID
        self.remoteMediaID = remoteMediaID
        self.remoteTitle = remoteTitle
        self.remoteCoverURL = remoteCoverURL
        self.lastSyncedProgress = lastSyncedProgress
        self.lastSyncedStatus = lastSyncedStatus
        self.updatedAt = updatedAt
    }
}

public struct TrackerSyncEvent: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let provider: TrackerProvider
    public let sourceKey: String
    public let comicID: String
    public let remoteMediaID: String
    public let targetProgress: Int
    public let targetStatus: TrackerReadingStatus?
    public let state: TrackerSyncEventState
    public let retryCount: Int
    public let lastError: String?
    public let createdAt: Int64
    public let updatedAt: Int64

    public nonisolated init(
        id: Int64,
        provider: TrackerProvider,
        sourceKey: String,
        comicID: String,
        remoteMediaID: String,
        targetProgress: Int,
        targetStatus: TrackerReadingStatus?,
        state: TrackerSyncEventState,
        retryCount: Int,
        lastError: String?,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.provider = provider
        self.sourceKey = sourceKey
        self.comicID = comicID
        self.remoteMediaID = remoteMediaID
        self.targetProgress = targetProgress
        self.targetStatus = targetStatus
        self.state = state
        self.retryCount = retryCount
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct TrackerSearchResult: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let coverURL: String?
    public let statusText: String?
    public let chapterCount: Int?
    public let siteURL: String?

    public nonisolated init(
        id: String,
        title: String,
        subtitle: String?,
        coverURL: String?,
        statusText: String?,
        chapterCount: Int?,
        siteURL: String?
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coverURL = coverURL
        self.statusText = statusText
        self.chapterCount = chapterCount
        self.siteURL = siteURL
    }
}
