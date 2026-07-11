import Observation
import SwiftUI

struct ComicPreviewPaginationResult {
    let images: [ComicPreviewImage]
    let nextToken: String?
}

enum ComicPreviewPagination {
    static func nextStartPage(after images: [ComicPreviewImage]) -> Int {
        guard let highestPage = images.lazy.map(\.page).max() else { return 1 }
        guard highestPage < Int.max else { return Int.max }
        return max(1, highestPage + 1)
    }

    static func merge(
        existing: [ComicPreviewImage],
        page: ComicPreviewImagePage,
        requestedToken: String?
    ) -> ComicPreviewPaginationResult {
        var seenPages = Set(existing.lazy.map(\.page))
        var seenIDs = Set(existing.lazy.map(\.id))
        var images = existing
        images.reserveCapacity(existing.count + page.images.count)
        for image in page.images {
            guard !seenPages.contains(image.page), !seenIDs.contains(image.id) else { continue }
            seenPages.insert(image.page)
            seenIDs.insert(image.id)
            images.append(image)
        }

        let requestedToken = normalizedToken(requestedToken)
        var nextToken = normalizedToken(page.nextToken)
        if nextToken == requestedToken, nextToken != nil {
            nextToken = nil
        }
        return ComicPreviewPaginationResult(images: images, nextToken: nextToken)
    }

    private static func normalizedToken(_ token: String?) -> String? {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}

@MainActor
@Observable
final class ComicDetailScreenModel {
    let item: ComicSummary

    var detail: ComicDetail?
    var errorText = ""
    var loading = false
    var bookmarkWorking = false
    var rootFavoriteWorking = false
    var favoriteFolderWorkingIDs: Set<String> = []
    var favoriteStatus = ""
    var favoriteFolders: [FavoriteFolder] = []
    var singleFavoriteFolderSelection = false
    var commentCapabilities = ComicCommentCapabilities(canLoad: false, canSend: false, canLike: false, canVote: false)
    var showCommentsPage = false
    var showQueueAllConfirm = false
    var queueingAll = false
    var queueAllProgressText = ""
    var showFullDescription = false
    var showCommentPreview = false
    var chapterQuery = ""
    var chapterDescending = false
    var previewImages: [ComicPreviewImage] = []
    var previewNextToken: String?
    var previewLoading = false
    var previewUnavailable = false
    var previewErrorText = ""

    init(item: ComicSummary) {
        self.item = item
    }

    var browserURLString: String? {
        guard let raw = detail?.comicURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.hasPrefix("http") == true
        else { return nil }
        return raw
    }

    var effectiveIsFavorited: Bool {
        if !favoriteFolders.isEmpty {
            return favoriteFolders.contains(where: \.isFavorited) || (detail?.isFavorite ?? false)
        }
        return detail?.isFavorite ?? false
    }

    var actionableFavoriteFolders: [FavoriteFolder] {
        favoriteFolders.filter { !Self.isVirtualFavoriteFolderID($0.id) }
    }

    var displayDetail: ComicDetail? {
        guard let detail else { return nil }
        if detail.title.isEmpty {
            return ComicDetail(
                title: item.title,
                cover: detail.cover,
                description: detail.description,
                comicURL: detail.comicURL,
                subID: detail.subID,
                tags: detail.tags,
                isFavorite: detail.isFavorite,
                favoriteId: detail.favoriteId,
                chapters: detail.chapters,
                commentsCount: detail.commentsCount,
                comments: detail.comments,
                previewImages: detail.previewImages,
                previewNextToken: detail.previewNextToken
            )
        }
        return detail
    }

    var isBookmarked: Bool = false

    static func isVirtualFavoriteFolderID(_ id: String) -> Bool {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "-1" || normalized == "all"
    }

