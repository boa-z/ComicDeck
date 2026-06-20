import SwiftUI
import Observation

@MainActor
@Observable
final class TrackerSubscriptionDetailModel {
    var syncingGroupID: String?
    var bindingComicID: String?
    var errorMessage: String?

    func sync(
        group: TrackerSubscriptionLocalGroup,
        provider: TrackerProvider,
        direction: TrackerSyncDirection,
        vm: ReaderViewModel,
        tracker: TrackerViewModel,
        library: LibraryViewModel
    ) async {
        syncingGroupID = group.id
        errorMessage = nil
        defer { syncingGroupID = nil }

        let item = ComicSummary(
            id: group.comicID,
            sourceKey: group.sourceKey,
            title: group.title,
            coverURL: group.coverURL
        )
        do {
            let detail = try await vm.loadComicDetail(item)
            let summary = try await tracker.sync(
                item: item,
                chapterSequence: detail.chapters,
                provider: provider,
                direction: direction,
                library: library,
                allowLocalRegression: direction == .remoteToLocal
            )
            tracker.status = Self.statusText(summary)
        } catch {
            errorMessage = error.localizedDescription
            tracker.status = error.localizedDescription
        }
    }

    func unlink(
        group: TrackerSubscriptionLocalGroup,
        provider: TrackerProvider,
        tracker: TrackerViewModel
    ) async {
        syncingGroupID = group.id
        errorMessage = nil
        defer { syncingGroupID = nil }
        do {
            try await tracker.unbind(
                ComicSummary(
                    id: group.comicID,
                    sourceKey: group.sourceKey,
                    title: group.title,
                    coverURL: group.coverURL
                ),
                provider: provider
            )
        } catch {
            errorMessage = error.localizedDescription
            tracker.status = error.localizedDescription
        }
    }

    func bind(
        item: ComicSummary,
        entry: TrackerListEntry,
        provider: TrackerProvider,
        tracker: TrackerViewModel
    ) async -> Bool {
        bindingComicID = item.id
        errorMessage = nil
        defer { bindingComicID = nil }
        do {
            try await tracker.bind(
                item,
                provider: provider,
                result: TrackerSearchResult(
                    id: entry.mediaID,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    coverURL: entry.coverURL,
                    statusText: entry.status?.title,
                    chapterCount: entry.chapterCount,
                    siteURL: entry.siteURL
                ),
                initialProgress: entry.progress,
                initialStatus: entry.status
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            tracker.status = error.localizedDescription
            return false
        }
    }

    private static func statusText(_ summary: TrackerSyncSummary) -> String {
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
}

@MainActor
struct TrackerSubscriptionDetailView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    let provider: TrackerProvider
    let row: TrackerSubscriptionRow

    @Environment(TrackerViewModel.self) private var tracker
    @Environment(LibraryViewModel.self) private var library
    @Environment(\.openURL) private var openURL
    @State private var model = TrackerSubscriptionDetailModel()
    @State private var sourceSearchRoute: TrackerSourceSearchRoute?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                remoteEntryCard
                syncHintCard

                if let errorMessage = model.errorMessage {
                    errorBanner(errorMessage)
                }

                if localGroups.isEmpty {
                    unboundCard
                } else {
                    bindingsSection
                }
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle(row.entry.title)
        .platformNavigationBarTitleDisplayModeInline()
        .sheet(item: $sourceSearchRoute) { route in
            TrackerSourceBindingSearchSheet(
                vm: vm,
                provider: provider,
                entry: row.entry,
                sourceKey: route.sourceKey,
                initialKeyword: route.keyword,
                onBind: bindSourceComic
            )
            .environment(library)
        }
    }

    private var localGroups: [TrackerSubscriptionLocalGroup] {
        let groups = tracker.bindingGroups(provider: provider, remoteMediaID: row.entry.mediaID).compactMap { bindings -> TrackerSubscriptionLocalGroup? in
            guard let providerBinding = bindings[provider] else { return nil }
            let localComic = localComic(for: providerBinding)
            return TrackerSubscriptionLocalGroup(
                sourceKey: providerBinding.sourceKey,
                comicID: providerBinding.comicID,
                title: localComic?.title ?? providerBinding.sourceTitle ?? providerBinding.remoteTitle,
                coverURL: localComic?.coverURL ?? providerBinding.sourceCoverURL ?? providerBinding.remoteCoverURL,
                bindings: bindings
            )
        }
        return groups
    }

