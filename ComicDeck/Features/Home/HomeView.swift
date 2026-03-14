import SwiftUI
import Observation

@MainActor
@Observable
final class HomeScreenModel {
    func formatReadingDuration(_ seconds: TimeInterval) -> String {
        let roundedSeconds = max(0, Int(seconds.rounded()))
        let hours = roundedSeconds / 3600
        let minutes = (roundedSeconds % 3600) / 60

        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return roundedSeconds > 0 ? "<1m" : "0m"
    }

    func relativeText(for timestamp: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(timestamp)), relativeTo: Date())
    }

    func activeSourceSubtitle(using sourceManager: SourceManagerViewModel) -> String {
        sourceManager.selectedSource?.name ?? AppLocalization.text("home.source.select", "Select a source")
    }
}

@MainActor
struct HomeView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @Environment(LibraryViewModel.self) private var library

    let onOpenSearch: () -> Void
    let onOpenSettings: () -> Void
    let onOpenDiscover: () -> Void
    let onOpenLibrary: () -> Void
    let onTagSearchRequested: (String, String) -> Void

    @State private var model = HomeScreenModel()
    @State private var selectedDetailItem: ComicSummary?
    @State private var pendingDetailReadRoute: ReaderLaunchContext?

    private var latestHistory: ReadingHistoryItem? {
        library.history.first
    }

    private var recentHistory: [ReadingHistoryItem] {
        Array(library.history.prefix(8))
    }

    private var completedDownloadsCount: Int {
        library.offlineChapters.lazy.filter { $0.integrityStatus == .complete }.count
    }

    private var latestOfflineItem: OfflineChapterAsset? {
        library.offlineChapters
            .filter { $0.integrityStatus == .complete }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.downloadedAt > $1.downloadedAt
            }
            .first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    searchEntryCard
                    continueReadingSection
                    homeStatusSection
                    quickActionsSection
                    if let latestOfflineItem {
                        offlineSpotlightSection(latestOfflineItem)
                    }
                    recentReadingSection
                }
                .padding(.horizontal, AppSpacing.screen)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.xl)
            }
            .background(
                LinearGradient(
                    colors: [
                        AppSurface.grouped,
                        AppSurface.background.opacity(0.7)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            .navigationTitle(AppLocalization.text("home.navigation.title", "Home"))
            .navigationDestination(item: $selectedDetailItem) { item in
                ComicDetailView(
                    vm: vm,
                    item: item,
                    onTagSelected: onTagSearchRequested,
                    initialReadRoute: pendingDetailReadRoute,
                    onConsumeInitialReadRoute: { pendingDetailReadRoute = nil }
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(AppLocalization.text("home.action.settings", "Open settings"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSearch) {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel(AppLocalization.text("home.action.search", "Open search"))
                }
            }
        }
    }

    private var searchEntryCard: some View {
        Button(action: onOpenSearch) {
            HStack(spacing: AppSpacing.md) {
                Image(systemName: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(AppTint.accent)
                    .frame(width: 38, height: 38)
                    .background(AppTint.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.text("home.search.title", "Search Comics"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(AppLocalization.text("home.search.subtitle", "Jump straight to titles, authors, and tags."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .appCardStyle()
        }
        .buttonStyle(.plain)
    }

    private var continueReadingSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AppLocalization.text("home.continue.title", "Continue Reading"))
                .font(.title3.weight(.semibold))

            if let latestHistory {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        CoverArtworkView(urlString: latestHistory.coverURL, width: 92, height: 132)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(latestHistory.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            Text(latestHistory.author?.isEmpty == false ? latestHistory.author! : latestHistory.sourceKey)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if let chapter = latestHistory.chapter, !chapter.isEmpty {
                                Label(chapter, systemImage: "book.closed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Text(
                                AppLocalization.format(
                                    "home.continue.page_updated",
                                    "Page %@ • Updated %@",
                                    String(latestHistory.page),
                                    model.relativeText(for: latestHistory.updatedAt)
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                    }

                    HStack(spacing: AppSpacing.md) {
                        metricCard(
                            title: AppLocalization.text("home.metric.today", "Today"),
                            value: model.formatReadingDuration(library.todayReadingDurationSeconds),
                            subtitle: AppLocalization.text("home.metric.reading_time", "Reading time"),
                            tint: AppTint.accent
                        )

                        metricCard(
                            title: AppLocalization.text("home.metric.library", "Library"),
                            value: "\(library.favorites.count)",
                            subtitle: AppLocalization.text("home.metric.bookmarks", "Bookmarks"),
                            tint: AppTint.success
                        )
                    }

                    HStack(spacing: AppSpacing.sm) {
                        Button {
                            openRecentReading(latestHistory)
                        } label: {
                            actionChip(title: AppLocalization.text("home.action.resume", "Resume"), systemImage: "play.fill", prominent: true)
                        }
                        .buttonStyle(.plain)

                        Button(action: onOpenLibrary) {
                            actionChip(title: AppLocalization.text("home.action.library", "Library"), systemImage: "books.vertical", prominent: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .appCardStyle()
            } else {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    Text(AppLocalization.text("home.empty.title", "No reading session yet"))
                        .font(.headline)
                    Text(AppLocalization.text("home.empty.subtitle", "Start from Discover or Search, then Home will surface your current comic and today's reading time."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: AppSpacing.md) {
                        metricCard(
                            title: AppLocalization.text("home.metric.today", "Today"),
                            value: model.formatReadingDuration(library.todayReadingDurationSeconds),
                            subtitle: AppLocalization.text("home.metric.reading_time", "Reading time"),
                            tint: AppTint.accent
                        )

                        metricCard(
                            title: AppLocalization.text("home.metric.installed", "Installed"),
                            value: "\(sourceManager.installedSources.count)",
                            subtitle: AppLocalization.text("home.metric.sources", "Sources"),
                            tint: AppTint.warning
                        )
                    }

                    HStack(spacing: AppSpacing.sm) {
                        Button(action: onOpenDiscover) {
                            actionChip(title: AppLocalization.text("home.action.browse_discover", "Browse Discover"), systemImage: "sparkles", prominent: true)
                        }
                        .buttonStyle(.plain)

                        Button(action: onOpenSearch) {
                            actionChip(title: AppLocalization.text("home.action.search_short", "Search"), systemImage: "magnifyingglass", prominent: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .appCardStyle()
            }
        }
    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AppLocalization.text("home.quick_actions.title", "Quick Actions"))
                .font(.title3.weight(.semibold))

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: AppSpacing.md),
                    GridItem(.flexible(), spacing: AppSpacing.md)
                ],
                spacing: AppSpacing.md
            ) {
                Button(action: onOpenDiscover) {
                    quickActionCard(
                        title: AppLocalization.text("home.quick.discover.title", "Discover"),
                        subtitle: AppLocalization.text("home.quick.discover.subtitle", "Browse active sources"),
                        value: sourceManager.selectedSource?.name ?? AppLocalization.text("home.quick.discover.none", "No source"),
                        systemImage: "sparkles.rectangle.stack",
                        tint: AppTint.accent
                    )
                }
                .buttonStyle(.plain)

                Button(action: onOpenLibrary) {
                    quickActionCard(
                        title: AppLocalization.text("home.quick.library.title", "Library"),
                        subtitle: AppLocalization.text("home.quick.library.subtitle", "Bookmarks, shelves, history"),
                        value: "\(library.favorites.count)",
                        systemImage: "books.vertical",
                        tint: AppTint.success
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    HistoryView(vm: vm, onTagSearchRequested: onTagSearchRequested)
                } label: {
                    quickActionCard(
                        title: AppLocalization.text("home.quick.history.title", "History"),
                        subtitle: AppLocalization.text("home.quick.history.subtitle", "Resume recent reads"),
                        value: "\(library.history.count)",
                        systemImage: "clock.arrow.circlepath",
                        tint: AppTint.warning
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    DownloadManagerView(vm: vm)
                } label: {
                    quickActionCard(
                        title: AppLocalization.text("home.quick.downloads.title", "Downloads"),
                        subtitle: AppLocalization.text("home.quick.downloads.subtitle", "Offline chapters"),
                        value: "\(completedDownloadsCount)",
                        systemImage: "arrow.down.circle",
                        tint: AppTint.accent
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    SourceManagementView(vm: vm, sourceManager: sourceManager)
                } label: {
                    quickActionCard(
                        title: AppLocalization.text("home.quick.sources.title", "Sources"),
                        subtitle: AppLocalization.text("home.quick.sources.subtitle", "Installed and updates"),
                        value: "\(sourceManager.installedSources.count)",
                        systemImage: "tray.full",
                        tint: AppTint.warning
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var homeStatusSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AppLocalization.text("home.glance.title", "At a Glance"))
                .font(.title3.weight(.semibold))

            HStack(spacing: AppSpacing.md) {
                compactMetricCard(
                    title: AppLocalization.text("home.metric.today", "Today"),
                    value: model.formatReadingDuration(library.todayReadingDurationSeconds),
                    subtitle: AppLocalization.text("home.metric.reading", "Reading"),
                    tint: AppTint.accent
                )
                compactMetricCard(
                    title: AppLocalization.text("home.metric.offline", "Offline"),
                    value: "\(completedDownloadsCount)",
                    subtitle: AppLocalization.text("home.metric.ready", "Ready"),
                    tint: AppTint.success
                )
                compactMetricCard(
                    title: AppLocalization.text("home.metric.sources", "Sources"),
                    value: "\(sourceManager.installedSources.count)",
                    subtitle: AppLocalization.text("home.metric.installed", "Installed"),
                    tint: AppTint.warning
                )
            }

            HStack(spacing: AppSpacing.md) {
                sourceStatusCard
                librarySnapshotCard
            }
        }
    }

    private var sourceStatusCard: some View {
        Button(action: onOpenDiscover) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Label(AppLocalization.text("home.source.active", "Active Source"), systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.activeSourceSubtitle(using: sourceManager))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(sourceManager.selectedSourceKey.isEmpty ? AppLocalization.text("home.source.empty_hint", "Open Discover to choose a source.") : AppLocalization.text("home.source.browse_hint", "Browse fresh content from the current source."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCardStyle()
        }
        .buttonStyle(.plain)
    }

    private var librarySnapshotCard: some View {
        Button(action: onOpenLibrary) {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Label(AppLocalization.text("home.library_snapshot.title", "Library Snapshot"), systemImage: "books.vertical")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(
                    AppLocalization.format(
                        "home.library_snapshot.bookmarks",
                        "%@ bookmarks",
                        String(library.favorites.count)
                    )
                )
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(
                    AppLocalization.format(
                        "home.library_snapshot.subtitle",
                        "%@ shelves · %@ history records",
                        String(library.favoriteCategories.count),
                        String(library.history.count)
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .appCardStyle()
        }
        .buttonStyle(.plain)
    }

    private func offlineSpotlightSection(_ item: OfflineChapterAsset) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(AppLocalization.text("home.offline_spotlight.title", "Offline Spotlight"))
                    .font(.title3.weight(.semibold))
                Spacer()
                NavigationLink(AppLocalization.text("home.quick.downloads.title", "Downloads")) {
                    DownloadManagerView(vm: vm)
                }
                .font(.subheadline.weight(.semibold))
            }

            NavigationLink {
                ComicReaderView(
                    vm: vm,
                    item: ComicSummary(
                        id: item.comicID,
                        sourceKey: item.sourceKey,
                        title: item.comicTitle,
                        coverURL: item.coverURL
                    ),
                    chapterID: item.chapterID,
                    chapterTitle: item.chapterTitle,
                    localChapterDirectory: item.directoryPath
                )
            } label: {
                HStack(spacing: AppSpacing.md) {
                    CoverArtworkView(urlString: item.coverURL, width: 72, height: 102)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.comicTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(item.chapterTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(
                            AppLocalization.format(
                                "home.offline_spotlight.ready_pages",
                                "Offline ready · %@ pages",
                                String(item.pageCount)
                            )
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AppTint.accent)
                }
                .appCardStyle()
            }
            .buttonStyle(.plain)
        }
    }

    private var recentReadingSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(AppLocalization.text("home.recent_reading.title", "Recent Reading"))
                    .font(.title3.weight(.semibold))
                Spacer()
                if !recentHistory.isEmpty {
                    Button(AppLocalization.text("home.action.library", "Library"), action: onOpenLibrary)
                        .font(.subheadline.weight(.semibold))
                }
            }

            if recentHistory.isEmpty {
                Text(AppLocalization.text("home.recent_reading.empty", "Your recent reading will appear here once you open a chapter."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appCardStyle()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.md) {
                        ForEach(recentHistory, id: \.id) { item in
                            Button {
                                openRecentReading(item)
                            } label: {
                                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                                    CoverArtworkView(urlString: item.coverURL, width: 128, height: 182)
                                        .frame(width: 128, height: 182)

                                    Text(item.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)

                                    Text(
                                        item.chapter?.isEmpty == false
                                            ? item.chapter!
                                            : AppLocalization.format("home.chapter.page", "Page %@", String(item.page))
                                    )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    Text(model.relativeText(for: item.updatedAt))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .frame(width: 148, alignment: .leading)
                                .appCardStyle()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func comicSummary(from item: ReadingHistoryItem) -> ComicSummary {
        ComicSummary(
            id: item.comicID,
            sourceKey: item.sourceKey,
            title: item.title,
            coverURL: item.coverURL,
            author: item.author,
            tags: item.tags
        )
    }

    private func openRecentReading(_ item: ReadingHistoryItem) {
        guard let context = ReaderLaunchContext.fromHistory(item, using: library) else {
            pendingDetailReadRoute = nil
            selectedDetailItem = comicSummary(from: item)
            return
        }
        pendingDetailReadRoute = context
        selectedDetailItem = context.item
    }

    private func metricCard(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func compactMetricCard(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func actionChip(title: String, systemImage: String, prominent: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(prominent ? Color.white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            prominent ? AppTint.accent : AppSurface.subtle,
            in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
        )
    }

    private func quickActionCard(title: String, subtitle: String, value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer(minLength: 0)
                Text(value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .appCardStyle()
    }
}
