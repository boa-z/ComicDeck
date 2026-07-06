#if os(iOS)
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
    var onNavigateBack: (() -> Void)? = nil

    @State private var model: ComicDetailScreenModel
    @State private var readRoute: ReaderLaunchContext?
    @State private var tagRoute: CategoryNavigationTarget?
    @State private var didConsumeInitialReadRoute = false
    @State private var trackerSearchProvider: TrackerProvider?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(
        vm: ReaderViewModel,
        item: ComicSummary,
        onTagSelected: ((String, String) -> Void)? = nil,
        initialReadRoute: ReaderLaunchContext? = nil,
        onConsumeInitialReadRoute: (() -> Void)? = nil,
        onNavigateBack: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.item = item
        self.onTagSelected = onTagSelected
        self.initialReadRoute = initialReadRoute
        self.onConsumeInitialReadRoute = onConsumeInitialReadRoute
        self.onNavigateBack = onNavigateBack
        _model = State(initialValue: ComicDetailScreenModel(item: item))
    }

    private var sourceDisplayName: String {
        vm.sourceManager.installedSources.first(where: { $0.key == item.sourceKey })?.name ?? item.sourceKey
    }

    private var detailIdentity: String {
        "\(item.sourceKey)::\(item.id)"
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
            .platformNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .platformTopBarTrailing) {
                    toolbarMenu
                }
            }
            .task(id: detailIdentity) {
                let currentModel = ComicDetailScreenModel(item: item)
                model = currentModel
                didConsumeInitialReadRoute = false
                await currentModel.load(using: vm, library: library)
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
                            initialReplyComment: nil,
                            seededComments: dedupedPreviewComments(detail.comments)
                        )
                    }
                }
            }
            .sheet(item: $trackerSearchProvider) { provider in
                TrackerSearchSheet(
                    item: item,
                    provider: provider,
                    initialQuery: detailSearchQuery
                ) {
                    Task { await model.load(using: vm, library: library) }
                }
                .environment(vm.tracker)
            }
            .navigationDestination(item: $readRoute) { route in
                ReaderRoutingView(
                    vm: vm,
                    item: route.item,
                    chapterID: route.chapterID,
                    chapterTitle: route.chapterTitle,
                    localChapterDirectory: route.localDirectory,
                    initialPage: route.initialPage,
                    chapterSequence: route.chapterSequence
                )
                .environment(library)
            }
            .navigationDestination(item: $tagRoute) { target in
                switch target {
                case let .category(sourceKey, item):
                    CategoryComicsPageView(vm: vm, sourceKey: sourceKey, item: item)
                        .environment(library)
                case let .ranking(sourceKey):
                    CategoryRankingPageView(vm: vm, sourceKey: sourceKey, initialProfile: .empty)
                        .environment(library)
                case let .search(sourceKey, keyword):
                    SourceScopedSearchView(vm: vm, sourceKey: sourceKey, initialKeyword: keyword)
                        .environment(library)
                }
            }
            .confirmationDialog(
                AppLocalization.text("detail.queue_all.title", "Queue download for all chapters?"),
                isPresented: showQueueConfirmBinding,
                titleVisibility: .visible
            ) {
                Button(AppLocalization.text("detail.queue_all.action", "Queue All"), role: .destructive) {
                    if model.detail != nil {
                        Task { await model.queueAllChapters(using: vm, library: library) }
                    }
                }
                Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {}
            } message: {
                if let detail = model.detail {
                    Text(AppLocalization.text("detail.queue_all.message", "This will queue \(detail.chapters.count) chapters."))
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

    private func navigateBack() {
        if let onNavigateBack {
            onNavigateBack()
        } else {
            dismiss()
        }
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
        ComicDetailSectionCard(title: AppLocalization.text("detail.loading", "Loading"), subtitle: AppLocalization.text("detail.loading.subtitle", "Fetching detail, comments, and favorite state")) {
            ProgressView(AppLocalization.text("detail.loading.progress", "Loading comic details..."))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var errorCard: some View {
        ComicDetailSectionCard(title: AppLocalization.text("detail.load_failed", "Load Failed"), subtitle: AppLocalization.text("detail.load_failed.subtitle", "The source returned an error")) {
            Text(model.errorText)
                .foregroundStyle(AppTint.danger)
            Button(AppLocalization.text("common.retry", "Retry")) {
                Task { await model.load(using: vm, library: library) }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var toolbarMenu: some View {
        Menu {
            Button(AppLocalization.text("detail.action.copy_title", "Copy Title")) {
                let title = (model.detail?.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    ? (model.detail?.title ?? item.title)
                    : item.title
                copyText(title)
            }
            Button(AppLocalization.text("detail.action.copy_id", "Copy ID")) {
                copyText(item.id)
            }
            if let url = model.browserURLString {
                Button(AppLocalization.text("detail.action.copy_url", "Copy URL")) {
                    copyText(url)
                }
                Button(AppLocalization.text("detail.action.open_browser", "Open In Browser")) {
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
        let chapterSnapshot = chapterSnapshot(from: detail)
        ComicDetailHeroSection(
            item: item,
            detail: displayDetail,
            sourceName: sourceDisplayName,
            chapterCount: displayDetail.chapters.count,
            commentCount: displayDetail.commentsCount ?? displayDetail.comments.count,
            browserURLString: model.browserURLString,
            showContinue: chapterSnapshot.continueTarget != nil,
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
                guard let target = chapterSnapshot.continueTarget else { return }
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
                let first = chapterSnapshot.firstChapter
                readRoute = ReaderLaunchContext.fromChapter(
                    item: item,
                    chapterID: first.chapterID,
                    chapterTitle: first.chapterTitle,
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
                let target = chapterSnapshot.readTarget
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

        ComicDetailPreviewSection(
            images: model.previewImages,
            loading: model.previewLoading,
            canLoadMore: model.previewNextToken != nil && !model.previewLoading,
            errorText: model.previewErrorText,
            onOpenPage: { preview in
                let target = chapterSnapshot.readTarget
                readRoute = ReaderLaunchContext(
                    item: item,
                    chapterID: target.chapterID,
                    chapterTitle: target.chapterTitle,
                    localDirectory: target.localDirectory,
                    initialPage: preview.page,
                    chapterSequence: detail.chapters
                )
            },
            onLoadMore: {
                Task { await model.loadMorePreviewImages(using: vm) }
            }
        )

        ComicDetailChaptersSection(
            chapters: chapterSnapshot.displayedChapters,
            totalChapterCount: detail.chapters.count,
            chapterQuery: Binding(
                get: { model.chapterQuery },
                set: { model.chapterQuery = $0 }
            ),
            chapterDescending: Binding(
                get: { model.chapterDescending },
                set: { model.chapterDescending = $0 }
            ),
            continueChapterID: chapterSnapshot.continueTarget?.chapterID,
            downloadStateByChapterID: chapterSnapshot.downloadStateByChapterID,
            offlineChapterCount: chapterSnapshot.offlineChapterCount,
            queueingAll: model.queueingAll,
            queueAllProgressText: model.queueAllProgressText,
            onQueueAll: {
                if detail.chapters.isEmpty {
                    let target = chapterSnapshot.readTarget
                    Task {
                        await model.enqueueDownload(
                            using: vm,
                            library: library,
                            chapterID: target.chapterID,
                            chapterTitle: target.chapterTitle
                        )
                    }
                } else {
                    model.showQueueAllConfirm = true
                }
            },
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

        ComicDetailTagsSection(groups: detail.tags) { namespace, tag in
            Task { await onTagTap(namespace: namespace, tag: tag) }
        }
        .id(DetailAnchor.tags)

        if model.commentCapabilities.canLoad || !detail.comments.isEmpty || (detail.commentsCount ?? 0) > 0 {
            ComicDetailCommentsSection(
                title: AppLocalization.format(
                    "detail.comments.title_count_format",
                    "Comments (%lld)",
                    Int64(detail.commentsCount ?? detail.comments.count)
                ),
                canLoad: model.commentCapabilities.canLoad,
                previewComments: model.showCommentPreview ? dedupedPreviewComments(detail.comments) : [],
                isPreviewExpanded: model.showCommentPreview,
                previewNote: previewNote(for: detail),
                onTogglePreview: { model.showCommentPreview.toggle() },
                onOpenComments: { model.showCommentsPage = true }
            )
            .id(DetailAnchor.comments)
        }

        ComicTrackerSection(
            providers: TrackerProvider.allCases.map {
                ComicTrackerProviderState(
                    provider: $0,
                    account: vm.tracker.account(for: $0),
                    binding: vm.tracker.binding(for: item, provider: $0),
                    syncing: vm.tracker.syncing,
                    statusText: vm.tracker.status
                )
            },
            manualDefaultDirection: vm.tracker.manualSyncDefaultDirection,
            onLink: { trackerSearchProvider = $0 },
            onSync: { provider, direction in
                syncTrackerBinding(detail: detail, provider: provider, direction: direction)
            },
            onUnlink: { unlinkTrackerBinding(provider: $0) }
        )

        ComicDetailFavoriteSection(
            effectiveIsFavorited: model.effectiveIsFavorited,
            favoriteFolders: model.actionableFavoriteFolders,
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
    }

    private var detailSearchQuery: String {
        let resolved = model.detail?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let resolved, !resolved.isEmpty {
            return resolved
        }
        return item.title
    }

    private func syncTrackerBinding(detail: ComicDetail, provider: TrackerProvider, direction: TrackerSyncDirection) {
        Task {
            do {
                let summary = try await vm.tracker.sync(
                    item: item,
                    chapterSequence: detail.chapters,
                    provider: provider,
                    direction: direction,
                    library: library,
                    allowLocalRegression: direction == .remoteToLocal
                )
                vm.tracker.status = trackerSyncStatusText(summary)
            } catch {
                vm.tracker.status = error.localizedDescription
            }
        }
    }

    private func trackerSyncStatusText(_ summary: TrackerSyncSummary) -> String {
        if summary.pushedRemote {
            return AppLocalization.format(
                "tracking.sync.status.pushed_format",
                "Pushed %@ progress %@",
                summary.provider.title,
                String(summary.progress)
            )
        }
        if summary.updatedLocalHistory {
            return AppLocalization.format(
                "tracking.sync.status.pulled_history_format",
                "Pulled %@ progress %@ to local history",
                summary.provider.title,
                String(summary.progress)
            )
        }
        if summary.pulledRemote {
            return AppLocalization.format(
                "tracking.sync.status.pulled_metadata_format",
                "Pulled %@ progress %@",
                summary.provider.title,
                String(summary.progress)
            )
        }
        return AppLocalization.text("tracking.sync.status.complete", "Tracker sync complete")
    }

    private func unlinkTrackerBinding(provider: TrackerProvider) {
        Task {
            do {
                try await vm.tracker.unbind(item, provider: provider)
            } catch {
                vm.tracker.status = error.localizedDescription
            }
        }
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

    private func chapterSnapshot(from detail: ComicDetail) -> ComicDetailChapterSnapshot {
        ComicDetailChapterSnapshot(
            sourceKey: item.sourceKey,
            comicID: item.id,
            detail: detail,
            chapterQuery: model.chapterQuery,
            chapterDescending: model.chapterDescending,
            downloads: library.downloadChapters,
            offlineChapters: library.offlineChapters,
            latestHistory: library.latestHistoryForComic(sourceKey: item.sourceKey, comicID: item.id)
        )
    }

    private func copyText(_ value: String) {
        PlatformPasteboard.copy(value)
    }

    private func onTagTap(namespace: String, tag: String) async {
        let fallback: () -> Void = {
            onTagSelected?(tag, item.sourceKey)
            navigateBack()
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
                    navigateBack()
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

#endif