    func load(using vm: ReaderViewModel, library: LibraryViewModel) async {
        loading = true
        errorText = ""
        favoriteStatus = ""
        isBookmarked = library.isBookmarked(item)
        do {
            try await library.reloadAll()
            isBookmarked = library.isBookmarked(item)
            await library.refreshDownloadList()
            detail = try await vm.loadComicDetail(item)
            let initialPreview = ComicPreviewPagination.merge(
                existing: [],
                page: ComicPreviewImagePage(
                    images: detail?.previewImages ?? [],
                    nextToken: detail?.previewNextToken
                ),
                requestedToken: nil
            )
            previewImages = initialPreview.images
            previewNextToken = initialPreview.nextToken
            previewUnavailable = false
            previewErrorText = ""
            if previewImages.isEmpty {
                await loadMorePreviewImages(using: vm)
            }
            do {
                commentCapabilities = try await vm.getComicCommentCapabilities(item)
            } catch {
                commentCapabilities = ComicCommentCapabilities(canLoad: false, canSend: false, canLike: false, canVote: false)
            }
            do {
                let favoriteListing = try await vm.loadSourceFavoriteFolders(item)
                favoriteFolders = favoriteListing.folders
                singleFavoriteFolderSelection = favoriteListing.singleFolderForSingleComic
            } catch {
                favoriteFolders = []
                singleFavoriteFolderSelection = false
                favoriteStatus = "Source favorite unavailable offline"
            }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    func loadMorePreviewImages(using vm: ReaderViewModel) async {
        guard !previewLoading, !previewUnavailable else { return }
        if !previewImages.isEmpty, previewNextToken == nil { return }

        previewLoading = true
        defer { previewLoading = false }

        do {
            let requestedToken = previewNextToken
            let page = try await vm.loadComicThumbnailPage(
                item,
                nextToken: requestedToken,
                startPage: ComicPreviewPagination.nextStartPage(after: previewImages)
            )
            let merged = ComicPreviewPagination.merge(
                existing: previewImages,
                page: page,
                requestedToken: requestedToken
            )
            previewImages = merged.images
            previewNextToken = merged.nextToken
            previewUnavailable = previewImages.isEmpty && previewNextToken == nil
            previewErrorText = ""
        } catch {
            if previewImages.isEmpty {
                previewUnavailable = true
            } else {
                previewErrorText = error.localizedDescription
            }
        }
    }

    func startToggleBookmark(using library: LibraryViewModel) {
        guard !bookmarkWorking else { return }
        bookmarkWorking = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.bookmarkWorking = false }
            await library.toggleBookmark(item)
            self.isBookmarked = library.isBookmarked(item)
        }
    }

    func isFavoriteWorking(folderID: String? = nil) -> Bool {
        if let folderID {
            favoriteFolderWorkingIDs.contains(folderID)
        } else {
            rootFavoriteWorking
        }
    }

    func startToggleFavorite(using vm: ReaderViewModel, folderID: String? = nil, isAdding: Bool? = nil) {
        guard let detail else { return }
        guard !isFavoriteWorking(folderID: folderID) else { return }

        if let folderID {
            favoriteFolderWorkingIDs.insert(folderID)
        } else {
            rootFavoriteWorking = true
        }

        let currentDetail = detail
        let targetAdding = isAdding ?? !effectiveIsFavorited

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if let folderID {
                    self.favoriteFolderWorkingIDs.remove(folderID)
                } else {
                    self.rootFavoriteWorking = false
                }
            }

            do {
                let updated = try await vm.toggleSourceFavorite(
                    item,
                    detail: currentDetail,
                    folderID: folderID,
                    isAdding: targetAdding
                )
                self.detail = updated
                let favoriteListing = try await vm.loadSourceFavoriteFolders(item)
                self.favoriteFolders = favoriteListing.folders
                self.singleFavoriteFolderSelection = favoriteListing.singleFolderForSingleComic
                self.favoriteStatus = targetAdding ? "Added to source favorites" : "Removed from source favorites"
            } catch {
                self.favoriteStatus = "Favorite failed: \(error.localizedDescription)"
            }
        }
    }

    func enqueueDownload(using vm: ReaderViewModel, library: LibraryViewModel, chapterID: String, chapterTitle: String) async {
        library.status = "Fetching pages for \(chapterTitle.isEmpty ? chapterID : chapterTitle)..."
        library.status = await vm.enqueueChapterDownload(
            item: item,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            comicDescription: detail?.description
        )
    }

    func queueAllChapters(using vm: ReaderViewModel, library: LibraryViewModel) async {
        guard let detail else { return }
        guard !queueingAll else { return }
        queueingAll = true
        defer {
            queueingAll = false
            queueAllProgressText = ""
        }
        for (idx, chapter) in detail.chapters.enumerated() {
            queueAllProgressText = "\(idx + 1)/\(detail.chapters.count)"
            await enqueueDownload(using: vm, library: library, chapterID: chapter.id, chapterTitle: chapter.title)
        }
    }
}
