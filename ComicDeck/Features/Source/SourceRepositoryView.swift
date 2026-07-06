import SwiftUI
import Observation

@MainActor
struct SourceRepositoryView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel

    @State private var query = ""
    @State private var showInstalledOnly = false

    private var updateCount: Int {
        sourceManager.availableSourceUpdates.count
    }

    var body: some View {
        let snapshot = makeSnapshot()

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                configurationCard
                sourceListCard(snapshot)
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle(AppLocalization.text("source.repository.title", "Source Index"))
        .platformNavigationBarTitleDisplayModeInline()
        .searchable(text: $query, prompt: AppLocalization.text("source.repository.search_placeholder", "Search source index"))
        .toolbar {
            ToolbarItem(placement: .platformTopBarTrailing) {
                Button {
                    Task { await sourceManager.refreshRemoteSources(forceRefresh: true) }
                } label: {
                    if sourceManager.refreshingIndex {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(sourceManager.refreshingIndex)
                .accessibilityLabel(AppLocalization.text("source.repository.refresh_accessibility", "Refresh source index"))
            }
        }
        .refreshable {
            await sourceManager.refreshRemoteSources(forceRefresh: true)
        }
    }

    private func makeSnapshot() -> SourceRepositorySnapshot {
        SourceRepositorySnapshot(
            remoteSources: sourceManager.remoteSources,
            installedSources: sourceManager.installedSources,
            availableUpdates: sourceManager.availableSourceUpdates,
            normalizedQuery: normalizedQuery,
            showInstalledOnly: showInstalledOnly,
            resolvedKey: { sourceManager.resolvedKey(for: $0) },
            isOperating: { sourceManager.isOperating(on: $0) }
        )
    }

    private var configurationCard: some View {
        ComicDetailSectionCard(
            title: AppLocalization.text("source.repository.title", "Source Index"),
            subtitle: AppLocalization.text("source.repository.configuration_subtitle", "Provide your own source index URL and manage update checks")
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                TextField(AppLocalization.text("source.repository.index_url_placeholder", "index.json URL"), text: $sourceManager.indexURL)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

                HStack(spacing: 10) {
                    Button {
                        Task { await sourceManager.refreshRemoteSources(forceRefresh: true) }
                    } label: {
                        if sourceManager.refreshingIndex {
                            Label(AppLocalization.text("source.repository.refreshing", "Refreshing..."), systemImage: "arrow.clockwise")
                        } else if sourceManager.remoteSources.isEmpty {
                            Label(AppLocalization.text("source.repository.load_sources", "Load Sources"), systemImage: "tray.and.arrow.down")
                        } else {
                            Label(AppLocalization.text("common.refresh", "Refresh"), systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceManager.refreshingIndex)
                }

                Toggle(AppLocalization.text("source.repository.auto_load_toggle", "Auto-load source index on open"), isOn: $sourceManager.autoLoadRemoteSources)
                    .toggleStyle(.switch)

                Text(sourceManager.autoLoadRemoteSources
                     ? AppLocalization.text("source.repository.auto_load_enabled_help", "The configured source index refreshes automatically when you open Sources.")
                     : AppLocalization.text("source.repository.auto_load_disabled_help", "Remote sources stay idle until you explicitly load your source index."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(sourceManager.lastRemoteRefreshDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    metricPill(title: AppLocalization.text("source.repository.metric.installed", "Installed"), value: "\(sourceManager.installedSources.count)", tint: AppTint.accent)
                    metricPill(title: AppLocalization.text("source.management.metric.updates", "Updates"), value: "\(updateCount)", tint: updateCount == 0 ? .secondary : AppTint.warning)
                    metricPill(title: AppLocalization.text("source.management.metric.remote", "Remote"), value: sourceManager.remoteSources.isEmpty ? "-" : "\(sourceManager.remoteSources.count)", tint: AppTint.success)
                }

                HStack(spacing: 10) {
                    Button(AppLocalization.text("source.repository.check_updates", "Check Updates")) {
                        sourceManager.checkSourceUpdates()
                    }
                    .buttonStyle(.bordered)

                    if updateCount > 0 {
                        Button {
                            Task { await sourceManager.updateAllSources() }
                        } label: {
                            if sourceManager.updatingAll {
                                Label(AppLocalization.text("source.management.status.updating", "Updating..."), systemImage: "square.and.arrow.down")
                            } else {
                                Label(AppLocalization.text("source.repository.update_all", "Update All"), systemImage: "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(sourceManager.updatingAll)
                    }
                }

                if !sourceManager.status.isEmpty {
                    Text(sourceManager.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sourceListCard(_ snapshot: SourceRepositorySnapshot) -> some View {
        ComicDetailSectionCard(
            title: AppLocalization.text("source.repository.indexed_sources", "Indexed Sources"),
            subtitle: sourceManager.remoteSources.isEmpty
                ? AppLocalization.text("source.repository.indexed_sources_empty_subtitle", "Load your source index to browse available sources.")
                : AppLocalization.format("source.repository.filtered_count_format", "%lld sources in the current filter", Int64(snapshot.totalRowCount))
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Toggle(AppLocalization.text("source.repository.show_installed_only", "Show installed only"), isOn: $showInstalledOnly)
                    .toggleStyle(.switch)

                if sourceManager.remoteSources.isEmpty {
                    emptyState(
                        title: AppLocalization.text("source.repository.empty_title", "Source index not loaded"),
                        subtitle: sourceManager.autoLoadRemoteSources
                            ? AppLocalization.text("source.repository.empty_auto_subtitle", "Pull to refresh if your source index did not load.")
                            : AppLocalization.text("source.repository.empty_manual_subtitle", "Enter your source index URL, then tap Load Sources.")
                    )
                } else if snapshot.rows.isEmpty {
                    emptyState(
                        title: AppLocalization.text("source.repository.no_matches_title", "No matching sources"),
                        subtitle: AppLocalization.text("source.repository.no_matches_subtitle", "Try a different keyword or clear the installed-only filter.")
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.md) {
                        ForEach(snapshot.visibleRows) { row in
                            remoteSourceCard(row)
                        }
                    }

                    if snapshot.hasHiddenRows {
                        Text(AppLocalization.format(
                            "source.repository.visible_limit_format",
                            "Showing first %lld of %lld matching sources. Narrow the search to see more.",
                            Int64(snapshot.visibleRows.count),
                            Int64(snapshot.totalRowCount)
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func remoteSourceCard(_ row: SourceRepositoryRowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.item.name)
                        .font(.headline)

                    Text("\(row.key) · v\(row.item.version ?? "?")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let description = row.item.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                if row.installedSource != nil {
                    statusBadge(AppLocalization.text("source.repository.status.installed", "Installed"), tint: AppTint.success)
                }
                if row.hasUpdate {
                    statusBadge(AppLocalization.text("source.action.update", "Update"), tint: AppTint.warning)
                }
            }

            HStack(spacing: 10) {
                if let installed = row.installedSource {
                    NavigationLink {
                        SourceDetailView(
                            vm: vm,
                            sourceManager: sourceManager,
                            login: vm.login,
                            source: installed
                        )
                    } label: {
                        Label(AppLocalization.text("common.details", "Details"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    Task { await sourceManager.installFromIndex(row.item) }
                } label: {
                    if row.isOperating {
                        Label(AppLocalization.text("source.repository.working", "Working..."), systemImage: "arrow.down.circle")
                    } else if row.hasUpdate {
                        Label(AppLocalization.text("source.action.update", "Update"), systemImage: "square.and.arrow.down")
                    } else if row.installedSource != nil {
                        Label(AppLocalization.text("source.repository.reinstall", "Reinstall"), systemImage: "arrow.clockwise")
                    } else {
                        Label(AppLocalization.text("source.repository.install", "Install"), systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(row.isOperating)
            }
        }
        .padding(AppSpacing.md)
        .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func metricPill(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func statusBadge(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private func emptyState(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
