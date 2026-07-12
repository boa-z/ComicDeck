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

    var body: some View {
        let snapshot = LibraryOverviewSnapshot(
            history: library.history,
            offlineChapters: library.offlineChapters,
            historyLimit: 6,
            offlineLimit: 3
        )
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.section) {
                    workspacesSection(readyOfflineCount: snapshot.readyOfflineCount)
                    recentReadingSection(recentHistory: snapshot.recentHistory)
                    if !snapshot.recentOfflineChapters.isEmpty {
                        downloadsSnapshotSection(recentCompletedDownloads: snapshot.recentOfflineChapters)
                    }
                }
                .padding(.horizontal, AppSpacing.screen)
                .padding(.top, AppSpacing.md)
                .padding(.bottom, AppSpacing.xl)
            }
            .appScreenBackground()
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
            AppSectionHeader(
                title: AppLocalization.text("library.workspaces.title", "Workspaces"),
                subtitle: AppLocalization.text("library.workspaces.subtitle", "Jump into bookmarks, trackers, and offline tools")
            )

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
                .buttonStyle(AppSoftPressButtonStyle())

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
                    .buttonStyle(AppSoftPressButtonStyle())
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
                .buttonStyle(AppSoftPressButtonStyle())

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
                .buttonStyle(AppSoftPressButtonStyle())

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
                .buttonStyle(AppSoftPressButtonStyle())
            }
        }
    }

    private func recentReadingSection(recentHistory: [ReadingHistoryItem]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            AppSectionHeader(
                title: AppLocalization.text("library.recent.title", "Recent Activity"),
                subtitle: AppLocalization.text("library.recent.subtitle", "Latest chapters and progress"),
                trailing: {
                    if !recentHistory.isEmpty {
                        NavigationLink(AppLocalization.text("library.workspace.history.title", "History")) {
                            HistoryView(vm: vm, onTagSearchRequested: onTagSearchRequested)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                }
            )

            if recentHistory.isEmpty {
                AppEmptyStateCard(
                    title: AppLocalization.text("library.recent.empty_title", "No recent activity"),
                    message: AppLocalization.text("library.recent.empty", "Your reading history will appear here after you open a chapter."),
                    systemImage: "clock.arrow.circlepath"
                )
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
                            .buttonStyle(AppSoftPressButtonStyle())
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func downloadsSnapshotSection(recentCompletedDownloads: [OfflineChapterAsset]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            AppSectionHeader(
                title: AppLocalization.text("library.offline_ready.title", "Offline Ready"),
                subtitle: AppLocalization.text("library.offline_ready.subtitle", "Ready to read without network"),
                trailing: {
                    NavigationLink(AppLocalization.text("library.workspace.downloads.title", "Downloads")) {
                        DownloadManagerView(vm: vm)
                    }
                    .font(.subheadline.weight(.semibold))
                }
            )

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
                        .buttonStyle(AppSoftPressButtonStyle())
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
            AppIconBadge(systemImage: systemImage, tint: tint, size: 40)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(AppTypography.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: AppSpacing.xs) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .appCardStyle()
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .accessibilityElement(children: .combine)
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
            CoverArtworkView(
                urlString: coverURL,
                refererURLString: refererURLString,
                size: AppCoverSize.shelf
            )
            .frame(width: AppCoverSize.shelf.width, height: AppCoverSize.shelf.height)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(minHeight: 36, alignment: .topLeading)

            Text(subtitle)
                .font(AppTypography.meta)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: 148, alignment: .leading)
        .appCardStyle()
        .accessibilityElement(children: .combine)
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
