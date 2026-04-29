import SwiftUI
import Observation

struct TrackerSubscriptionRow: Identifiable, Hashable {
    var id: String { entry.mediaID }
    let entry: TrackerListEntry
    let localGroups: [TrackerSubscriptionLocalGroup]
}

struct TrackerSubscriptionLocalGroup: Identifiable, Hashable {
    var id: String { "\(sourceKey)::\(comicID)" }
    let sourceKey: String
    let comicID: String
    let title: String
    let coverURL: String?
    let bindings: [TrackerProvider: TrackerBinding]
}

struct TrackerSourceSearchRoute: Identifiable, Hashable {
    let sourceKey: String
    let keyword: String

    var id: String { "\(sourceKey)::\(keyword)" }
}

@MainActor
@Observable
final class TrackerSubscriptionsScreenModel {
    var rows: [TrackerSubscriptionRow] = []
    var loading = false
    var errorMessage: String?
    var lastLoadedAt: Date?
    private var entries: [TrackerListEntry] = []

    func load(provider: TrackerProvider, using tracker: TrackerViewModel, library: LibraryViewModel) async {
        guard !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }

        do {
            try await tracker.reload()
            entries = try await tracker.loadMangaList(provider: provider)
            refreshLocalBindings(provider: provider, using: tracker, library: library)
            lastLoadedAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshLocalBindings(provider: TrackerProvider, using tracker: TrackerViewModel, library: LibraryViewModel) {
        rows = Self.makeRows(entries: entries, provider: provider, localComicForBinding: { binding in
            Self.localComic(for: binding, library: library)
        }) { mediaID in
            tracker.bindingGroups(provider: provider, remoteMediaID: mediaID)
        }
    }

    static func makeRows(
        entries: [TrackerListEntry],
        provider: TrackerProvider,
        localComicForBinding: (TrackerBinding) -> ComicSummary?,
        bindingGroupsForMediaID: (String) -> [[TrackerProvider: TrackerBinding]]
    ) -> [TrackerSubscriptionRow] {
        entries.map { entry in
            let groups = bindingGroupsForMediaID(entry.mediaID).compactMap { bindings -> TrackerSubscriptionLocalGroup? in
                guard let providerBinding = bindings[provider] else { return nil }
                let localComic = localComicForBinding(providerBinding)
                return TrackerSubscriptionLocalGroup(
                    sourceKey: providerBinding.sourceKey,
                    comicID: providerBinding.comicID,
                    title: localComic?.title ?? providerBinding.sourceTitle ?? providerBinding.remoteTitle,
                    coverURL: localComic?.coverURL ?? providerBinding.sourceCoverURL ?? providerBinding.remoteCoverURL,
                    bindings: bindings
                )
            }
            return TrackerSubscriptionRow(entry: entry, localGroups: groups)
        }
    }

    private static func localComic(for binding: TrackerBinding, library: LibraryViewModel) -> ComicSummary? {
        if let favorite = library.favorites.first(where: { $0.sourceKey == binding.sourceKey && $0.id == binding.comicID }) {
            return ComicSummary(
                id: favorite.id,
                sourceKey: favorite.sourceKey,
                title: favorite.title,
                coverURL: favorite.coverURL
            )
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
            return ComicSummary(
                id: offline.comicID,
                sourceKey: offline.sourceKey,
                title: offline.comicTitle,
                coverURL: offline.coverURL
            )
        }
        return nil
    }
}

@MainActor
struct TrackerSubscriptionsView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    let provider: TrackerProvider

    @Environment(TrackerViewModel.self) private var tracker
    @Environment(LibraryViewModel.self) private var library
    @State private var model = TrackerSubscriptionsScreenModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                headerCard

