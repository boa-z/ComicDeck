import SwiftUI

@MainActor
struct CommentsPageView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var vm: ReaderViewModel
    let item: ComicSummary
    let detail: ComicDetail
    let capabilities: ComicCommentCapabilities
    let initialReplyComment: ComicComment?
    @State private var model: CommentsPageScreenModel

    init(
        vm: ReaderViewModel,
        item: ComicSummary,
        detail: ComicDetail,
        capabilities: ComicCommentCapabilities,
        initialReplyComment: ComicComment?,
        seededComments: [ComicComment] = []
    ) {
        self.vm = vm
        self.item = item
        self.detail = detail
        self.capabilities = capabilities
        self.initialReplyComment = initialReplyComment
        _model = State(
            initialValue: CommentsPageScreenModel(
                item: item,
                detail: detail,
                capabilities: capabilities,
                initialReplyComment: initialReplyComment,
                seededComments: initialReplyComment == nil ? seededComments : []
            )
        )
    }

    var body: some View {
        let repliesTargetBinding = Binding(
            get: { model.repliesTarget },
            set: { model.repliesTarget = $0 }
        )

        List {
            if model.isLoadingCommentsPage {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.linear)
                        Text(model.loadingStatusText)
                            .font(.subheadline.weight(.semibold))
                        if model.isShowingSeededComments {
                            Text(AppLocalization.text(
                                "comments.loading.preview_note",
                                "Showing preview comments while latest comments load."
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            if !model.errorText.isEmpty {
                Section {
                    Text(model.errorText)
                        .foregroundStyle(.red)
                    Button(AppLocalization.text("common.retry", "Retry")) {
                        Task { await model.reload(using: vm, replyComment: initialReplyComment) }
                    }
                }
            }

            if let replyTo = model.replyTo {
                Section(AppLocalization.text("comments.reply_to", "Reply To")) {
                    CommentPreviewRow(comment: replyTo)
                    Button(AppLocalization.text("comments.cancel_reply", "Cancel Reply"), role: .destructive) {
                        model.replyTo = nil
                    }
                }
            }

            if model.comments.isEmpty {
                if !model.isLoadingCommentsPage {
                    Section {
                        Text(AppLocalization.text("comments.empty", "No comments"))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section(AppLocalization.text("comments.section.title", "Comments")) {
                    ForEach(model.comments.indices, id: \.self) { index in
                        let comment = model.comments[index]
                        CommentItemRow(
                            vm: vm,
                            item: item,
                            detail: detail,
                            capabilities: capabilities,
                            comment: comment,
                            onReply: { target in
                                model.replyTo = target
                            },
                            onOpenReplies: { target in
                                model.repliesTarget = target
                            }
                        )
                    }
                    if model.canLoadMore {
                        Button {
                            Task { await model.loadMore(using: vm) }
                        } label: {
                            HStack {
                                if model.loadingMore {
                                    ProgressView().controlSize(.small)
                                }
                                Text(
                                    model.loadingMore
                                        ? AppLocalization.text("comments.loading.more", "Loading…")
                                        : AppLocalization.text("comments.action.load_more", "Load More")
                                )
                            }
                        }
                        .disabled(model.loadingMore)
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.text("comments.navigation.title", "Comments"))
        .toolbar {
            ToolbarItem(placement: .platformTopBarLeading) {
                Button(AppLocalization.text("common.close", "Close")) { dismiss() }
            }
            if initialReplyComment != nil {
                ToolbarItem(placement: .principal) {
                    Text(AppLocalization.text("comments.replies.title", "Replies"))
                        .font(.headline)
                }
            }
            ToolbarItem(placement: .platformTopBarTrailing) {
                Button {
                    Task { await model.reload(using: vm, replyComment: initialReplyComment) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoadingCommentsPage || model.loadingMore)
                .accessibilityLabel(AppLocalization.text("comments.action.refresh", "Refresh comments"))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if capabilities.canSend {
                HStack(spacing: 8) {
                    TextField(
                        model.replyTo == nil
                            ? AppLocalization.text("comments.write_placeholder", "Write a comment")
                            : AppLocalization.text("comments.reply_placeholder", "Reply..."),
                        text: Binding(
                            get: { model.inputText },
                            set: { model.inputText = $0 }
                        ),
                        axis: .vertical
                    )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button {
                        Task { await model.sendComment(using: vm) }
                    } label: {
                        if model.sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                        }
                    }
                    .disabled(model.sendButtonDisabled)
                    .accessibilityLabel(AppLocalization.text("comments.action.send", "Send comment"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            }
        }
        .task {
            await model.reload(using: vm, replyComment: initialReplyComment)
        }
        .sheet(item: repliesTargetBinding) { target in
            NavigationStack {
                CommentsPageView(
                    vm: vm,
                    item: item,
                    detail: detail,
                    capabilities: capabilities,
                    initialReplyComment: target
                )
            }
        }
    }
}

@MainActor
struct CommentItemRow: View {
    @Bindable var vm: ReaderViewModel
    let item: ComicSummary
    let detail: ComicDetail
    let capabilities: ComicCommentCapabilities
    let comment: ComicComment
    let onReply: (ComicComment) -> Void
    let onOpenReplies: (ComicComment) -> Void

    @State private var score: Int?
    @State private var voteStatus: Int?
    @State private var isLiked: Bool?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if let avatar = comment.avatar {
                    CachedRemoteImage(
                        urlString: avatar,
                        decodeSize: CGSize(width: 28, height: 28),
                        contentMode: .fill,
                        failureSystemImage: "person.crop.circle",
                        priority: .thumbnail
                    )
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(comment.userName)
                        .font(.subheadline.weight(.semibold))
                    if let time = comment.timeText, !time.isEmpty {
                        Text(time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            RichTextContent(text: comment.content)
                .font(.subheadline)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                if capabilities.canVote, comment.actionableCommentID != nil {
                    Button {
                        Task { await vote(isUp: true) }
                    } label: {
                        Label(AppLocalization.text("comments.action.vote_up", "Upvote"), systemImage: "arrow.up")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(working)
                    .tint(voteStatus == 1 ? .red : .primary)

                    Text("\(score ?? comment.score ?? 0)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await vote(isUp: false) }
                    } label: {
                        Label(AppLocalization.text("comments.action.vote_down", "Downvote"), systemImage: "arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(working)
                    .tint(voteStatus == -1 ? .blue : .primary)
                } else if let score = score ?? comment.score {
                    Text("♥ \(score)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if capabilities.canLike, comment.actionableCommentID != nil {
                    Button {
                        Task { await like() }
                    } label: {
                        Label(
                            isLiked == true
                                ? AppLocalization.text("comments.liked", "Liked")
                                : AppLocalization.text("comments.like", "Like"),
                            systemImage: isLiked == true ? "heart.fill" : "heart"
                        )
                        .font(.caption)
                    }
                    .disabled(working)
                }

                if comment.actionableCommentID != nil {
                    Button(AppLocalization.text("comments.reply", "Reply")) {
                        onReply(comment)
                    }
                    .font(.caption)
                }
                if let replyCount = comment.replyCount, replyCount > 0, comment.actionableCommentID != nil {
                    Button(AppLocalization.format("comments.replies", "Replies %lld", Int64(replyCount))) {
                        onOpenReplies(comment)
                    }
                    .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .task {
            score = comment.score
            voteStatus = comment.voteStatus
            isLiked = comment.isLiked
        }
        .padding(.vertical, 4)
    }

    private func like() async {
        guard let commentID = comment.actionableCommentID else { return }
        working = true
        defer { working = false }
        let target = !(isLiked ?? false)
        do {
            let updated = try await vm.likeComicComment(
                item,
                detail: detail,
                commentID: commentID,
                isLiking: target
            )
            isLiked = target
            if let updated {
                score = updated
            } else {
                score = (score ?? comment.score ?? 0) + (target ? 1 : -1)
            }
        } catch {}
    }

    private func vote(isUp: Bool) async {
        guard let commentID = comment.actionableCommentID else { return }
        working = true
        defer { working = false }
        let current = voteStatus ?? 0
        let isCancel = (isUp && current == 1) || (!isUp && current == -1)
        do {
            let updated = try await vm.voteComicComment(
                item,
                detail: detail,
                commentID: commentID,
                isUp: isUp,
                isCancel: isCancel
            )
            if isCancel {
                voteStatus = 0
            } else {
                voteStatus = isUp ? 1 : -1
            }
            if let updated { score = updated }
        } catch {}
    }
}
