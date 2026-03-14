import SwiftUI

@MainActor
struct ComicDetailView: View {
    private enum DetailAnchor: String {
        case tags
        case chapters
        case comments
    }

    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    let item: ComicSummary
    var onTagSelected: ((String, String) -> Void)? = nil
    var initialReadRoute: ReaderLaunchContext? = nil
    var onConsumeInitialReadRoute: (() -> Void)? = nil

    @State private var model: ComicDetailScreenModel
    @State private var readRoute: ReaderLaunchContext?
    @State private var tagRoute: CategoryNavigationTarget?
    @State private var didConsumeInitialReadRoute = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(
        vm: ReaderViewModel,
        item: ComicSummary,
        onTagSelected: ((String, String) -> Void)? = nil,
        initialReadRoute: ReaderLaunchContext? = nil,
        onConsumeInitialReadRoute: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.item = item
        self.onTagSelected = onTagSelected
        self.initialReadRoute = initialReadRoute
        self.onConsumeInitialReadRoute = onConsumeInitialReadRoute
        _model = State(initialValue: ComicDetailScreenModel(item: item))
    }

    private var sourceDisplayName: String {
        vm.sourceManager.installedSources.first(where: { $0.key == item.sourceKey })?.name ?? item.sourceKey
    }
    
    private func dedupedPreviewComments(_ comments: [ComicComment], maxCount: Int = 5) -> [ComicComment] {
        func normalize(_ text: String) -> String {
            let noTags = text.replacingOccurrences(
                of: "<[^>]+>",
                with: " ",
                options: .regularExpression
            )
            let collapsed = noTags.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            )
            return collapsed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var seen = Set<String>()
        var output: [ComicComment] = []
        output.reserveCapacity(min(maxCount, comments.count))
        for comment in comments {
            let normalizedContent = normalize(comment.content)
            guard !normalizedContent.isEmpty else { continue }
            let key = [
                normalize(comment.userName),
                normalize(comment.timeText ?? ""),
                normalizedContent
            ].joined(separator: "|")
            if seen.insert(key).inserted {
                output.append(comment)
                if output.count >= maxCount { break }
            }
        }
        return output
    }

