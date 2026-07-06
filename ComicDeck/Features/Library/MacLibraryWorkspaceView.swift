#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct MacLibraryWorkspaceView: View {
    enum SidebarItem: Hashable, Identifiable {
        case overview
        case bookmarks
        case shelves
        case favorites
        case history
        case tracking(TrackerProvider)
        case downloads

        var id: String {
            switch self {
            case .overview:
                return "overview"
            case .bookmarks:
                return "bookmarks"
            case .shelves:
                return "shelves"
            case .favorites:
                return "favorites"
            case .history:
                return "history"
            case .tracking(let provider):
                return "tracking.\(provider.rawValue)"
            case .downloads:
                return "downloads"
            }
        }

        var title: String {
            switch self {
            case .overview:
                return AppLocalization.text("library.mac.overview", "Overview")
            case .bookmarks:
                return AppLocalization.text("library.workspace.bookmarks.title", "Bookmarks")
            case .shelves:
                return AppLocalization.text("library.shelves.shelves", "Shelves")
            case .favorites:
                return AppLocalization.text("library.workspace.favorites.title", "Favorites")
            case .history:
                return AppLocalization.text("library.workspace.history.title", "History")
            case .tracking(let provider):
                return AppLocalization.format("library.workspace.tracker.title_format", "%@ Library", provider.title)
            case .downloads:
                return AppLocalization.text("library.workspace.downloads.title", "Downloads")
            }
        }

        var systemImage: String {
            switch self {
            case .overview:
                return "rectangle.grid.2x2"
            case .bookmarks:
                return "bookmark"
            case .shelves:
                return "books.vertical"
            case .favorites:
                return "heart.text.square"
            case .history:
                return "clock.arrow.circlepath"
            case .tracking:
                return "rectangle.stack.badge.person.crop"
            case .downloads:
                return "arrow.down.circle"
            }
        }
    }

    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @Environment(LibraryViewModel.self) private var library
    @Environment(TrackerViewModel.self) private var tracker
    @State private var selection: SidebarItem? = .overview

    let onTagSearchRequested: (String, String) -> Void

    var body: some View {
        let snapshot = LibraryOverviewSnapshot(
            history: library.history,
            offlineChapters: library.offlineChapters,
            historyLimit: 0,
            offlineLimit: 0
        )
        HStack(spacing: 0) {
            sidebar(readyOfflineCount: snapshot.readyOfflineCount)
                .frame(width: 260)

            Divider()

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(AppLocalization.text("library.navigation.title", "Library"))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func sidebar(readyOfflineCount: Int) -> some View {
        List(selection: $selection) {
            Section {
                sidebarRow(.overview, badge: nil)
                    .tag(SidebarItem.overview)
            }

            Section(AppLocalization.text("library.mac.local_section", "Local Library")) {
                sidebarRow(.bookmarks, badge: library.favorites.count)
                    .tag(SidebarItem.bookmarks)
                sidebarRow(.shelves, badge: library.favoriteCategories.count)
                    .tag(SidebarItem.shelves)
                sidebarRow(.history, badge: library.history.count)
                    .tag(SidebarItem.history)
                sidebarRow(.downloads, badge: readyOfflineCount)
                    .tag(SidebarItem.downloads)
            }

            Section(AppLocalization.text("library.mac.source_section", "Source Library")) {
                sidebarRow(.favorites, badge: nil)
                    .tag(SidebarItem.favorites)
            }

            Section(AppLocalization.text("library.mac.tracker_section", "Tracker Libraries")) {
                ForEach(TrackerProvider.mangaListWorkspaceProviders) { provider in
                    let item = SidebarItem.tracking(provider)
                    sidebarRow(item, badge: nil, subtitle: tracker.account(for: provider)?.displayName)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ item: SidebarItem, badge: Int?, subtitle: String? = nil) -> some View {
        Label {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if let badge {
                    Text(String(badge))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: item.systemImage)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection ?? .overview {
        case .overview:
            NavigationStack {
                MacLibraryOverviewView(
                    vm: vm,
                    sourceManager: sourceManager,
                    onSelect: { selection = $0 },
                    onTagSearchRequested: onTagSearchRequested
                )
                .environment(library)
                .environment(tracker)
            }
        case .bookmarks:
            NavigationStack {
                LibraryBookmarksView(vm: vm, onTagSearchRequested: onTagSearchRequested)
                    .environment(library)
            }
        case .shelves:
            NavigationStack {
                BookmarkShelvesView(vm: vm, onTagSearchRequested: onTagSearchRequested)
                    .environment(library)
            }
        case .favorites:
            NavigationStack {
                FavoritesView(vm: vm, sourceManager: sourceManager, onTagSearchRequested: onTagSearchRequested)
                    .environment(library)
            }
        case .history:
            NavigationStack {
                HistoryView(vm: vm, onTagSearchRequested: onTagSearchRequested)
                    .environment(library)
            }
        case .tracking(let provider):
            NavigationStack {
                TrackerSubscriptionsView(vm: vm, sourceManager: sourceManager, provider: provider)
                    .environment(library)
                    .environment(tracker)
            }
        case .downloads:
            NavigationStack {
                MacDownloadWorkspaceView(vm: vm)
                    .environment(library)
            }
        }
    }

}

@MainActor
private struct MacLibraryOverviewView: View {
    private enum OverviewSelection: Hashable {
        case history(ReadingHistoryItem.ID)
        case offline(OfflineChapterAsset.ID)
    }

    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @Environment(LibraryViewModel.self) private var library
    @Environment(TrackerViewModel.self) private var tracker

    let onSelect: (MacLibraryWorkspaceView.SidebarItem) -> Void
    let onTagSearchRequested: (String, String) -> Void

    @State private var selectedDetailItem: ComicSummary?
    @State private var pendingDetailReadRoute: ReaderLaunchContext?
    @State private var selection: OverviewSelection?
    @State private var selectionCommandController = MacSelectionCommandController()

    private var overviewSnapshot: LibraryOverviewSnapshot {
        LibraryOverviewSnapshot(
            history: library.history,
            offlineChapters: library.offlineChapters,
            historyLimit: 8,
            offlineLimit: 6
        )
    }

    var body: some View {
        let snapshot = overviewSnapshot
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                metricsGrid(readyOfflineCount: snapshot.readyOfflineCount)
                recentReadingSection(recentHistory: snapshot.recentHistory)
                offlineSection(recentOfflineChapters: snapshot.recentOfflineChapters)
            }
            .padding(AppSpacing.screen)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle(AppLocalization.text("library.mac.overview", "Overview"))
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailRoutingView(
                vm: vm,
                item: item,
                onTagSelected: onTagSearchRequested,
                initialReadRoute: pendingDetailReadRoute,
                onConsumeInitialReadRoute: { pendingDetailReadRoute = nil },
                onNavigateBack: { selectedDetailItem = nil }
            )
        }
        .onAppear {
            reconcileSelection()
            configureSelectionCommands()
        }
        .onChange(of: recentHistoryIDs) { _, _ in
            reconcileSelection()
            configureSelectionCommands()
        }
        .onChange(of: recentOfflineChapterIDs) { _, _ in
            reconcileSelection()
            configureSelectionCommands()
        }
        .onChange(of: selection) { _, _ in
            configureSelectionCommands()
        }
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
    }

    private var recentHistoryIDs: [ReadingHistoryItem.ID] {
        overviewSnapshot.recentHistoryIDs
    }

    private var recentOfflineChapterIDs: [OfflineChapterAsset.ID] {
        overviewSnapshot.recentOfflineChapterIDs
    }

    private var selectedHistoryItem: ReadingHistoryItem? {
        guard case .history(let id) = selection else { return nil }
        return overviewSnapshot.recentHistory.first { $0.id == id }
    }

    private var selectedOfflineChapter: OfflineChapterAsset? {
        guard case .offline(let id) = selection else { return nil }
        return overviewSnapshot.recentOfflineChapters.first { $0.id == id }
    }

    private var overviewColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: 220, maximum: 360),
                spacing: AppSpacing.md,
                alignment: .top
            )
        ]
    }

    private var offlineColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: 260, maximum: 420),
                spacing: AppSpacing.md,
                alignment: .top
            )
        ]
    }

    private func metricsGrid(readyOfflineCount: Int) -> some View {
        LazyVGrid(
            columns: overviewColumns,
            spacing: AppSpacing.md
        ) {
            overviewMetric(
                title: AppLocalization.text("library.workspace.bookmarks.title", "Bookmarks"),
                value: String(library.favorites.count),
                subtitle: AppLocalization.text("library.workspace.bookmarks.subtitle", "Your local reading list and shelf organization"),
                systemImage: "bookmark",
                tint: AppTint.success,
                action: { onSelect(.bookmarks) }
            )
            overviewMetric(
                title: AppLocalization.text("library.shelves.shelves", "Shelves"),
                value: String(library.favoriteCategories.count),
                subtitle: AppLocalization.text("library.mac.shelves_subtitle", "Organize saved comics for desktop browsing"),
                systemImage: "books.vertical",
                tint: AppTint.accent,
                action: { onSelect(.shelves) }
            )
            overviewMetric(
                title: AppLocalization.text("library.workspace.history.title", "History"),
                value: String(library.history.count),
                subtitle: AppLocalization.text("library.workspace.history.subtitle", "Resume chapters and manage reading history"),
                systemImage: "clock.arrow.circlepath",
                tint: AppTint.warning,
                action: { onSelect(.history) }
            )
            overviewMetric(
                title: AppLocalization.text("library.workspace.downloads.title", "Downloads"),
                value: String(readyOfflineCount),
                subtitle: AppLocalization.text("library.workspace.downloads.subtitle", "Queue, offline library, and storage cleanup"),
                systemImage: "arrow.down.circle",
                tint: AppTint.accent,
                action: { onSelect(.downloads) }
            )
            overviewMetric(
                title: AppLocalization.text("library.workspace.favorites.title", "Favorites"),
                value: sourceManager.selectedSourceKey.isEmpty ? AppLocalization.text("library.workspace.favorites.source", "Source") : sourceManager.selectedSourceKey,
                subtitle: AppLocalization.text("library.workspace.favorites.subtitle", "Source-side favorites and folders"),
                systemImage: "heart.text.square",
                tint: AppTint.warning,
                action: { onSelect(.favorites) }
            )
            overviewMetric(
                title: AppLocalization.text("library.mac.tracker_accounts", "Tracker Accounts"),
                value: String(connectedTrackerCount),
                subtitle: AppLocalization.text("library.workspace.tracker.subtitle", "View manga and local progress bindings"),
                systemImage: "rectangle.stack.badge.person.crop",
                tint: AppTint.success,
                action: {
                    onSelect(.tracking(.defaultMangaListWorkspaceProvider))
                }
            )
        }
    }

    private var connectedTrackerCount: Int {
        TrackerProvider.allCases.reduce(into: 0) { count, provider in
            if tracker.account(for: provider) != nil {
                count += 1
            }
        }
    }

    private func overviewMetric(
        title: String,
        value: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(tint)
                    Spacer()
                    Text(value)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(minHeight: 32, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .padding(AppSpacing.md)
            .background(AppSurface.card, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .stroke(AppSurface.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func recentReadingSection(recentHistory: [ReadingHistoryItem]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader(
                title: AppLocalization.text("library.recent.title", "Recent Activity"),
                actionTitle: AppLocalization.text("library.workspace.history.title", "History"),
                action: { onSelect(.history) }
            )

            if recentHistory.isEmpty {
                ContentUnavailableView(
                    AppLocalization.text("library.recent.empty_title", "No recent reading"),
                    systemImage: "clock",
                    description: Text(AppLocalization.text("library.recent.empty", "Your reading history will appear here after you open a chapter."))
                )
                .frame(minHeight: 180)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentHistory, id: \.id) { item in
                        Button {
                            openRecentReading(item)
                        } label: {
                            MacLibraryHistoryRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(AppLocalization.text("history.action.resume", "Resume"), systemImage: "play.fill") {
                                openRecentReading(item)
                            }
                            Button(AppLocalization.text("common.open", "Open"), systemImage: "book") {
                                openHistoryDetail(item)
                            }
                            Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
                                copyHistoryTitle(item)
                            }
                            Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
                                copyHistoryID(item)
                            }
                            Button(AppLocalization.text("search.action.copy_source", "Copy Source"), systemImage: "shippingbox") {
                                copyHistorySource(item)
                            }
                        }

                        if item.id != recentHistory.last?.id {
                            Divider()
                                .padding(.leading, 58)
                        }
                    }
                }
                .background(AppSurface.card, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .stroke(AppSurface.border, lineWidth: 1)
                }
            }
        }
    }

    private func offlineSection(recentOfflineChapters: [OfflineChapterAsset]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader(
                title: AppLocalization.text("library.offline_ready.title", "Offline Ready"),
                actionTitle: AppLocalization.text("library.workspace.downloads.title", "Downloads"),
                action: { onSelect(.downloads) }
            )

            if recentOfflineChapters.isEmpty {
                ContentUnavailableView(
                    AppLocalization.text("downloads.empty.no_offline", "No offline chapters"),
                    systemImage: "arrow.down.circle",
                    description: Text(AppLocalization.text("downloads.empty.no_offline_hint", "Downloaded chapters will appear here after indexing."))
                )
                .frame(minHeight: 160)
            } else {
                LazyVGrid(
                    columns: offlineColumns,
                    spacing: AppSpacing.md
                ) {
                    ForEach(recentOfflineChapters) { item in
                        MacLibraryOfflineTile(item: item) { openOfflineChapter(item) }
                        .onDrag {
                            selection = .offline(item.id)
                            return offlineDirectoryItemProvider(item)
                        }
                        .contextMenu {
                            offlineContextMenu(for: item)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            Button(actionTitle, action: action)
                .font(.subheadline.weight(.semibold))
        }
    }

    private func openRecentReading(_ item: ReadingHistoryItem) {
        selection = .history(item.id)
        guard let context = ReaderLaunchContext.fromHistory(item, using: library) else {
            openHistoryDetail(item)
            return
        }
        pendingDetailReadRoute = context
        selectedDetailItem = context.item
    }

    private func openHistoryDetail(_ item: ReadingHistoryItem) {
        selection = .history(item.id)
        pendingDetailReadRoute = nil
        selectedDetailItem = ComicSummary(
            id: item.comicID,
            sourceKey: item.sourceKey,
            title: item.title,
            coverURL: item.coverURL,
            author: item.author,
            tags: item.tags
        )
    }

    private func openOfflineChapter(_ item: OfflineChapterAsset) {
        selection = .offline(item.id)
        let chapterSequence = OfflineChapterSequenceBuilder.sequence(for: item, in: library.offlineChapters)

        pendingDetailReadRoute = ReaderLaunchContext(
            item: ComicSummary(
                id: item.comicID,
                sourceKey: item.sourceKey,
                title: item.comicTitle,
                coverURL: item.coverURL
            ),
            chapterID: item.chapterID,
            chapterTitle: item.chapterTitle,
            localDirectory: item.directoryPath,
            initialPage: 1,
            chapterSequence: chapterSequence
        )
        selectedDetailItem = pendingDetailReadRoute?.item
    }

    @ViewBuilder
    private func offlineContextMenu(for item: OfflineChapterAsset) -> some View {
        Button(AppLocalization.text("history.action.resume", "Resume"), systemImage: "play.fill") {
            openOfflineChapter(item)
        }
        Button(AppLocalization.text("downloads.action.reveal_in_finder", "Reveal in Finder"), systemImage: "folder") {
            revealOfflineChapter(item)
        }
        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyOfflineTitle(item)
        }
        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyOfflineID(item)
        }
        Button(AppLocalization.text("downloads.action.copy_path", "Copy Path"), systemImage: "doc.on.clipboard") {
            copyOfflinePath(item)
        }
    }

    private func copyHistoryTitle(_ item: ReadingHistoryItem) {
        selection = .history(item.id)
        PlatformPasteboard.copy(item.title)
    }

    private func copyHistoryID(_ item: ReadingHistoryItem) {
        selection = .history(item.id)
        PlatformPasteboard.copy(item.comicID)
    }

    private func copyHistorySource(_ item: ReadingHistoryItem) {
        selection = .history(item.id)
        PlatformPasteboard.copy(item.sourceKey)
    }

    private func revealOfflineChapter(_ item: OfflineChapterAsset) {
        selection = .offline(item.id)
        PlatformFileActions.revealDirectory(path: item.directoryPath)
    }

    private func copyOfflineTitle(_ item: OfflineChapterAsset) {
        selection = .offline(item.id)
        PlatformPasteboard.copy(item.comicTitle)
    }

    private func copyOfflineID(_ item: OfflineChapterAsset) {
        selection = .offline(item.id)
        PlatformPasteboard.copy(item.comicID)
    }

    private func copyOfflinePath(_ item: OfflineChapterAsset) {
        selection = .offline(item.id)
        PlatformPasteboard.copy(item.directoryPath)
    }

    private func offlineDirectoryItemProvider(_ item: OfflineChapterAsset) -> NSItemProvider {
        let url = URL(fileURLWithPath: item.directoryPath, isDirectory: true)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }
        provider.suggestedName = url.lastPathComponent
        return provider
    }

    private func reconcileSelection() {
        let snapshot = overviewSnapshot
        switch selection {
        case .history(let id) where snapshot.recentHistoryIDs.contains(id):
            return
        case .offline(let id) where snapshot.recentOfflineChapterIDs.contains(id):
            return
        default:
            if let firstHistory = snapshot.recentHistory.first {
                selection = .history(firstHistory.id)
            } else if let firstOfflineChapter = snapshot.recentOfflineChapters.first {
                selection = .offline(firstOfflineChapter.id)
            } else {
                selection = nil
            }
        }
    }

    private func configureSelectionCommands() {
        selectionCommandController.reset()

        if let item = selectedHistoryItem {
            selectionCommandController.open = { openRecentReading(item) }
            selectionCommandController.copyTitle = { copyHistoryTitle(item) }
            selectionCommandController.copyID = { copyHistoryID(item) }
            selectionCommandController.export = { copyHistorySource(item) }
            selectionCommandController.openTitle = AppLocalization.text("history.action.resume", "Resume")
            selectionCommandController.exportTitle = AppLocalization.text("search.action.copy_source", "Copy Source")
            selectionCommandController.canOpen = true
            selectionCommandController.canCopyTitle = true
            selectionCommandController.canCopyID = true
            selectionCommandController.canExport = true
        } else if let item = selectedOfflineChapter {
            selectionCommandController.open = { openOfflineChapter(item) }
            selectionCommandController.copyTitle = { copyOfflineTitle(item) }
            selectionCommandController.copyID = { copyOfflineID(item) }
            selectionCommandController.reveal = { revealOfflineChapter(item) }
            selectionCommandController.export = { copyOfflinePath(item) }
            selectionCommandController.openTitle = AppLocalization.text("history.action.resume", "Resume")
            selectionCommandController.exportTitle = AppLocalization.text("downloads.action.copy_path", "Copy Path")
            selectionCommandController.canOpen = true
            selectionCommandController.canCopyTitle = true
            selectionCommandController.canCopyID = true
            selectionCommandController.canReveal = true
            selectionCommandController.canExport = true
        }
    }
}

private struct MacLibraryHistoryRow: View {
    let item: ReadingHistoryItem

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            CoverArtworkView(urlString: item.coverURL, refererURLString: item.comicID, width: 42, height: 58)
                .frame(width: 42, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(updatedText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 8)
    }

    private var subtitle: String {
        let chapter = item.chapter?.isEmpty == false
            ? item.chapter!
            : AppLocalization.format("library.recent.page", "Page %@", String(item.page))
        return "\(chapter) · \(item.sourceKey)"
    }

    private var updatedText: String {
        RelativeTimeText.short(for: item.updatedAt)
    }
}

private struct MacLibraryOfflineTile: View {
    let item: OfflineChapterAsset
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                CoverArtworkView(urlString: item.coverURL, refererURLString: item.comicID, width: 54, height: 76)
                    .frame(width: 54, height: 76)

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.comicTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(item.chapterTitle.isEmpty ? item.chapterID : item.chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Label(
                        AppLocalization.format("library.offline_ready.pages_count", "%d pages", item.pageCount),
                        systemImage: "photo.stack"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .padding(AppSpacing.md)
            .background(AppSurface.card, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .stroke(AppSurface.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}
#endif
