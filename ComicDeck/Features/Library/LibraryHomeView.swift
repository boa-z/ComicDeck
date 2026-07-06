import SwiftUI
import Observation

@MainActor
@Observable
final class LibraryHomeScreenModel {
    func relativeText(for timestamp: Int64) -> String {
        RelativeTimeText.short(for: timestamp)
    }
}

@MainActor
struct LibraryHomeView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @Environment(LibraryViewModel.self) private var library

    let onTagSearchRequested: (String, String) -> Void

    @State private var model = LibraryHomeScreenModel()
    @State private var selectedDetailItem: ComicSummary?
    @State private var pendingDetailReadRoute: ReaderLaunchContext?

    private var recentHistory: [ReadingHistoryItem] {
        Array(library.history.prefix(6))
    }

    var body: some View {
        let offlineSnapshot = OfflineChapterPreviewBuilder.snapshot(from: library.offlineChapters, limit: 3)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    workspacesSection(readyOfflineCount: offlineSnapshot.readyCount)
                    recentReadingSection
                    if !offlineSnapshot.recentChapters.isEmpty {
                        downloadsSnapshotSection(recentCompletedDownloads: offlineSnapshot.recentChapters)
                    }
                }
                .padding(.horizontal, AppSpacing.screen)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.xl)
            }
            .background(AppSurface.grouped.ignoresSafeArea())
            .navigationTitle(AppLocalization.text("library.navigation.title", "Library"))
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
        }
    }

    private func workspacesSection(readyOfflineCount: Int) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AppLocalization.text("library.workspaces.title", "Workspaces"))
                .font(.title3.weight(.semibold))

            VStack(spacing: AppSpacing.sm) {
                NavigationLink {
                    LibraryBookmarksView(vm: vm, onTagSearchRequested: onTagSearchRequested)
                } label: {
                    workspaceCard(
                        title: AppLocalization.text("library.workspace.bookmarks.title", "Bookmarks"),
                        subtitle: AppLocalization.text("library.workspace.bookmarks.subtitle", "Your local reading list and shelf organization"),
                        value: "\(library.favorites.count)",
                        systemImage: "bookmark",
                        tint: AppTint.success
                    )
                }
                .buttonStyle(.plain)

                ForEach(TrackerProvider.mangaListWorkspaceProviders) { provider in
                    NavigationLink {
                        TrackerSubscriptionsView(vm: vm, sourceManager: sourceManager, provider: provider)
                    } label: {
                        workspaceCard(
                            title: AppLocalization.format(
                                "library.workspace.tracker.title_format",
                                "%@ Library",
                                provider.title
                            ),
                            subtitle: AppLocalization.text(
                                "library.workspace.tracker.subtitle",
                                "View manga and local progress bindings"
                            ),
                            value: vm.tracker.account(for: provider)?.displayName ?? AppLocalization.text("library.workspace.tracker.disconnected", "Connect"),
                            systemImage: "rectangle.stack.badge.person.crop",
                            tint: AppTint.accent
                        )
                    }
                    .buttonStyle(.plain)
                }

                NavigationLink {
                    FavoritesView(vm: vm, sourceManager: sourceManager, onTagSearchRequested: onTagSearchRequested)
                } label: {
                    workspaceCard(
                        title: AppLocalization.text("library.workspace.favorites.title", "Favorites"),
                        subtitle: AppLocalization.text("library.workspace.favorites.subtitle", "Source-side favorites and folders"),
                        value: sourceManager.selectedSourceKey.isEmpty ? AppLocalization.text("library.workspace.favorites.source", "Source") : sourceManager.selectedSourceKey,
                        systemImage: "heart.text.square",
                        tint: AppTint.warning
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    HistoryView(vm: vm, onTagSearchRequested: onTagSearchRequested)
                } label: {
                    workspaceCard(
                        title: AppLocalization.text("library.workspace.history.title", "History"),
                        subtitle: AppLocalization.text("library.workspace.history.subtitle", "Resume chapters and manage reading history"),
                        value: "\(library.history.count)",
                        systemImage: "clock.arrow.circlepath",
                        tint: AppTint.warning
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    DownloadManagerView(vm: vm)
                } label: {
                    workspaceCard(
                        title: AppLocalization.text("library.workspace.downloads.title", "Downloads"),
                        subtitle: AppLocalization.text("library.workspace.downloads.subtitle", "Queue, offline library, and storage cleanup"),
                        value: "\(readyOfflineCount)",
                        systemImage: "arrow.down.circle",
                        tint: AppTint.accent
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recentReadingSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(AppLocalization.text("library.recent.title", "Recent Activity"))
                    .font(.title3.weight(.semibold))
                Spacer()
                if !recentHistory.isEmpty {
                    NavigationLink(AppLocalization.text("library.workspace.history.title", "History")) {
                        HistoryView(vm: vm, onTagSearchRequested: onTagSearchRequested)
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }

            if recentHistory.isEmpty {
                Text(AppLocalization.text("library.recent.empty", "Your reading history will appear here after you open a chapter."))
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
                                libraryPreviewCard(
                                    title: item.title,
                                    subtitle: recentReadingSubtitle(item),
                                    coverURL: item.coverURL,
                                    refererURLString: item.comicID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func downloadsSnapshotSection(recentCompletedDownloads: [OfflineChapterAsset]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack {
                Text(AppLocalization.text("library.offline_ready.title", "Offline Ready"))
                    .font(.title3.weight(.semibold))
                Spacer()
                NavigationLink(AppLocalization.text("library.workspace.downloads.title", "Downloads")) {
                    DownloadManagerView(vm: vm)
                }
                .font(.subheadline.weight(.semibold))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.md) {
                    ForEach(recentCompletedDownloads) { item in
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
                            libraryPreviewCard(
                                title: item.comicTitle,
                                subtitle: AppLocalization.format(
                                    "library.offline_ready.chapter_pages",
                                    "%@ • %@ pages",
                                    item.chapterTitle,
                                    String(item.pageCount)
                                ),
                                coverURL: item.coverURL,
                                refererURLString: item.comicID
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func statPill(title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1), in: Capsule())
    }

    private func workspaceCard(title: String, subtitle: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(value)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .appCardStyle()
    }

    private func recentReadingSubtitle(_ item: ReadingHistoryItem) -> String {
        let chapterText = item.chapter?.isEmpty == false
            ? item.chapter!
            : AppLocalization.format("library.recent.page", "Page %@", String(item.page))
        return "\(chapterText) • \(model.relativeText(for: item.updatedAt))"
    }

    private func libraryPreviewCard(
        title: String,
        subtitle: String,
        coverURL: String?,
        refererURLString: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            CoverArtworkView(urlString: coverURL, refererURLString: refererURLString, width: 128, height: 182)
                .frame(width: 128, height: 182)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: 148, alignment: .leading)
        .appCardStyle()
    }

    private func openRecentReading(_ item: ReadingHistoryItem) {
        guard let context = ReaderLaunchContext.fromHistory(item, using: library) else {
            pendingDetailReadRoute = nil
            selectedDetailItem = ComicSummary(
                id: item.comicID,
                sourceKey: item.sourceKey,
                title: item.title,
                coverURL: item.coverURL,
                author: item.author,
                tags: item.tags
            )
            return
        }
        pendingDetailReadRoute = context
        selectedDetailItem = context.item
    }
}