                if tracker.account(for: provider) == nil {
                    connectRequiredCard
                } else if model.loading && model.rows.isEmpty {
                    loadingCard
                } else if let errorMessage = model.errorMessage, model.rows.isEmpty {
                    errorCard(errorMessage)
                } else if model.rows.isEmpty {
                    emptyCard
                } else {
                    if let errorMessage = model.errorMessage {
                        compactErrorBanner(errorMessage)
                    }
                    LazyVStack(spacing: AppSpacing.md) {
                        ForEach(model.rows) { row in
                            subscriptionCard(row)
                        }
                    }
                }
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle(providerLibraryTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await loadIfConnected() }
                } label: {
                    if model.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.loading || tracker.account(for: provider) == nil)
                .accessibilityLabel(AppLocalization.text("tracking.subscriptions.refresh", "Refresh"))
            }
        }
        .refreshable {
            await loadIfConnected()
        }
        .task {
            await loadIfConnected()
        }
        .onChange(of: tracker.bindings) { _, _ in
            model.refreshLocalBindings(provider: provider, using: tracker, library: library)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .font(.title2)
                    .foregroundStyle(AppTint.accent)
                    .frame(width: 44, height: 44)
                    .background(AppTint.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(providerLibraryTitle)
                        .font(.headline)
                    Text(providerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: AppSpacing.sm) {
                statusPill(
                    title: AppLocalization.text("tracking.subscriptions.account", "Account"),
                    value: tracker.account(for: provider)?.displayName ?? AppLocalization.text("library.workspace.tracker.disconnected", "Connect")
                )
                statusPill(
                    title: AppLocalization.text("tracking.subscriptions.entries", "Entries"),
                    value: "\(model.rows.count)"
                )
            }

            if let lastLoadedAt = model.lastLoadedAt {
                Text(lastLoadedText(lastLoadedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .appCardStyle()
    }

    private var connectRequiredCard: some View {
        stateCard(
            systemImage: "person.crop.circle.badge.exclamationmark",
            title: AppLocalization.format(
                "tracking.subscriptions.connect_required.title_format",
                "Connect %@ first",
                provider.title
            ),
            message: AppLocalization.format(
                "tracking.subscriptions.connect_required.message_format",
                "Connect %@ in Settings > Tracking to load your manga list.",
                provider.title
            )
        )
    }

    private var loadingCard: some View {
        VStack(spacing: AppSpacing.sm) {
            ProgressView()
            Text(AppLocalization.format(
                "tracking.subscriptions.loading_format",
                "Loading %@ manga...",
                provider.title
            ))
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .appCardStyle()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: AppSpacing.md) {
            stateCard(
                systemImage: "exclamationmark.triangle",
                title: AppLocalization.format(
                    "tracking.subscriptions.error_format",
                    "Could not load %@",
                    provider.title
                ),
                message: message
            )
            Button(AppLocalization.text("tracking.subscriptions.refresh", "Refresh")) {
                Task { await loadIfConnected() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.loading)
        }
    }

    private var emptyCard: some View {
        stateCard(
            systemImage: "tray",
            title: AppLocalization.format(
                "tracking.subscriptions.empty_format",
                "No %@ manga found",
                provider.title
            ),
            message: AppLocalization.format(
                "tracking.subscriptions.empty.message_format",
                "Your %@ manga list will appear here after it has entries.",
                provider.title
            )
        )
    }

    private func compactErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AppTint.warning)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.sm)
        .background(AppTint.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func subscriptionCard(_ row: TrackerSubscriptionRow) -> some View {
        NavigationLink {
            TrackerSubscriptionDetailView(
                vm: vm,
                sourceManager: sourceManager,
                provider: provider,
                row: row
            )
            .environment(library)
        } label: {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                CoverArtworkView(urlString: row.entry.coverURL, width: 72, height: 104)
                    .frame(width: 72, height: 104)

                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(row.entry.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let subtitle = row.entry.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(remoteProgressText(row.entry))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTint.accent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppLocalization.format(
            "tracking.subscriptions.open_detail_format",
            "Open %@ details",
            row.entry.title
        ))
        .appCardStyle()
    }

    private func statusPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(AppSurface.subtle, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func stateCard(systemImage: String, title: String, message: String) -> some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(AppSpacing.lg)
        .appCardStyle()
    }

    private func loadIfConnected() async {
        guard tracker.account(for: provider) != nil else { return }
        await model.load(provider: provider, using: tracker, library: library)
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

    private var providerLibraryTitle: String {
        AppLocalization.format(
            "tracking.subscriptions.title_format",
            "%@ Library",
            provider.title
        )
    }

    private var providerSubtitle: String {
        AppLocalization.format(
            "tracking.subscriptions.subtitle_format",
            "View %@ manga and confirmed local progress bindings.",
            provider.title
        )
    }

    private func lastLoadedText(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let text = formatter.localizedString(for: date, relativeTo: Date())
        return AppLocalization.format("tracking.subscriptions.last_loaded", "Loaded %@", text)
    }
}
