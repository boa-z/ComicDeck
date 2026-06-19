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
                    if let latestOfflineItem {
                        offlineSpotlightSection(latestOfflineItem)
                    }
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
                    onConsumeInitialReadRoute: { pendingDetailReadRoute = nil },
                    onNavigateBack: { selectedDetailItem = nil }
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
                sourcesSnapshotCard
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

    private var sourcesSnapshotCard: some View {
        NavigationLink {
            SourceManagementView(vm: vm, sourceManager: sourceManager)
        } label: {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                Label(AppLocalization.text("home.sources_snapshot.title", "Sources"), systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(
                    AppLocalization.format(
                        "home.sources_snapshot.installed",
                        "%@ installed",
                        String(sourceManager.installedSources.count)
                    )
                )
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(sourceManager.availableSourceUpdates.isEmpty
                     ? AppLocalization.text("home.sources_snapshot.up_to_date", "All sources up to date")
                     : AppLocalization.format(
                         "home.sources_snapshot.updates",
                         "%@ updates available",
                         String(sourceManager.availableSourceUpdates.count)
                     ))
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
                NavigationLink(AppLocalization.text("downloads.navigation.title", "Downloads")) {
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
                    localChapterDirectory: item.directoryPath,
                    chapterSequence: library.offlineChapters
                        .filter { $0.sourceKey == item.sourceKey && $0.comicID == item.comicID && $0.integrityStatus == .complete }
                        .sorted { $0.downloadedAt < $1.downloadedAt }
                        .map { ComicChapter(id: $0.chapterID, title: $0.chapterTitle) }
                )
                .environment(library)
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
}