    private func localComic(for binding: TrackerBinding) -> ComicSummary? {
        if let favorite = library.favorites.first(where: { $0.sourceKey == binding.sourceKey && $0.id == binding.comicID }) {
            return ComicSummary(id: favorite.id, sourceKey: favorite.sourceKey, title: favorite.title, coverURL: favorite.coverURL)
        }
        if let history = library.history.first(where: { $0.sourceKey == binding.sourceKey && $0.comicID == binding.comicID }) {
            return ComicSummary(
                id: history.comicID,
                sourceKey: history.sourceKey,
                title: history.title,
                coverURL: history.coverURL,
                author: history.author,
                tags: history.tags
            )
        }
        if let offline = library.offlineChapters.first(where: { $0.sourceKey == binding.sourceKey && $0.comicID == binding.comicID }) {
            return ComicSummary(id: offline.comicID, sourceKey: offline.sourceKey, title: offline.comicTitle, coverURL: offline.coverURL)
        }
        return nil
    }

    private var remoteEntryCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                CoverArtworkView(urlString: row.entry.coverURL, width: 104, height: 148)
                    .frame(width: 104, height: 148)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(row.entry.title)
                        .font(.title3.weight(.semibold))
                    if let subtitle = row.entry.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text(remoteProgressText(row.entry))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTint.accent)
                    if let updatedAt = row.entry.updatedAt {
                        Text(updatedText(updatedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let siteURL = row.entry.siteURL, let url = URL(string: siteURL) {
                        Button {
                            openURL(url)
                        } label: {
                            Label(
                                AppLocalization.format("tracking.subscriptions.open_remote_format", "Open %@", provider.title),
                                systemImage: "safari"
                            )
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .appCardStyle()
    }

    private var syncHintCard: some View {
        Text(AppLocalization.text(
            "tracking.subscription_detail.sync_hint",
            "Pull and two-way sync only apply to confirmed bindings. Local history is updated after ComicDeck loads the local chapter list."
        ))
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
    }

    private var unboundCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(AppLocalization.text("tracking.subscriptions.no_local_binding", "No confirmed local binding yet."))
                .font(.headline)
            addSourceBindingButton(prominent: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
    }

    private var bindingsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .center, spacing: AppSpacing.sm) {
                Text(AppLocalization.text("tracking.subscription_detail.bindings", "Confirmed bindings"))
                    .font(.headline)
                Spacer(minLength: 0)
                addSourceBindingButton(prominent: false)
            }

            ForEach(localGroups) { group in
                bindingGroupCard(group)
            }
        }
    }

    private var defaultBindingSourceKey: String? {
        if !sourceManager.selectedSourceKey.isEmpty {
            return sourceManager.selectedSourceKey
        }
        return sourceManager.installedSources.first?.key
    }

    @ViewBuilder
    private func addSourceBindingButton(prominent: Bool) -> some View {
        if let sourceKey = defaultBindingSourceKey {
            if prominent {
                Button {
                    sourceSearchRoute = TrackerSourceSearchRoute(
                        sourceKey: sourceKey,
                        keyword: row.entry.title
                    )
                } label: {
                    addSourceBindingLabel
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    sourceSearchRoute = TrackerSourceSearchRoute(
                        sourceKey: sourceKey,
                        keyword: row.entry.title
                    )
                } label: {
                    addSourceBindingLabel
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var addSourceBindingLabel: some View {
        Label(
            AppLocalization.text("tracking.source_binding.add_source_binding", "Add source binding"),
            systemImage: "link.badge.plus"
        )
    }

    private func bindingGroupCard(_ group: TrackerSubscriptionLocalGroup) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                CoverArtworkView(urlString: group.coverURL, width: 64, height: 92)
                    .frame(width: 64, height: 92)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(group.sourceKey) · \(group.comicID)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let history = library.latestHistoryForComic(sourceKey: group.sourceKey, comicID: group.comicID) {
                        Text(localHistoryText(history))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: AppSpacing.sm) {
                    ForEach(group.bindings.values.sorted { $0.provider.title < $1.provider.title }) { binding in
                        bindingColumn(binding)
                    }
                }
            }

            actionButtons(for: group)
        }
        .padding(AppSpacing.md)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppSurface.border, lineWidth: 1)
        )
    }

    private func actionButtons(for group: TrackerSubscriptionLocalGroup) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if group.bindings[provider] != nil {
                syncMenu(for: group)
            }

            NavigationLink {
                ComicDetailRoutingView(
                    vm: vm,
                    item: ComicSummary(
                        id: group.comicID,
                        sourceKey: group.sourceKey,
                        title: group.title,
                        coverURL: group.coverURL
                    )
                )
                .environment(library)
            } label: {
                Label(
                    AppLocalization.text("tracking.subscriptions.open_local_comic", "Open local comic"),
                    systemImage: "book"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private func bindingColumn(_ binding: TrackerBinding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(binding.provider.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTint.accent)
            Text(binding.remoteTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(providerProgressText(binding))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 160, alignment: .leading)
        .padding(AppSpacing.sm)
        .background(AppSurface.subtle, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func syncMenu(for group: TrackerSubscriptionLocalGroup) -> some View {
        HStack(spacing: AppSpacing.sm) {
            Button {
                Task { await sync(group, direction: tracker.manualSyncDefaultDirection) }
            } label: {
                Label(
                    model.syncingGroupID == group.id ? AppLocalization.text("tracking.sync.syncing", "Syncing...") : syncDirectionTitle(tracker.manualSyncDefaultDirection),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Menu {
                Button(syncDirectionTitle(.localToRemote)) {
                    Task { await sync(group, direction: .localToRemote) }
                }
                Button(syncDirectionTitle(.remoteToLocal)) {
                    Task { await sync(group, direction: .remoteToLocal) }
                }
                Button(syncDirectionTitle(.bidirectional)) {
                    Task { await sync(group, direction: .bidirectional) }
                }
                Button(AppLocalization.text("tracking.unlink", "Unlink"), role: .destructive) {
                    Task { await unlink(group) }
                }
            } label: {
                Label(AppLocalization.text("tracking.sync.more", "More"), systemImage: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(AppLocalization.text("tracking.sync.more_actions", "More sync actions"))
        }
        .disabled(model.syncingGroupID != nil)
    }

    private func bindSourceComic(_ item: ComicSummary) async -> Bool {
        await model.bind(item: item, entry: row.entry, provider: provider, tracker: tracker)
    }

    private func sync(_ group: TrackerSubscriptionLocalGroup, direction: TrackerSyncDirection) async {
        await model.sync(
            group: group,
            provider: provider,
            direction: direction,
            vm: vm,
            tracker: tracker,
            library: library
        )
    }

    private func unlink(_ group: TrackerSubscriptionLocalGroup) async {
        await model.unlink(group: group, provider: provider, tracker: tracker)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AppTint.warning)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.sm)
        .background(AppTint.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func remoteProgressText(_ entry: TrackerListEntry) -> String {
        let status = entry.status.map(statusTitle) ?? AppLocalization.text("tracking.subscriptions.status.unknown", "Unknown")
        if let chapterCount = entry.chapterCount {
            return AppLocalization.format(
                "tracking.subscriptions.progress_with_status_format",
                "%@ • %@/%@",
                status,
                String(entry.progress),
                String(chapterCount)
            )
        }
        return AppLocalization.format(
            "tracking.subscriptions.progress_count_with_status_format",
            "%@ • %@",
            status,
            String(entry.progress)
        )
    }

    private func providerProgressText(_ binding: TrackerBinding) -> String {
        let status = binding.lastSyncedStatus.map(statusTitle)
        if let status {
            return AppLocalization.format(
                "tracking.subscriptions.provider_status_progress_format",
                "%@ · %@ · %@",
                binding.provider.title,
                status,
                String(binding.lastSyncedProgress)
            )
        }
        return AppLocalization.format(
            "tracking.subscriptions.provider_progress_format",
            "%@ · %@",
            binding.provider.title,
            String(binding.lastSyncedProgress)
        )
    }

    private func syncDirectionTitle(_ direction: TrackerSyncDirection) -> String {
        switch direction {
        case .localToRemote:
            return AppLocalization.text("tracking.sync.direction.local_to_remote", "Push Local Progress")
        case .remoteToLocal:
            return AppLocalization.text("tracking.sync.direction.remote_to_local", "Pull Tracker Progress")
        case .bidirectional:
            return AppLocalization.text("tracking.sync.direction.bidirectional", "Two-way Sync")
        }
    }

    private func statusTitle(_ status: TrackerReadingStatus) -> String {
        switch status {
        case .current:
            return AppLocalization.text("tracking.status.current", "Current")
        case .completed:
            return AppLocalization.text("tracking.status.completed", "Completed")
        case .paused:
            return AppLocalization.text("tracking.status.paused", "Paused")
        case .planning:
            return AppLocalization.text("tracking.status.planning", "Planning")
        case .dropped:
            return AppLocalization.text("tracking.status.dropped", "Dropped")
        }
    }

    private func updatedText(_ timestamp: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let text = formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(timestamp)), relativeTo: Date())
        return AppLocalization.format("tracking.subscription_detail.updated_format", "Updated %@", text)
    }

    private func localHistoryText(_ history: ReadingHistoryItem) -> String {
        let chapter = history.chapter?.isEmpty == false ? (history.chapter ?? history.chapterID ?? "") : (history.chapterID ?? "")
        if chapter.isEmpty {
            return AppLocalization.format("tracking.subscription_detail.local_page_format", "Local page %@", String(history.page))
        }
        return AppLocalization.format(
            "tracking.subscription_detail.local_history_format",
            "%@ · page %@",
            chapter,
            String(history.page)
        )
    }
}

@MainActor
struct TrackerSourceBindingSearchSheet: View {
    @Bindable var vm: ReaderViewModel
    let provider: TrackerProvider
    let entry: TrackerListEntry
    let initialKeyword: String
    let onBind: (ComicSummary) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var didInitialSearch = false
    @State private var bindingComicID: String?
    @State private var errorText = ""
    @State private var selectedSourceKey: String
    @State private var model: SearchScreenModel

    init(
        vm: ReaderViewModel,
        provider: TrackerProvider,
        entry: TrackerListEntry,
        sourceKey: String,
        initialKeyword: String,
        onBind: @escaping (ComicSummary) async -> Bool
    ) {
        self.vm = vm
        self.provider = provider
        self.entry = entry
        self.initialKeyword = initialKeyword
        self.onBind = onBind
        _selectedSourceKey = State(initialValue: sourceKey)
        let model = SearchScreenModel()
        model.keyword = initialKeyword
        _model = State(initialValue: model)
    }

    private var sourceTitle: String {
        vm.sourceManager.installedSources.first(where: { $0.key == selectedSourceKey })?.name ?? selectedSourceKey
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    headerCard

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(AppTint.warning)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AppSpacing.sm)
                            .background(AppTint.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                    }

                    if model.results.isEmpty {
                        emptyState
                    } else {
                        resultsSection
                    }
                }
                .padding(.horizontal, AppSpacing.screen)
                .padding(.vertical, AppSpacing.md)
            }
            .background(AppSurface.grouped.ignoresSafeArea())
            .navigationTitle(AppLocalization.text("tracking.source_binding.title", "Bind Source"))
            .platformNavigationBarTitleDisplayModeInline()
            .searchable(
                text: Binding(
                    get: { model.keyword },
                    set: { model.keyword = $0 }
                ),
                prompt: AppLocalization.text("tracking.source_binding.search_prompt", "Search keyword")
            )
            .onSubmit(of: .search) {
                Task { await search(model.keyword) }
            }
            .onChange(of: selectedSourceKey) { _, _ in
                model.results = []
                Task { await search(model.keyword) }
            }
            .toolbar {
                ToolbarItem(placement: .platformTopBarLeading) {
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button(AppLocalization.text("common.done", "Done")) { dismiss() }
                }
            }
            .task {
                if selectedSourceKey.isEmpty {
                    selectedSourceKey = vm.sourceManager.installedSources.first?.key ?? ""
                }
                guard !didInitialSearch else { return }
                didInitialSearch = true
                await search(initialKeyword)
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(AppLocalization.format(
                "tracking.source_binding.header_format",
                "Bind a %@ result from %@ to this %@ entry.",
                sourceTitle,
                selectedSourceKey,
                provider.title
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(entry.title)
                .font(.headline)
            sourcePicker
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
    }

    @ViewBuilder
    private var sourcePicker: some View {
        if vm.sourceManager.installedSources.isEmpty {
            Text(AppLocalization.text("tracking.source_binding.no_sources", "No source installed."))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker(
                AppLocalization.text("tracking.source_binding.source_picker", "Search source"),
                selection: $selectedSourceKey
            ) {
                ForEach(vm.sourceManager.installedSources) { source in
                    Text(source.name).tag(source.key)
                }
            }
            .pickerStyle(.menu)
        }
    }

    private var emptyState: some View {
        Text(model.isSearching ? AppLocalization.text("tracking.source_binding.searching", "Searching...") : AppLocalization.text("tracking.source_binding.empty", "No source results yet."))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .appCardStyle()
    }

    private var resultsSection: some View {
        LazyVStack(spacing: AppSpacing.md) {
            ForEach(model.results) { item in
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    SearchResultCard(item: item)
                    Button {
                        Task { await bind(item) }
                    } label: {
                        Label(
                            bindingComicID == item.id ? AppLocalization.text("tracking.source_binding.binding", "Binding...") : AppLocalization.text("tracking.source_binding.bind_action", "Bind to tracker"),
                            systemImage: "link.badge.plus"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bindingComicID != nil)
                }
            }
        }
    }

    private func search(_ text: String) async {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        model.keyword = keyword
        errorText = ""
        do {
            let configuration = try await vm.loadSearchConfiguration(sourceKey: selectedSourceKey)
            await model.performSearch(
                using: vm,
                sourceKey: selectedSourceKey,
                options: configuration.options,
                profile: configuration.profile,
                append: false,
                trigger: .keyword
            )
        } catch {
            errorText = error.localizedDescription
            model.results = []
        }
    }

    private func bind(_ item: ComicSummary) async {
        bindingComicID = item.id
        errorText = ""
        let didBind = await onBind(item)
        bindingComicID = nil
        if didBind {
            dismiss()
        } else {
            errorText = AppLocalization.text("tracking.source_binding.failed", "Could not bind this source result.")
        }
    }
}