    var body: some View {
        let showCommentsBinding = Binding(
            get: { model.showCommentsPage },
            set: { model.showCommentsPage = $0 }
        )
        let showQueueConfirmBinding = Binding(
            get: { model.showQueueAllConfirm },
            set: { model.showQueueAllConfirm = $0 }
        )

        content
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarMenu
                }
            }
            .task {
                await model.load(using: vm, library: library)
            }
            .onChange(of: model.detail != nil) { _, isReady in
                guard isReady else { return }
                maybeOpenInitialReadRoute()
            }
            .refreshable {
                await model.load(using: vm, library: library)
            }
            .sheet(isPresented: showCommentsBinding) {
                if let detail = model.detail {
                    NavigationStack {
                        CommentsPageView(
                            vm: vm,
                            item: item,
                            detail: detail,
                            capabilities: model.commentCapabilities,
                            initialReplyComment: nil
                        )
                    }
                }
            }
            .navigationDestination(item: $readRoute) { route in
                ComicReaderView(
                    vm: vm,
                    item: route.item,
                    chapterID: route.chapterID,
                    chapterTitle: route.chapterTitle,
                    localChapterDirectory: route.localDirectory,
                    initialPage: route.initialPage,
                    chapterSequence: route.chapterSequence
                )
            }
            .navigationDestination(item: $tagRoute) { target in
                switch target {
                case let .category(sourceKey, item):
                    CategoryComicsPageView(vm: vm, sourceKey: sourceKey, item: item)
                case let .ranking(sourceKey):
                    CategoryRankingPageView(vm: vm, sourceKey: sourceKey, initialProfile: .empty)
                case let .search(sourceKey, keyword):
                    SourceScopedSearchView(vm: vm, sourceKey: sourceKey, initialKeyword: keyword)
                }
            }
            .confirmationDialog(
                "Queue download for all chapters?",
                isPresented: showQueueConfirmBinding,
                titleVisibility: .visible
            ) {
                Button("Queue All", role: .destructive) {
                    if model.detail != nil {
                        Task { await model.queueAllChapters(using: vm, library: library) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let detail = model.detail {
                    Text("This will queue \(detail.chapters.count) chapters.")
                }
            }
    }

    private func maybeOpenInitialReadRoute() {
        guard !didConsumeInitialReadRoute,
              model.detail != nil,
              let initialReadRoute else { return }
        didConsumeInitialReadRoute = true
        onConsumeInitialReadRoute?()
        readRoute = initialReadRoute
    }

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppSpacing.section) {
                    if let detail = model.detail {
                        detailSections(detail, proxy: proxy)
                    } else if model.loading {
                        loadingCard
                    } else if !model.errorText.isEmpty {
                        errorCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppSpacing.screen)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.xl)
            }
            .background(
                LinearGradient(
                    colors: [AppSurface.background, AppSurface.grouped],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
    }

    private var loadingCard: some View {
        ComicDetailSectionCard(title: "Loading", subtitle: "Fetching detail, comments, and favorite state") {
            ProgressView("Loading comic details...")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var errorCard: some View {
        ComicDetailSectionCard(title: "Load Failed", subtitle: "The source returned an error") {
            Text(model.errorText)
                .foregroundStyle(AppTint.danger)
            Button("Retry") {
                Task { await model.load(using: vm, library: library) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var toolbarMenu: some View {
        Menu {
            Button("Copy Title") {
                let title = (model.detail?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? (model.detail?.title ?? item.title)
                    : item.title
                copyText(title)
            }
            Button("Copy ID") {
                copyText(item.id)
            }
            if let url = model.browserURLString {
                Button("Copy URL") {
                    copyText(url)
                }
                Button("Open In Browser") {
                    if let target = URL(string: url) {
                        openURL(target)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    @ViewBuilder
    private func detailSections(_ detail: ComicDetail, proxy: ScrollViewProxy) -> some View {
        let displayDetail = model.displayDetail ?? detail
        ComicDetailHeroSection(
            item: item,
            detail: displayDetail,
            sourceName: sourceDisplayName,
            chapterCount: displayDetail.chapters.count,
            commentCount: displayDetail.commentsCount ?? displayDetail.comments.count,
            browserURLString: model.browserURLString,
            showContinue: continueTarget(from: detail) != nil,
            isBookmarked: model.isBookmarked,
            bookmarkWorking: model.bookmarkWorking,
            queueingAll: model.queueingAll,
            queueAllProgressText: model.queueAllProgressText,
            canShowComments: model.commentCapabilities.canLoad,
            hasChapters: !detail.chapters.isEmpty,
            onTapChapters: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(DetailAnchor.chapters, anchor: .top)
                }
            },
            onTapComments: {
                model.showCommentsPage = true
            },
            onTapTags: detail.tags.isEmpty ? nil : {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(DetailAnchor.tags, anchor: .top)
                }
            },
            onContinue: {
                guard let target = continueTarget(from: detail) else { return }
                readRoute = ReaderLaunchContext(
                    item: item,
                    chapterID: target.chapterID,
                    chapterTitle: target.chapterTitle,
                    localDirectory: target.localDirectory,
                    initialPage: max(1, target.page),
                    chapterSequence: detail.chapters
                )
            },
            onStart: {
                let first = firstChapter(from: detail)
                readRoute = ReaderLaunchContext.fromChapter(
                    item: item,
                    chapterID: first.id,
                    chapterTitle: first.title,
                    chapterSequence: detail.chapters,
                    using: library
                )
            },
            onToggleBookmark: {
                model.startToggleBookmark(using: library)
            },
            onOpenComments: {
                model.showCommentsPage = true
            },
            onQueueAll: {
                model.showQueueAllConfirm = true
            },
            onDownloadSingle: {
                let target = readTarget(from: detail)
                Task {
                    await model.enqueueDownload(
                        using: vm,
                        library: library,
                        chapterID: target.chapterID,
                        chapterTitle: target.chapterTitle
                    )
                }
            },
            showFullDescription: Binding(
                get: { model.showFullDescription },
                set: { model.showFullDescription = $0 }
            )
        )
        .id("hero")

        ComicDetailTagsSection(groups: detail.tags) { namespace, tag in
            Task { await onTagTap(namespace: namespace, tag: tag) }
        }
        .id(DetailAnchor.tags)
        ComicDetailFavoriteSection(
            effectiveIsFavorited: model.effectiveIsFavorited,
            favoriteFolders: model.favoriteFolders,
            isRootFavoriteWorking: model.rootFavoriteWorking,
            favoriteStatus: model.favoriteStatus,
            onToggleFavorite: {
                model.startToggleFavorite(using: vm, isAdding: !model.effectiveIsFavorited)
            },
            onToggleFolderFavorite: { folder in
                model.startToggleFavorite(using: vm, folderID: folder.id, isAdding: !folder.isFavorited)
            },
            isFolderFavoriteWorking: { folderID in
                model.isFavoriteWorking(folderID: folderID)
            }
        )
        if model.commentCapabilities.canLoad || !detail.comments.isEmpty || (detail.commentsCount ?? 0) > 0 {
            ComicDetailCommentsSection(
                title: "Comments (\(detail.commentsCount ?? detail.comments.count))",
                canLoad: model.commentCapabilities.canLoad,
                previewComments: model.showCommentPreview ? dedupedPreviewComments(detail.comments) : [],
                isPreviewExpanded: model.showCommentPreview,
                previewNote: previewNote(for: detail),
                onTogglePreview: { model.showCommentPreview.toggle() },
                onOpenComments: { model.showCommentsPage = true }
            )
            .id(DetailAnchor.comments)
        }
        ComicDetailChaptersSection(
            chapters: displayedChapters(from: detail),
            chapterQuery: Binding(
                get: { model.chapterQuery },
                set: { model.chapterQuery = $0 }
            ),
            chapterDescending: Binding(
                get: { model.chapterDescending },
                set: { model.chapterDescending = $0 }
            ),
            continueChapterID: continueTarget(from: detail)?.chapterID,
            downloadStateByChapterID: downloadStateByChapterID(for: detail),
            onReadSingleChapter: {
                readRoute = ReaderLaunchContext.fromChapter(
                    item: item,
                    chapterID: "1",
                    chapterTitle: "Chapter 1",
                    chapterSequence: detail.chapters,
                    using: library
                )
            },
            onDownloadSingleChapter: {
                Task {
                    await model.enqueueDownload(
                        using: vm,
                        library: library,
                        chapterID: "1",
                        chapterTitle: "Chapter 1"
                    )
                }
            },
            onReadChapter: { chapter in
                readRoute = ReaderLaunchContext.fromChapter(
                    item: item,
                    chapterID: chapter.id,
                    chapterTitle: chapter.title,
                    chapterSequence: detail.chapters,
                    using: library
                )
            },
            onDownloadChapter: { chapter in
                Task {
                    await model.enqueueDownload(
                        using: vm,
                        library: library,
                        chapterID: chapter.id,
                        chapterTitle: chapter.title
                    )
                }
            }
        )
        .id(DetailAnchor.chapters)
    }

    private func previewNote(for detail: ComicDetail) -> String? {
        if dedupedPreviewComments(detail.comments, maxCount: detail.comments.count).count < detail.comments.count {
            return "Preview deduplicated repeated comments"
        }
        if detail.comments.count > 5 {
            return "Showing first 5 comments in preview"
        }
        return nil
    }

    private func downloadStateByChapterID(for detail: ComicDetail) -> [String: DownloadStatus] {
        let downloads = library.downloadChapters.filter {
            $0.sourceKey == item.sourceKey &&
            $0.comicID == item.id
        }
        let offline = library.offlineChapters.filter {
            $0.sourceKey == item.sourceKey &&
            $0.comicID == item.id
        }

        var state: [String: DownloadStatus] = Dictionary(
            uniqueKeysWithValues: downloads.map { chapter in
                (chapter.chapterID, chapter.status)
            }
        )
        for chapter in offline {
            state[chapter.chapterID] = chapter.integrityStatus == .complete ? .completed : .failed
        }
        return state
    }

    private func copyText(_ value: String) {
        UIPasteboard.general.string = value
    }

    private func firstChapter(from detail: ComicDetail) -> (id: String, title: String) {
        if let first = detail.chapters.first {
            return (first.id, first.title.isEmpty ? first.id : first.title)
        }
        return ("1", "Chapter 1")
    }

    private func readTarget(from detail: ComicDetail) -> (chapterID: String, chapterTitle: String, localDirectory: String?) {
        let chapterOrder = Dictionary(uniqueKeysWithValues: detail.chapters.enumerated().map { ($1.id, $0) })
        let completed = library.offlineChapters
            .filter {
                $0.sourceKey == item.sourceKey &&
                $0.comicID == item.id &&
                $0.integrityStatus == .complete
            }
            .sorted { lhs, rhs in
                let li = chapterOrder[lhs.chapterID] ?? Int.max
                let ri = chapterOrder[rhs.chapterID] ?? Int.max
                if li != ri { return li < ri }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.chapterID.localizedCompare(rhs.chapterID) == .orderedAscending
            }

        if let preferred = completed.first {
            let title = preferred.chapterTitle.isEmpty ? preferred.chapterID : preferred.chapterTitle
            return (preferred.chapterID, title, preferred.directoryPath)
        }

        let first = firstChapter(from: detail)
        return (first.id, first.title, nil)
    }

    private func continueTarget(from detail: ComicDetail) -> (chapterID: String, chapterTitle: String, page: Int, localDirectory: String?)? {
        guard let history = library.latestHistoryForComic(sourceKey: item.sourceKey, comicID: item.id) else {
            return nil
        }
        let chapter = resolveChapter(from: detail, historyChapter: history.chapter)
        let offline = library.offlineChapter(
            sourceKey: item.sourceKey,
            comicID: item.id,
            chapterID: chapter.id
        )
        return (chapter.id, chapter.title, max(1, history.page), offline?.directoryPath)
    }

    private func resolveChapter(from detail: ComicDetail, historyChapter: String?) -> (id: String, title: String) {
        let fallback = firstChapter(from: detail)
        guard let historyChapter = historyChapter?.trimmingCharacters(in: .whitespacesAndNewlines),
              !historyChapter.isEmpty
        else {
            return fallback
        }
        if let matched = detail.chapters.first(where: { $0.id == historyChapter || $0.title == historyChapter }) {
            return (matched.id, matched.title.isEmpty ? matched.id : matched.title)
        }
        if let matched = detail.chapters.first(where: {
            $0.id.localizedCaseInsensitiveCompare(historyChapter) == .orderedSame ||
            $0.title.localizedCaseInsensitiveCompare(historyChapter) == .orderedSame
        }) {
            return (matched.id, matched.title.isEmpty ? matched.id : matched.title)
        }
        return fallback
    }

    private func displayedChapters(from detail: ComicDetail) -> [ComicChapter] {
        let normalized = model.chapterQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items = detail.chapters.filter { chapter in
            guard !normalized.isEmpty else { return true }
            return chapter.id.lowercased().contains(normalized) ||
                chapter.title.lowercased().contains(normalized)
        }
        if model.chapterDescending {
            items.reverse()
        }
        return items
    }

    private func onTagTap(namespace: String, tag: String) async {
        let fallback: () -> Void = {
            onTagSelected?(tag, item.sourceKey)
            dismiss()
        }
        do {
            let target = try await vm.resolveComicTagClick(item, namespace: namespace, tag: tag)
            switch target.page {
            case "search":
                let keyword = target.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? tag
                guard !keyword.isEmpty else {
                    fallback()
                    return
                }
                if let onTagSelected {
                    onTagSelected(keyword, item.sourceKey)
                    dismiss()
                } else {
                    tagRoute = .search(sourceKey: item.sourceKey, keyword: keyword)
                }
            case "category":
                let label = target.category?.trimmingCharacters(in: .whitespacesAndNewlines) ?? tag
                guard !label.isEmpty else {
                    fallback()
                    return
                }
                tagRoute = .category(
                    sourceKey: item.sourceKey,
                    item: CategoryItemData(id: UUID().uuidString, label: label, target: target)
                )
            case "ranking":
                tagRoute = .ranking(sourceKey: item.sourceKey)
            default:
                fallback()
            }
        } catch {
            fallback()
        }
    }
}

@MainActor
struct CommentPreviewRow: View {
    let comment: ComicComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(comment.userName)
                    .font(.subheadline.weight(.semibold))
                if let time = comment.timeText, !time.isEmpty {
                    Text(time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let score = comment.score {
                    Text("♥ \(score)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let replyCount = comment.replyCount, replyCount > 0 {
                    Text("↩ \(replyCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(comment.content)
                .font(.subheadline)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
private struct CommentsPageView: View {
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
        initialReplyComment: ComicComment?
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
                initialReplyComment: initialReplyComment
            )
        )
    }

    var body: some View {
        let repliesTargetBinding = Binding(
            get: { model.repliesTarget },
            set: { model.repliesTarget = $0 }
        )

        List {
            if !model.errorText.isEmpty {
                Section {
                    Text(model.errorText)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task { await model.reload(using: vm, replyComment: model.initialReplyComment) }
                    }
                }
            }

            if let replyTo = model.replyTo {
                Section("Reply To") {
                    CommentPreviewRow(comment: replyTo)
                    Button("Cancel Reply", role: .destructive) {
                        model.replyTo = nil
                    }
                }
            }

            if model.loading {
                Section {
                    ProgressView("Loading comments...")
                }
            } else if model.comments.isEmpty {
                Section {
                    Text("No comments")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Comments") {
                    ForEach(Array(model.comments.enumerated()), id: \.offset) { _, comment in
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
                                Text(model.loadingMore ? "Loading..." : "Load More")
                            }
                        }
                        .disabled(model.loadingMore)
                    }
                }
            }
        }
        .navigationTitle("Comments")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
            if initialReplyComment != nil {
                ToolbarItem(placement: .principal) {
                    Text("Replies")
                        .font(.headline)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await model.reload(using: vm, replyComment: model.initialReplyComment) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if capabilities.canSend {
                HStack(spacing: 8) {
                    TextField(
                        model.replyTo == nil ? "Write a comment" : "Reply...",
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
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            }
        }
        .task {
            await model.reload(using: vm, replyComment: model.initialReplyComment)
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
private struct CommentItemRow: View {
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
                if let avatar = comment.avatar, let url = URL(string: avatar) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Circle().fill(.gray.opacity(0.2))
                        }
                    }
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

            Text(comment.content)
                .font(.subheadline)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                if capabilities.canVote, comment.actionableCommentID != nil {
                    Button {
                        Task { await vote(isUp: true) }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .disabled(working)
                    .tint(voteStatus == 1 ? .red : .primary)

                    Text("\(score ?? comment.score ?? 0)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button {
                        Task { await vote(isUp: false) }
                    } label: {
                        Image(systemName: "arrow.down")
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
                            isLiked == true ? "Liked" : "Like",
                            systemImage: isLiked == true ? "heart.fill" : "heart"
                        )
                        .font(.caption)
                    }
                    .disabled(working)
                }

                if comment.actionableCommentID != nil {
                    Button("Reply") {
                        onReply(comment)
                    }
                    .font(.caption)
                }
                if let replyCount = comment.replyCount, replyCount > 0, comment.actionableCommentID != nil {
                    Button("Replies \(replyCount)") {
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
