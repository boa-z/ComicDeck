import Observation
import SwiftUI

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
    var commentCapabilities = ComicCommentCapabilities(canLoad: false, canSend: false, canLike: false, canVote: false)
    var showCommentsPage = false
    var showQueueAllConfirm = false
    var queueingAll = false
    var queueAllProgressText = ""
    var showFullDescription = false
    var showCommentPreview = false
    var chapterQuery = ""
    var chapterDescending = false

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
                comments: detail.comments
            )
        }
        return detail
    }

    var isBookmarked: Bool = false

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
            do {
                commentCapabilities = try await vm.getComicCommentCapabilities(item)
            } catch {
                commentCapabilities = ComicCommentCapabilities(canLoad: false, canSend: false, canLike: false, canVote: false)
            }
            do {
                favoriteFolders = try await vm.loadSourceFavoriteFolders(item)
            } catch {
                favoriteFolders = []
                favoriteStatus = "Source favorite unavailable offline"
            }
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
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
                self.favoriteFolders = try await vm.loadSourceFavoriteFolders(item)
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
