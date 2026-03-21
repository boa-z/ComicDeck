import Foundation
import Observation

@MainActor
@Observable
final class CommentsPageScreenModel {
    let item: ComicSummary
    let detail: ComicDetail
    let capabilities: ComicCommentCapabilities
    let initialReplyComment: ComicComment?

    var isInitialLoading = false
    var isRefreshing = false
    var isShowingSeededComments = false
    var loadingStatusText = ""
    var sending = false
    var loadingMore = false
    var comments: [ComicComment]
    var page = 1
    var maxPage: Int?
    var errorText = ""
    var inputText = ""
    var replyTo: ComicComment?
    var repliesTarget: ComicComment?

    @ObservationIgnored
    private var loadingStatusTask: Task<Void, Never>?

    init(
        item: ComicSummary,
        detail: ComicDetail,
        capabilities: ComicCommentCapabilities,
        initialReplyComment: ComicComment?,
        seededComments: [ComicComment] = []
    ) {
        self.item = item
        self.detail = detail
        self.capabilities = capabilities
        self.initialReplyComment = initialReplyComment
        comments = seededComments
        isShowingSeededComments = initialReplyComment == nil && !seededComments.isEmpty
    }

    deinit {
        loadingStatusTask?.cancel()
    }

    var isLoadingCommentsPage: Bool {
        isInitialLoading || isRefreshing
    }

    var canLoadMore: Bool {
        guard capabilities.canLoad, !isLoadingCommentsPage, !isShowingSeededComments else { return false }
        if let maxPage { return page < maxPage }
        return !comments.isEmpty
    }

    var sendButtonDisabled: Bool {
        sending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reload(using vm: ReaderViewModel, replyComment: ComicComment?) async {
        guard !isLoadingCommentsPage, !loadingMore else { return }
        guard capabilities.canLoad else {
            stopLoadingStatus()
            isInitialLoading = false
            isRefreshing = false
            page = 1
            maxPage = nil
            errorText = AppLocalization.text(
                "comments.error.unsupported",
                "This source does not support loading comments."
            )
            return
        }

        let hasVisibleComments = !comments.isEmpty
        errorText = ""
        isInitialLoading = !hasVisibleComments
        isRefreshing = hasVisibleComments
        startLoadingStatus(replyComment: replyComment, hasVisibleComments: hasVisibleComments)

        do {
            let data = try await vm.loadComicComments(
                item,
                detail: detail,
                page: 1,
                replyTo: replyComment?.actionableCommentID
            )
            comments = data.comments
            page = 1
            maxPage = data.maxPage
            isShowingSeededComments = false
        } catch {
            if hasVisibleComments {
                let errorKey = isShowingSeededComments ? "comments.error.latest" : "comments.error.refresh"
                let defaultValue = isShowingSeededComments
                    ? "Loading latest comments failed: %@"
                    : "Refreshing comments failed: %@"
                errorText = AppLocalization.format(errorKey, defaultValue, error.localizedDescription)
            } else {
                comments = []
                isShowingSeededComments = false
                errorText = AppLocalization.format(
                    "comments.error.load",
                    "Loading comments failed: %@",
                    error.localizedDescription
                )
            }
        }

        isInitialLoading = false
        isRefreshing = false
        stopLoadingStatus()
    }

    func loadMore(using vm: ReaderViewModel) async {
        guard !loadingMore, canLoadMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        errorText = ""

        let nextPage = page + 1
        do {
            let data = try await vm.loadComicComments(
                item,
                detail: detail,
                page: nextPage,
                replyTo: initialReplyComment?.actionableCommentID
            )
            comments.append(contentsOf: data.comments)
            page = nextPage
            if let max = data.maxPage { maxPage = max }
            if data.comments.isEmpty, maxPage == nil {
                maxPage = page
            }
        } catch {
            errorText = AppLocalization.format(
                "comments.error.load_more",
                "Loading more comments failed: %@",
                error.localizedDescription
            )
        }
    }

    func sendComment(using vm: ReaderViewModel) async {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        sending = true
        defer { sending = false }

        do {
            try await vm.sendComicComment(
                item,
                detail: detail,
                content: content,
                replyTo: replyTo?.actionableCommentID ?? initialReplyComment?.actionableCommentID
            )
            inputText = ""
            await reload(using: vm, replyComment: initialReplyComment)
        } catch {
            errorText = AppLocalization.format(
                "comments.error.send",
                "Sending comment failed: %@",
                error.localizedDescription
            )
        }
    }

    private func startLoadingStatus(replyComment: ComicComment?, hasVisibleComments: Bool) {
        let initialText: String
        if replyComment != nil && !hasVisibleComments {
            initialText = AppLocalization.text("comments.loading.replies", "Loading replies…")
        } else if isShowingSeededComments {
            initialText = AppLocalization.text("comments.loading.latest", "Loading latest comments…")
        } else if hasVisibleComments {
            initialText = AppLocalization.text("comments.loading.refresh", "Refreshing comments…")
        } else {
            initialText = AppLocalization.text("comments.loading.initial", "Loading comments…")
        }

        let slowText = AppLocalization.text("comments.loading.slow", "Still working with source…")
        loadingStatusText = initialText
        loadingStatusTask?.cancel()
        loadingStatusTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch {
                return
            }
            await self?.applyDelayedLoadingStatus(slowText)
        }
    }

    private func applyDelayedLoadingStatus(_ text: String) {
        guard isLoadingCommentsPage else { return }
        loadingStatusText = text
    }

    private func stopLoadingStatus() {
        loadingStatusTask?.cancel()
        loadingStatusTask = nil
        loadingStatusText = ""
    }
}
