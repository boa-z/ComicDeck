import Foundation

// MARK: - Download Status

public enum DownloadStatus: String, Codable, Sendable, Hashable {
    case pending
    case downloading
    case completed
    case failed
}

// MARK: - Comic Summary

public struct ComicSummary: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let sourceKey: String
    public var title: String
    public var coverURL: String?
    public var author: String?
    public var tags: [String]

    public nonisolated init(
        id: String,
        sourceKey: String,
        title: String,
        coverURL: String? = nil,
        author: String? = nil,
        tags: [String] = []
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.title = title
        self.coverURL = coverURL
        self.author = author
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceKey
        case title
        case coverURL
        case author
        case tags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.sourceKey = try container.decode(String.self, forKey: .sourceKey)
        self.title = try container.decode(String.self, forKey: .title)
        self.coverURL = try container.decodeIfPresent(String.self, forKey: .coverURL)
        self.author = try container.decodeIfPresent(String.self, forKey: .author)
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

// MARK: - Reading History

public struct ReadingHistoryItem: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let comicID: String
    public let sourceKey: String
    public let title: String
    public let coverURL: String?
    public let author: String?
    public let tags: [String]
    public let chapterID: String?
    public let chapter: String?
    public let page: Int
    public let updatedAt: Int64

    public nonisolated init(
        id: Int64,
        comicID: String,
        sourceKey: String,
        title: String,
        coverURL: String? = nil,
        author: String? = nil,
        tags: [String] = [],
        chapterID: String? = nil,
        chapter: String?,
        page: Int,
        updatedAt: Int64
    ) {
        self.id = id
        self.comicID = comicID
        self.sourceKey = sourceKey
        self.title = title
        self.coverURL = coverURL
        self.author = author
        self.tags = tags
        self.chapterID = chapterID
        self.chapter = chapter
        self.page = page
        self.updatedAt = updatedAt
    }
}

// MARK: - Favorite Comic

public struct FavoriteComic: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let sourceKey: String
    public var title: String
    public var coverURL: String?
    public var createdAt: Int64

    public nonisolated init(
        id: String,
        sourceKey: String,
        title: String,
        coverURL: String? = nil,
        createdAt: Int64
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.title = title
        self.coverURL = coverURL
        self.createdAt = createdAt
    }
}

// MARK: - Library Categories

public struct LibraryCategory: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public var name: String
    public var sortOrder: Int
    public var createdAt: Int64

    public nonisolated init(
        id: Int64,
        name: String,
        sortOrder: Int,
        createdAt: Int64
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

// MARK: - Search Options

struct SearchOptionItem: Identifiable, Hashable {
    let id: String
    let value: String
    let label: String
}

struct SearchOptionGroup: Identifiable, Hashable {
    let id: String
    let label: String
    let type: String
    let defaultValue: String?
    let options: [SearchOptionItem]
}

struct SearchFeatureProfile: Hashable {
    let hasKeywordSearch: Bool
    let supportsPagedKeywordSearch: Bool
    let supportsLoadPage: Bool
    let supportsLoadNext: Bool
    let optionGroupCount: Int
    let availableMethods: [String]

    static let empty = SearchFeatureProfile(
        hasKeywordSearch: false,
        supportsPagedKeywordSearch: false,
        supportsLoadPage: false,
        supportsLoadNext: false,
        optionGroupCount: 0,
        availableMethods: []
    )
}

struct ComicPageResult: Hashable {
    let comics: [ComicSummary]
    let maxPage: Int?
    let nextToken: String?
}

enum ExplorePageKind: String, Hashable {
    case multiPageComicList
    case singlePageWithMultiPart
    case mixed
}

struct ExplorePageItem: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: ExplorePageKind
}

struct ExplorePartData: Identifiable, Hashable {
    let id: String
    let title: String
    let comics: [ComicSummary]
    let viewMore: CategoryJumpTarget?
}

enum ExploreMixedBlock: Hashable, Identifiable {
    case comics(id: String, items: [ComicSummary])
    case part(ExplorePartData)

    var id: String {
        switch self {
        case let .comics(id, _): return "comics:\(id)"
        case let .part(part): return "part:\(part.id)"
        }
    }
}

struct ExploreMixedPageResult: Hashable {
    let blocks: [ExploreMixedBlock]
    let maxPage: Int?
}

struct CategoryJumpTarget: Hashable {
    let page: String
    let keyword: String?
    let category: String?
    let param: String?
}

struct CategoryItemData: Identifiable, Hashable {
    let id: String
    let label: String
    let target: CategoryJumpTarget
}

struct CategoryPartData: Identifiable, Hashable {
    let id: String
    let title: String
    let type: String
    let randomNumber: Int?
    let items: [CategoryItemData]
}

struct CategoryPageProfile: Hashable {
    let title: String
    let key: String
    let enableRankingPage: Bool
    let parts: [CategoryPartData]

    static let empty = CategoryPageProfile(
        title: "",
        key: "",
        enableRankingPage: false,
        parts: []
    )
}

struct CategoryComicsOptionItem: Identifiable, Hashable {
    let id: String
    let value: String
    let label: String
}

struct CategoryComicsOptionGroup: Identifiable, Hashable {
    let id: String
    let label: String
    let options: [CategoryComicsOptionItem]
    let notShowWhen: [String]
    let showWhen: [String]?
}

