import SwiftUI
import Observation

@MainActor
struct SourceRepositoryView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel

    @State private var query = ""
    @State private var showInstalledOnly = false

    private var discoveredSources: [SourceConfigIndexItem] {
        let base = sourceManager.remoteSources.filter { item in
            !showInstalledOnly || sourceManager.installedSource(for: sourceManager.resolvedKey(for: item)) != nil
        }
        guard !query.isEmpty else { return base }
        return base.filter {
            matches(
                query: query,
                name: $0.name,
                key: sourceManager.resolvedKey(for: $0),
                description: $0.description
            )
        }
    }

    private var updateCount: Int {
        sourceManager.availableSourceUpdates.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                configurationCard
                sourceListCard
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle("Repository")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search repository sources")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await sourceManager.refreshRemoteSources() }
                } label: {
                    if sourceManager.refreshingIndex {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(sourceManager.refreshingIndex)
                .accessibilityLabel("Refresh source repository")
            }
        }
        .refreshable {
            await sourceManager.refreshRemoteSources()
        }
    }

    private var configurationCard: some View {
        ComicDetailSectionCard(title: "Repository", subtitle: "Configure the source index and manage update checks") {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                TextField("index.json URL", text: $sourceManager.indexURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))

                HStack(spacing: 10) {
                    Button("Use Official Index") {
                        sourceManager.resetIndexURLToOfficial()
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task { await sourceManager.refreshRemoteSources() }
                    } label: {
                        if sourceManager.refreshingIndex {
                            Label("Refreshing...", systemImage: "arrow.clockwise")
                        } else if sourceManager.remoteSources.isEmpty {
                            Label("Load Sources", systemImage: "tray.and.arrow.down")
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sourceManager.refreshingIndex)
                }

                Toggle("Auto-load repository on open", isOn: $sourceManager.autoLoadRemoteSources)
                    .toggleStyle(.switch)

                Text(sourceManager.autoLoadRemoteSources
                     ? "The repository index refreshes automatically when you open Sources."
                     : "Remote sources stay idle until you explicitly load them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(sourceManager.lastRemoteRefreshDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    metricPill(title: "Installed", value: "\(sourceManager.installedSources.count)", tint: AppTint.accent)
                    metricPill(title: "Updates", value: "\(updateCount)", tint: updateCount == 0 ? .secondary : AppTint.warning)
                    metricPill(title: "Remote", value: sourceManager.remoteSources.isEmpty ? "-" : "\(sourceManager.remoteSources.count)", tint: AppTint.success)
                }

                HStack(spacing: 10) {
                    Button("Check Updates") {
                        sourceManager.checkSourceUpdates()
                    }
                    .buttonStyle(.bordered)

                    if updateCount > 0 {
                        Button {
                            Task { await sourceManager.updateAllSources() }
                        } label: {
                            if sourceManager.updatingAll {
                                Label("Updating...", systemImage: "square.and.arrow.down")
                            } else {
                                Label("Update All", systemImage: "square.and.arrow.down")
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

    private var sourceListCard: some View {
        ComicDetailSectionCard(
            title: "Repository Sources",
            subtitle: sourceManager.remoteSources.isEmpty
                ? "Load the repository to browse available sources."
                : "\(discoveredSources.count) sources in the current filter"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                Toggle("Show installed only", isOn: $showInstalledOnly)
                    .toggleStyle(.switch)

                if sourceManager.remoteSources.isEmpty {
                    emptyState(
                        title: "Repository not loaded",
                        subtitle: sourceManager.autoLoadRemoteSources
                            ? "Pull to refresh if the repository did not load."
                            : "Tap Load Sources to fetch available sources."
                    )
                } else if discoveredSources.isEmpty {
                    emptyState(
                        title: "No matching sources",
                        subtitle: "Try a different keyword or clear the installed-only filter."
                    )
                } else {
                    ForEach(discoveredSources.prefix(120)) { item in
                        remoteSourceCard(item)
                    }
                }
            }
        }
    }

    private func remoteSourceCard(_ item: SourceConfigIndexItem) -> some View {
        let key = sourceManager.resolvedKey(for: item)
        let installed = sourceManager.installedSource(for: key)
        let hasUpdate = sourceManager.availableSourceUpdates[key] != nil
        let isOperating = sourceManager.isOperating(on: key)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.headline)

                    Text("\(key) · v\(item.version ?? "?")")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let description = item.description, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                if installed != nil {
                    statusBadge("Installed", tint: AppTint.success)
                }
                if hasUpdate {
                    statusBadge("Update", tint: AppTint.warning)
                }
            }

            HStack(spacing: 10) {
                if let installed {
                    NavigationLink {
                        SourceDetailView(
                            vm: vm,
                            sourceManager: sourceManager,
                            login: vm.login,
                            source: installed
                        )
                    } label: {
                        Label("Details", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button {
                    Task { await sourceManager.installFromIndex(item) }
                } label: {
                    if isOperating {
                        Label("Working...", systemImage: "arrow.down.circle")
                    } else if hasUpdate {
                        Label("Update", systemImage: "square.and.arrow.down")
                    } else if installed != nil {
                        Label("Reinstall", systemImage: "arrow.clockwise")
                    } else {
                        Label("Install", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isOperating)
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

    private func matches(query: String, name: String, key: String, description: String? = nil) -> Bool {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return true }
        if name.lowercased().contains(keyword) { return true }
        if key.lowercased().contains(keyword) { return true }
        if let description, description.lowercased().contains(keyword) { return true }
        return false
    }
}
