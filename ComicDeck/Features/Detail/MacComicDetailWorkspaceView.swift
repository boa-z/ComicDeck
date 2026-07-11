#if os(macOS)
import SwiftUI

@MainActor
struct MacComicDetailWorkspaceView: View {
    private enum WorkspaceTab: String, CaseIterable, Identifiable {
        case overview
        case chapters
        case tags
        case activity

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview:
                return AppLocalization.text("detail.tab.overview", "Overview")
            case .chapters:
                return AppLocalization.text("detail.tab.chapters", "Chapters")
            case .tags:
                return AppLocalization.text("detail.tab.tags", "Tags")
            case .activity:
                return AppLocalization.text("detail.tab.activity", "Activity")
            }
        }

        var systemImage: String {
            switch self {
            case .overview: return "info.circle"
            case .chapters: return "books.vertical"
            case .tags: return "tag"
            case .activity: return "clock.arrow.circlepath"
            }
        }
    }

    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    let item: ComicSummary
    var onTagSelected: ((String, String) -> Void)?
    var initialReadRoute: ReaderLaunchContext?
    var onConsumeInitialReadRoute: (() -> Void)?
    var onNavigateBack: (() -> Void)?

    @State private var model: ComicDetailScreenModel
    @State private var selectedTab: WorkspaceTab = .chapters
    @State private var tagRoute: CategoryNavigationTarget?
    @State private var didConsumeInitialReadRoute = false
    @State private var trackerSearchProvider: TrackerProvider?
    @State private var showCommentsSheet = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow

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

    private var detailIdentity: String {
        "\(item.sourceKey)::\(item.id)"
    }

    private var sourceDisplayName: String {
        vm.sourceManager.installedSources.first(where: { $0.key == item.sourceKey })?.name ?? item.sourceKey
    }

    private var resolvedTitle: String {
        let title = model.displayDetail?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? (title ?? item.title) : item.title
    }

    var body: some View {
        Group {
            if let detail = model.displayDetail {
                workspace(detail: detail)
            } else if model.loading {
                loadingView
            } else if !model.errorText.isEmpty {
                errorView
            } else {
                loadingView
            }
        }
        .navigationTitle(resolvedTitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await reload() }
                } label: {
                    Label(AppLocalization.text("common.refresh", "Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(model.loading)

                moreMenu
            }
        }
        .task(id: detailIdentity) {
            model = ComicDetailScreenModel(item: item)
            didConsumeInitialReadRoute = false
            await reload()
        }
        .onChange(of: model.detail != nil) { _, isReady in
            guard isReady else { return }
            maybeOpenInitialReadRoute()
        }
        .sheet(item: $trackerSearchProvider) { provider in
            TrackerSearchSheet(
                item: item,
                provider: provider,
                initialQuery: resolvedTitle
            ) {
                Task { await reload() }
            }
            .environment(vm.tracker)
            .frame(minWidth: 760, minHeight: 560)
        }
        .sheet(isPresented: $showCommentsSheet) {
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
                .frame(minWidth: 520, minHeight: 400)
            }
        }
        .confirmationDialog(
            AppLocalization.text("detail.queue_all.title", "Queue download for all chapters?"),
            isPresented: Binding(
                get: { model.showQueueAllConfirm },
                set: { model.showQueueAllConfirm = $0 }
            ),
            titleVisibility: .visible
        ) {
            Button(AppLocalization.text("detail.queue_all.action", "Queue All"), role: .destructive) {
                Task { await model.queueAllChapters(using: vm, library: library) }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            if let detail = model.detail {
                Text(AppLocalization.text("detail.queue_all.message", "This will queue \(detail.chapters.count) chapters."))
            }
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
    }

    private func workspace(detail: ComicDetail) -> some View {
        HStack(spacing: 0) {
            summaryPane(detail: detail)
                .frame(width: 300)

            Divider()

            detailPane(detail: detail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppSurface.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func summaryPane(detail: ComicDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CoverArtworkView(
                    urlString: detail.cover ?? item.coverURL,
                    refererURLString: detail.comicURL ?? item.id,
                    width: 190,
                    height: 266
                )
                .frame(maxWidth: .infinity, alignment: .center)

                VStack(alignment: .leading, spacing: 6) {
                    Text(resolvedTitle)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Label(sourceDisplayName, systemImage: "shippingbox")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let author = item.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                        Label(author, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                metricsGrid(detail: detail)

                VStack(spacing: 8) {
                    let chapterSnapshot = chapterSnapshot(from: detail)
                    if chapterSnapshot.continueTarget != nil {
                        Button {
                            openContinue(detail: detail, chapterSnapshot: chapterSnapshot)
                        } label: {
                            Label(AppLocalization.text("detail.hero.action.continue", "Continue"), systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if chapterSnapshot.continueTarget == nil {
                        Button {
                            openFirstChapter(detail: detail, chapterSnapshot: chapterSnapshot)
                        } label: {
                            Label(AppLocalization.text("detail.hero.action.start", "Start"), systemImage: "book.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            openFirstChapter(detail: detail, chapterSnapshot: chapterSnapshot)
                        } label: {
                            Label(AppLocalization.text("detail.hero.action.start", "Start"), systemImage: "book.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button {
                        model.startToggleBookmark(using: library)
                    } label: {
                        Label(
                            model.isBookmarked
                                ? AppLocalization.text("detail.hero.action.bookmarked", "Bookmarked")
                                : AppLocalization.text("detail.hero.action.bookmark", "Bookmark"),
                            systemImage: model.isBookmarked ? "bookmark.fill" : "bookmark"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.bookmarkWorking)

                    Button {
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
                    } label: {
                        Label(queueAllTitle, systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.queueingAll)
                }
            }
            .padding(18)
        }
        .background(AppSurface.card)
    }

    private func metricsGrid(detail: ComicDetail) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                metricTile(
                    title: AppLocalization.text("detail.hero.metric.chapters", "Chapters"),
                    value: "\(detail.chapters.count)",
                    systemImage: "books.vertical",
                    action: { selectedTab = .chapters }
                )
                metricTile(
                    title: AppLocalization.text("detail.hero.metric.comments", "Comments"),
                    value: "\(detail.commentsCount ?? detail.comments.count)",
                    systemImage: "text.bubble",
                    action: { showCommentsSheet = true }
                )
            }
            GridRow {
                metricTile(
                    title: AppLocalization.text("detail.hero.metric.tags", "Tags"),
                    value: "\(detail.tags.reduce(0) { $0 + $1.values.count })",
                    systemImage: "tag",
                    action: { selectedTab = .tags }
                )
                metricTile(
                    title: AppLocalization.text("detail.favorite.title", "Source Favorite"),
                    value: model.effectiveIsFavorited ? AppLocalization.text("detail.favorite.favorited", "Favorited") : "-",
                    systemImage: "heart"
                )
            }
        }
    }

    private func metricTile(title: String, value: String, systemImage: String, action: (() -> Void)? = nil) -> some View {
        Group {
            if let action {
                Button(action: action) {
                    metricTileContent(title: title, value: value, systemImage: systemImage)
                }
                .buttonStyle(.plain)
            } else {
                metricTileContent(title: title, value: value, systemImage: systemImage)
            }
        }
    }

    private func metricTileContent(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTint.accent)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(AppSurface.subtle, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func detailPane(detail: ComicDetail) -> some View {
        VStack(spacing: 0) {
            Picker(AppLocalization.text("detail.tabs", "Detail sections"), selection: $selectedTab) {
                ForEach(WorkspaceTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.systemImage).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(AppSurface.card)

            Divider()

            switch selectedTab {
            case .overview:
                overviewTab(detail: detail)
            case .chapters:
                chaptersTab(detail: detail)
            case .tags:
                tagsTab(detail: detail)
            case .activity:
                activityTab(detail: detail)
            }
        }
        .background(AppSurface.grouped)
    }

    private func overviewTab(detail: ComicDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let description = detail.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                    MacDetailPanel(title: AppLocalization.text("detail.description.title", "Description")) {
                        RichTextContent(text: description, lineLimit: model.showFullDescription ? nil : 10)
                            .font(.body)
                            .textSelection(.enabled)
                        Button(
                            model.showFullDescription
                                ? AppLocalization.text("detail.hero.description.show_less", "Show Less")
                                : AppLocalization.text("detail.hero.description.show_more", "Show More")
                        ) {
                            model.showFullDescription.toggle()
                        }
                        .buttonStyle(.borderless)
                    }
                }

                previewPanel(detail: detail)

                if let url = model.browserURLString {
                    MacDetailPanel(title: AppLocalization.text("detail.link.title", "Source Link")) {
                        Text(url)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button(AppLocalization.text("detail.action.open_browser", "Open In Browser")) {
                            if let target = URL(string: url) {
                                openURL(target)
                            }
                        }
                    }
                }

                if !detail.comments.isEmpty {
                    MacDetailPanel(title: AppLocalization.text("comments.section.title", "Comments")) {
                        ForEach(dedupedPreviewComments(detail.comments), id: \.id) { comment in
                            CommentPreviewRow(comment: comment)
                            Divider()
                        }
                        Button(AppLocalization.text("comments.action.view_all", "View All Comments")) {
                            showCommentsSheet = true
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    @ViewBuilder
    private func previewPanel(detail: ComicDetail) -> some View {
        if !model.previewImages.isEmpty || model.previewLoading || model.previewNextToken != nil || !model.previewErrorText.isEmpty {
            MacDetailPanel(title: AppLocalization.text("detail.preview.title", "Preview")) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.previewImages.isEmpty, model.previewLoading {
                        ProgressView(AppLocalization.text("detail.preview.loading", "Loading previews..."))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if !model.previewImages.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 92, maximum: 136), spacing: 10)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(model.previewImages) { image in
                                MacComicPreviewTile(image: image) {
                                    openPreview(image, detail: detail)
                                }
                                .onAppear {
                                    if image.id == model.previewImages.last?.id,
                                       model.previewNextToken != nil,
                                       !model.previewLoading {
                                        Task { await model.loadMorePreviewImages(using: vm) }
                                    }
                                }
                            }
                        }
                    }

                    if model.previewLoading, !model.previewImages.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    } else if model.previewNextToken != nil {
                        Button(AppLocalization.text("detail.preview.load_more", "Load More"), systemImage: "arrow.down.circle") {
                            Task { await model.loadMorePreviewImages(using: vm) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !model.previewErrorText.isEmpty {
                        Text(model.previewErrorText)
                            .font(.caption)
                            .foregroundStyle(AppTint.danger)
                    }
                }
            }
        }
    }

    private func chaptersTab(detail: ComicDetail) -> some View {
        let chapterSnapshot = chapterSnapshot(from: detail)

        return VStack(spacing: 0) {
            chapterFilterControls
            .padding(14)
            .background(AppSurface.card)

            List(chapterSnapshot.displayedChapters) { chapter in
                MacChapterRow(
                    chapter: chapter,
                    status: chapterSnapshot.downloadStateByChapterID[chapter.id],
                    isContinueTarget: chapterSnapshot.continueTarget?.chapterID == chapter.id,
                    onRead: {
                        openWindow(id: "reader", value: ReaderLaunchContext.fromChapter(
                            item: item,
                            chapterID: chapter.id,
                            chapterTitle: chapter.title,
                            chapterSequence: detail.chapters,
                            using: library
                        ))
                    },
                    onDownload: {
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
            }
            .listStyle(.inset)
        }
    }

    private var chapterFilterControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                chapterSearchField
                newestFirstToggle
            }

            VStack(alignment: .leading, spacing: 8) {
                chapterSearchField
                newestFirstToggle
            }
        }
    }

    private var chapterSearchField: some View {
        TextField(
            AppLocalization.text("detail.chapters.search", "Search chapters"),
            text: Binding(
                get: { model.chapterQuery },
                set: { model.chapterQuery = $0 }
            )
        )
        .textFieldStyle(.roundedBorder)
    }

    private var newestFirstToggle: some View {
        Toggle(
            AppLocalization.text("detail.chapters.descending", "Newest first"),
            isOn: Binding(
                get: { model.chapterDescending },
                set: { model.chapterDescending = $0 }
            )
        )
        .toggleStyle(.checkbox)
    }

    private func tagsTab(detail: ComicDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if detail.tags.isEmpty {
                    ContentUnavailableView(
                        AppLocalization.text("detail.tags.empty", "No tags"),
                        systemImage: "tag"
                    )
                } else {
                    ForEach(detail.tags) { group in
                        MacDetailPanel(title: group.title) {
                            MacFlexibleTagLayout(tags: group.values) { value in
                                Button(value) {
                                    Task { await onTagTap(namespace: group.title, tag: value) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private func activityTab(detail: ComicDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                MacDetailPanel(title: AppLocalization.text("detail.favorite.title", "Source Favorite")) {
                    HStack {
                        Label(
                            model.effectiveIsFavorited
                                ? AppLocalization.text("detail.favorite.favorited", "Favorited")
                                : AppLocalization.text("detail.favorite.not_favorited", "Not Favorited"),
                            systemImage: model.effectiveIsFavorited ? "heart.fill" : "heart"
                        )
                        .foregroundStyle(model.effectiveIsFavorited ? AppTint.success : .secondary)
                        Spacer()
                        Button(model.effectiveIsFavorited ? AppLocalization.text("common.remove", "Remove") : AppLocalization.text("common.add", "Add")) {
                            model.startToggleFavorite(using: vm, isAdding: !model.effectiveIsFavorited)
                        }
                        .disabled(model.rootFavoriteWorking)
                    }

                    if !model.favoriteStatus.isEmpty {
                        Text(model.favoriteStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                MacDetailPanel(title: AppLocalization.text("tracking.section.title", "Tracking")) {
                    ForEach(TrackerProvider.allCases) { provider in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(vm.tracker.binding(for: item, provider: provider)?.remoteTitle ?? AppLocalization.text("tracking.status.unlinked", "Not linked"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(AppLocalization.text("tracking.action.link", "Link")) {
                                trackerSearchProvider = provider
                            }
                        }
                        Divider()
                    }
                }

                if !library.status.isEmpty || !model.queueAllProgressText.isEmpty {
                    MacDetailPanel(title: AppLocalization.text("downloads.navigation.title", "Downloads")) {
                        Text(model.queueAllProgressText.isEmpty ? library.status : model.queueAllProgressText)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text(AppLocalization.text("detail.loading.progress", "Loading comic details..."))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurface.grouped)
    }

    private var errorView: some View {
        ContentUnavailableView {
            Label(AppLocalization.text("detail.load_failed", "Load Failed"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(model.errorText)
        } actions: {
            Button(AppLocalization.text("common.retry", "Retry")) {
                Task { await reload() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurface.grouped)
    }

    private var moreMenu: some View {
        Menu {
            Button(AppLocalization.text("detail.action.copy_title", "Copy Title")) {
                PlatformPasteboard.copy(resolvedTitle)
            }
            Button(AppLocalization.text("detail.action.copy_id", "Copy ID")) {
                PlatformPasteboard.copy(item.id)
            }
            if let url = model.browserURLString {
                Button(AppLocalization.text("detail.action.copy_url", "Copy URL")) {
                    PlatformPasteboard.copy(url)
                }
                Button(AppLocalization.text("detail.action.open_browser", "Open In Browser")) {
                    if let target = URL(string: url) {
                        openURL(target)
                    }
                }
            }
        } label: {
            Label(AppLocalization.text("tracking.sync.more", "More"), systemImage: "ellipsis.circle")
        }
    }

    private var queueAllTitle: String {
        if model.queueingAll {
            return model.queueAllProgressText.isEmpty
                ? AppLocalization.text("detail.queue_all.queueing", "Queueing...")
                : model.queueAllProgressText
        }
        return AppLocalization.text("detail.queue_all.action", "Queue All")
    }

    private func reload() async {
        await model.load(using: vm, library: library)
    }

    private func maybeOpenInitialReadRoute() {
        guard !didConsumeInitialReadRoute,
              model.detail != nil,
              let initialReadRoute else { return }
        didConsumeInitialReadRoute = true
        onConsumeInitialReadRoute?()
        openWindow(id: "reader", value: initialReadRoute)
    }

    private func navigateBack() {
        if let onNavigateBack {
            onNavigateBack()
        } else {
            dismiss()
        }
    }

    private func openContinue(detail: ComicDetail, chapterSnapshot: ComicDetailChapterSnapshot? = nil) {
        let snapshot = chapterSnapshot ?? self.chapterSnapshot(from: detail)
        guard let target = snapshot.continueTarget else { return }
        openWindow(id: "reader", value: ReaderLaunchContext(
            item: item,
            chapterID: target.chapterID,
            chapterTitle: target.chapterTitle,
            localDirectory: target.localDirectory,
            initialPage: max(1, target.page),
            chapterSequence: detail.chapters
        ))
    }

    private func openPreview(_ preview: ComicPreviewImage, detail: ComicDetail) {
        let target = chapterSnapshot(from: detail).readTarget
        openWindow(id: "reader", value: ReaderLaunchContext(
            item: item,
            chapterID: target.chapterID,
            chapterTitle: target.chapterTitle,
            localDirectory: target.localDirectory,
            initialPage: max(1, preview.page),
            chapterSequence: detail.chapters
        ))
    }

    private func openFirstChapter(detail: ComicDetail, chapterSnapshot: ComicDetailChapterSnapshot? = nil) {
        let first = (chapterSnapshot ?? self.chapterSnapshot(from: detail)).firstChapter
        openWindow(id: "reader", value: ReaderLaunchContext.fromChapter(
            item: item,
            chapterID: first.chapterID,
            chapterTitle: first.chapterTitle,
            chapterSequence: detail.chapters,
            using: library
        ))
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
}

private struct MacComicPreviewTile: View {
    let image: ComicPreviewImage
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomTrailing) {
                CachedRemoteImage(
                    urlString: image.imageURL,
                    imageRequest: image.imageRequest,
                    refererURLString: image.sourceURL,
                    decodeSize: CGSize(width: 180, height: 250),
                    contentMode: .fill,
                    priority: .thumbnail
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(0.72, contentMode: .fit)
                .clipped()

                Text(String(image.page))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(6)
            }
            .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                    .stroke(AppSurface.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.format(
            "detail.preview.open_page_accessibility_format",
            "Open page %lld",
            Int64(image.page)
        ))
        .help(AppLocalization.format(
            "detail.preview.open_page_accessibility_format",
            "Open page %lld",
            Int64(image.page)
        ))
    }
}

private struct MacDetailPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .stroke(AppSurface.border, lineWidth: 1)
        }
    }
}

private struct MacChapterRow: View {
    let chapter: ComicChapter
    let status: DownloadStatus?
    let isContinueTarget: Bool
    let onRead: () -> Void
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isContinueTarget ? "play.circle.fill" : "book")
                .foregroundStyle(isContinueTarget ? AppTint.accent : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title.isEmpty ? chapter.id : chapter.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(chapter.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 0)

            if let status {
                Text(status.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusTint(status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(statusTint(status).opacity(0.12), in: Capsule())
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    readButton
                    downloadButton
                }

                HStack(spacing: 6) {
                    readButton.labelStyle(.iconOnly)
                    downloadButton.labelStyle(.iconOnly)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button(AppLocalization.text("reader.action.read", "Read"), systemImage: "play.fill", action: onRead)
            Button(AppLocalization.text("detail.hero.action.download", "Download"), systemImage: "arrow.down.circle", action: onDownload)
            Divider()
            Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
                PlatformPasteboard.copy(chapter.title.isEmpty ? chapter.id : chapter.title)
            }
            Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
                PlatformPasteboard.copy(chapter.id)
            }
        }
    }

    private func statusTint(_ status: DownloadStatus) -> Color {
        switch status {
        case .completed:
            return AppTint.success
        case .downloading:
            return AppTint.accent
        case .failed:
            return AppTint.danger
        case .pending:
            return AppTint.warning
        }
    }

    private var readButton: some View {
        Button(AppLocalization.text("reader.action.read", "Read"), systemImage: "play.fill", action: onRead)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(AppLocalization.text("reader.action.read", "Read"))
    }

    private var downloadButton: some View {
        Button(AppLocalization.text("detail.hero.action.download", "Download"), systemImage: "arrow.down.circle", action: onDownload)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(AppLocalization.text("detail.hero.action.download", "Download"))
    }
}

private struct MacFlexibleTagLayout<Content: View>: View {
    let tags: [String]
    @ViewBuilder let content: (String) -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: 8, alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(tags, id: \.self) { tag in
                content(tag)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
#endif