struct CategoryComicsPage: Hashable {
    let comics: [ComicSummary]
    let maxPage: Int?
    let nextToken: String?
}

struct CategoryRankingProfile: Hashable {
    let options: [CategoryComicsOptionItem]
    let supportsLoadPage: Bool
    let supportsLoadNext: Bool

    static let empty = CategoryRankingProfile(
        options: [],
        supportsLoadPage: false,
        supportsLoadNext: false
    )
}

// MARK: - Login

struct LoginProfile: Hashable {
    let hasAccountLogin: Bool
    let hasWebLogin: Bool
    let hasCookieLogin: Bool
    let webLoginURL: String?
    let registerWebsite: String?
    let cookieFields: [String]
}

// MARK: - Comic Content

struct ComicChapter: Identifiable, Hashable {
    let id: String
    let title: String
}

struct ComicComment: Identifiable, Hashable {
    let id: String
    let userName: String
    let content: String
    let timeText: String?
    let avatar: String?
    let score: Int?
    let isLiked: Bool?
    let voteStatus: Int?
    let replyCount: Int?

    var likes: Int? { score }
    var actionableCommentID: String? { id.isEmpty ? nil : id }
}

struct FavoriteFolder: Identifiable, Hashable {
    let id: String
    let title: String
    let isFavorited: Bool
}

struct FavoriteFolderListing: Hashable {
    let folders: [FavoriteFolder]
    let singleFolderForSingleComic: Bool
}

struct TagGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let values: [String]
}

struct ComicDetail: Hashable {
    let title: String
    let cover: String?
    let description: String?
    let comicURL: String?
    let subID: String?
    let tags: [TagGroup]
    let isFavorite: Bool?
    let favoriteId: String?
    let chapters: [ComicChapter]
    let commentsCount: Int?
    let comments: [ComicComment]
}

struct ComicCommentsPage: Hashable {
    let comments: [ComicComment]
    let maxPage: Int?
}

struct ComicCommentCapabilities: Hashable {
    let canLoad: Bool
    let canSend: Bool
    let canLike: Bool
    let canVote: Bool
}

struct ImageRequest: Hashable, Sendable {
    let url: String
    let method: String
    let headers: [String: String]
    let body: [UInt8]?
}

// MARK: - Downloads

public struct DownloadChapterItem: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let sourceKey: String
    public let comicID: String
    public let comicTitle: String
    public let coverURL: String?
    public let comicDescription: String?
    public let chapterID: String
    public let chapterTitle: String
    public let status: DownloadStatus
    public let totalPages: Int
    public let downloadedPages: Int
    public let directoryPath: String
    public let errorMessage: String?
    public let createdAt: Int64
    public let updatedAt: Int64

    public nonisolated init(
        id: Int64,
        sourceKey: String,
        comicID: String,
        comicTitle: String,
        coverURL: String?,
        comicDescription: String?,
        chapterID: String,
        chapterTitle: String,
        status: DownloadStatus,
        totalPages: Int,
        downloadedPages: Int,
        directoryPath: String,
        errorMessage: String?,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.comicID = comicID
        self.comicTitle = comicTitle
        self.coverURL = coverURL
        self.comicDescription = comicDescription
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.status = status
        self.totalPages = totalPages
        self.downloadedPages = downloadedPages
        self.directoryPath = directoryPath
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var progressText: String {
        "\(downloadedPages)/\(max(totalPages, downloadedPages))"
    }
}

public struct DownloadedFileItem: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let sizeBytes: Int64
    public let modifiedAt: Date
}

public enum OfflineChapterIntegrityStatus: String, Codable, Sendable, Hashable {
    case complete
    case incomplete

    public var title: String {
        switch self {
        case .complete:
            return "Complete"
        case .incomplete:
            return "Incomplete"
        }
    }
}

public struct OfflineChapterAsset: Codable, Sendable, Identifiable, Hashable {
    public let id: Int64
    public let sourceKey: String
    public let comicID: String
    public let comicTitle: String
    public let coverURL: String?
    public let comicDescription: String?
    public let chapterID: String
    public let chapterTitle: String
    public let pageCount: Int
    public let verifiedPageCount: Int
    public let integrityStatus: OfflineChapterIntegrityStatus
    public let directoryPath: String
    public let downloadedAt: Int64
    public let lastVerifiedAt: Int64
    public let updatedAt: Int64

    public nonisolated init(
        id: Int64,
        sourceKey: String,
        comicID: String,
        comicTitle: String,
        coverURL: String?,
        comicDescription: String?,
        chapterID: String,
        chapterTitle: String,
        pageCount: Int,
        verifiedPageCount: Int,
        integrityStatus: OfflineChapterIntegrityStatus,
        directoryPath: String,
        downloadedAt: Int64,
        lastVerifiedAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.comicID = comicID
        self.comicTitle = comicTitle
        self.coverURL = coverURL
        self.comicDescription = comicDescription
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.pageCount = pageCount
        self.verifiedPageCount = verifiedPageCount
        self.integrityStatus = integrityStatus
        self.directoryPath = directoryPath
        self.downloadedAt = downloadedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.updatedAt = updatedAt
    }
}
