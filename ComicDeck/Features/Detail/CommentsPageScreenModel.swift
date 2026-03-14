import Foundation
import Observation

@MainActor
@Observable
final class CommentsPageScreenModel {
    let item: ComicSummary
    let detail: ComicDetail
    let capabilities: ComicCommentCapabilities
    let initialReplyComment: ComicComment?

    var loading = false
    var sending = false
    var loadingMore = false
    var comments: [ComicComment] = []
    var page = 1
    var maxPage: Int?
    var errorText = ""
    var inputText = ""
    var replyTo: ComicComment?
    var repliesTarget: ComicComment?

    init(
        item: ComicSummary,
        detail: ComicDetail,
        capabilities: ComicCommentCapabilities,
        initialReplyComment: ComicComment?
    ) {
        self.item = item
        self.detail = detail
        self.capabilities = capabilities
        self.initialReplyComment = initialReplyComment
    }

    var canLoadMore: Bool {
        guard !loading else { return false }
        if let maxPage { return page < maxPage }
        return !comments.isEmpty
    }

    var sendButtonDisabled: Bool {
        sending || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func reload(using vm: ReaderViewModel, replyComment: ComicComment?) async {
        guard capabilities.canLoad else {
            comments = []
            errorText = "This source does not support comments loader"
            return
        }
        loading = true
        errorText = ""
        page = 1
        maxPage = nil
        do {
            let data = try await vm.loadComicComments(
                item,
                detail: detail,
                page: 1,
                replyTo: replyComment?.actionableCommentID
            )
            comments = data.comments
            maxPage = data.maxPage
        } catch {
            comments = []
            errorText = "Load comments failed: \(error.localizedDescription)"
        }
        loading = false
    }

    func loadMore(using vm: ReaderViewModel) async {
        guard !loadingMore, canLoadMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let nextPage = page + 1
        do {
            let data = try await vm.loadComicComments(
                item,
                detail: detail,
                page: nextPage,
                replyTo: replyTo?.actionableCommentID
            )
            comments.append(contentsOf: data.comments)
            page = nextPage
            if let max = data.maxPage { maxPage = max }
            if data.comments.isEmpty, maxPage == nil {
                maxPage = page
            }
        } catch {
            errorText = "Load more failed: \(error.localizedDescription)"
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
                replyTo: replyTo?.actionableCommentID
            )
            inputText = ""
            await reload(using: vm, replyComment: replyTo)
        } catch {
            errorText = "Send comment failed: \(error.localizedDescription)"
        }
    }
}
