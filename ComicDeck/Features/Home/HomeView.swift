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
        RelativeTimeText.short(for: timestamp)
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
    var onOpenDownloads: (() -> Void)?
    var onOpenSources: (() -> Void)?
    let onTagSearchRequested: (String, String) -> Void

    @State private var model = HomeScreenModel()
    @State private var selectedDetailItem: ComicSummary?
    @State private var pendingDetailReadRoute: ReaderLaunchContext?

    private var latestHistory: ReadingHistoryItem? {
        library.history.first
    }

    var body: some View {
        let offlineSnapshot = OfflineChapterPreviewBuilder.snapshot(from: library.offlineChapters, limit: 1)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    searchEntryCard
                    continueReadingSection
                    homeStatusSection(readyOfflineCount: offlineSnapshot.readyCount)
                    if let latestOfflineItem = offlineSnapshot.recentChapters.first {
                        offlineSpotlightSection(latestOfflineItem)
                    }
                }
                .padding(.horizontal, AppSpacing.screen)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.xxl)
            }
            .appScreenBackground()
            .navigationTitle(AppLocalization.text("home.navigation.title", "Home"))
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
            .toolbar {
                ToolbarItem(placement: .platformTopBarLeading) {
                    Button(AppLocalization.text("home.action.settings", "Open settings"), systemImage: "gearshape", action: onOpenSettings)
                }
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button(AppLocalization.text("home.action.search", "Open search"), systemImage: "magnifyingglass", action: onOpenSearch)
                }
            }
        }
    }

    private var searchEntryCard: some View {
        Button(action: onOpenSearch) {
            HStack(spacing: AppSpacing.md) {
                AppIconBadge(systemImage: "magnifyingglass")

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(AppLocalization.text("home.search.title", "Search Comics"))
                        .font(AppTypography.cardTitle)
                        .foregroundStyle(.primary)
                    Text(AppLocalization.text("home.search.subtitle", "Jump straight to titles, authors, and tags."))
                        .font(AppTypography.meta)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .appCardStyle(elevated: true)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        }
        .appSoftPress()
        .accessibilityHint(AppLocalization.text("home.search.accessibility_hint", "Opens global search"))
    }

    @ViewBuilder
    private var continueReadingSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            AppSectionHeader(
                title: AppLocalization.text("home.continue.title", "Continue Reading"),
                subtitle: AppLocalization.text("home.continue.subtitle", "Pick up where you left off")
            )

            if let latestHistory {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack(alignment: .top, spacing: AppSpacing.md) {
                        CoverArtworkView(
                            urlString: latestHistory.coverURL,
                            refererURLString: latestHistory.comicID,
                            size: AppCoverSize.spotlight
                        )

                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text(latestHistory.title)
                                .font(AppTypography.cardTitle)
                                .lineLimit(2)

                            if let chapter = latestHistory.chapter, !chapter.isEmpty {
                                Text(chapter)
                                    .font(AppTypography.secondary)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Text(
                                AppLocalization.format(
                                    "home.continue.page_updated",
                                    "Page %@ · %@",
                                    String(latestHistory.page),
                                    model.relativeText(for: latestHistory.updatedAt)
                                )
                            )
                            .font(AppTypography.meta)
                            .foregroundStyle(.secondary)

                            if let author = latestHistory.author, !author.isEmpty {
                                Text(author)
                                    .font(AppTypography.meta)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: AppSpacing.md) {
                        AppMetricCard(
                            title: AppLocalization.text("home.metric.today", "Today"),
                            value: model.formatReadingDuration(library.todayReadingDurationSeconds),
                            subtitle: AppLocalization.text("home.metric.reading_time", "Reading time"),
                            tint: AppTint.accent
                        )

                        AppMetricCard(
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
                            AppActionChip(
                                title: AppLocalization.text("home.action.resume", "Resume"),
                                systemImage: "play.fill",
                                prominent: true,
                                expands: true
                            )
                        }
                        .appSoftPress()

                        Button(action: onOpenLibrary) {
                            AppActionChip(
                                title: AppLocalization.text("home.action.library", "Library"),
                                systemImage: "books.vertical",
                                expands: true
                            )
                        }
                        .appSoftPress()
                    }
                }
                .appCardStyle()
            } else {
                AppEmptyStateCard(
                    title: AppLocalization.text("home.empty.title", "No reading session yet"),
                    message: AppLocalization.text(
                        "home.empty.subtitle",
                        "Start from Discover or Search, then Home will surface your current comic and today's reading time."
                    ),
                    systemImage: "book.closed",
                    actionTitle: AppLocalization.text("home.action.browse_discover", "Browse Discover"),
                    action: onOpenDiscover
                )

                HStack(spacing: AppSpacing.sm) {
                    Button(action: onOpenSearch) {
                        AppActionChip(
                            title: AppLocalization.text("home.action.search_short", "Search"),
                            systemImage: "magnifyingglass",
                            expands: true
                        )
                    }
                    .appSoftPress()

                    Button(action: onOpenLibrary) {
                        AppActionChip(
                            title: AppLocalization.text("home.action.library", "Library"),
                            systemImage: "books.vertical",
                            expands: true
                        )
                    }
                    .appSoftPress()
                }
            }
        }
    }

    private func homeStatusSection(readyOfflineCount: Int) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            AppSectionHeader(
                title: AppLocalization.text("home.glance.title", "At a Glance"),
                subtitle: AppLocalization.text("home.glance.subtitle", "Library health and active source")
            )

            HStack(spacing: AppSpacing.md) {
                AppMetricCard(
                    title: AppLocalization.text("home.metric.reading", "Reading"),
                    value: "\(library.history.count)",
                    subtitle: AppLocalization.text("home.metric.history_items", "History items"),
                    tint: AppTint.info
                )
                AppMetricCard(
                    title: AppLocalization.text("home.metric.offline", "Offline"),
                    value: "\(readyOfflineCount)",
                    subtitle: AppLocalization.text("home.metric.ready", "Ready chapters"),
                    tint: AppTint.warning
                )
            }

            HStack(spacing: AppSpacing.md) {
                AppMetricCard(
                    title: AppLocalization.text("home.metric.sources", "Sources"),
                    value: "\(sourceManager.installedSources.count)",
                    subtitle: AppLocalization.text("home.metric.installed", "Installed"),
                    tint: AppTint.accent
                )
                AppMetricCard(
                    title: AppLocalization.text("home.metric.bookmarks", "Bookmarks"),
                    value: "\(library.favorites.count)",
                    subtitle: AppLocalization.text("home.metric.library", "Library"),
                    tint: AppTint.success
                )
            }

            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                HStack(spacing: AppSpacing.sm) {
                    AppIconBadge(systemImage: "puzzlepiece.extension", tint: AppTint.accent, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalization.text("home.source.active", "Active Source"))
                            .font(AppTypography.meta)
                            .foregroundStyle(.secondary)
                        Text(model.activeSourceSubtitle(using: sourceManager))
                            .font(AppTypography.cardTitle)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                Text(
                    sourceManager.selectedSourceKey.isEmpty
                        ? AppLocalization.text("home.source.empty_hint", "Open Discover to choose a source.")
                        : AppLocalization.text("home.source.browse_hint", "Browse fresh content from the current source.")
                )
                .font(AppTypography.meta)
                .foregroundStyle(.secondary)

                HStack(spacing: AppSpacing.sm) {
                    Button(action: onOpenDiscover) {
                        AppActionChip(
                            title: AppLocalization.text("home.action.browse_discover", "Browse Discover"),
                            systemImage: "safari",
                            prominent: true,
                            expands: true
                        )
                    }
                    .appSoftPress()

                    if let onOpenSources {
                        Button(action: onOpenSources) {
                            AppActionChip(
                                title: AppLocalization.text("home.sources_snapshot.title", "Sources"),
                                systemImage: "square.stack.3d.up",
                                expands: true
                            )
                        }
                        .appSoftPress()
                    }
                }
            }
            .appCardStyle()
        }
    }

    private func offlineSpotlightSection(_ item: OfflineChapterAsset) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            AppSectionHeader(
                title: AppLocalization.text("home.offline_spotlight.title", "Offline Spotlight"),
                subtitle: nil,
                trailing: { downloadsLink }
            )

            NavigationLink {
                ReaderRoutingView(
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
                    chapterSequence: OfflineChapterSequenceBuilder.sequence(for: item, in: library.offlineChapters)
                )
                .environment(library)
            } label: {
                HStack(spacing: AppSpacing.md) {
                    CoverArtworkView(
                        urlString: item.coverURL,
                        refererURLString: item.comicID,
                        size: AppCoverSize.spotlight
                    )

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(item.comicTitle)
                            .font(AppTypography.cardTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(item.chapterTitle)
                            .font(AppTypography.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(
                            AppLocalization.format(
                                "home.offline_spotlight.ready_pages",
                                "Offline ready · %@ pages",
                                String(item.pageCount)
                            )
                        )
                        .font(AppTypography.meta)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AppTint.accent)
                        .accessibilityHidden(true)
                }
                .appCardStyle(elevated: true)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var downloadsLink: some View {
        if let onOpenDownloads {
            Button(AppLocalization.text("downloads.navigation.title", "Downloads"), action: onOpenDownloads)
                .font(.subheadline.weight(.semibold))
        } else {
            NavigationLink(AppLocalization.text("downloads.navigation.title", "Downloads")) {
                DownloadManagerView(vm: vm)
            }
            .font(.subheadline.weight(.semibold))
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
}
