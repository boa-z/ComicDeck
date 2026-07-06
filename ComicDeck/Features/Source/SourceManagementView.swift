import SwiftUI
import Observation

private struct SourceSelectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [AnyHashable: CGRect] = [:]

    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct SourceSelectionFrameModifier: ViewModifier {
    let id: AnyHashable
    let coordinateSpace: String

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SourceSelectionFramePreferenceKey.self,
                    value: [id: proxy.frame(in: .named(coordinateSpace))]
                )
            }
        )
    }
}

private extension View {
    func sourceSelectionFrame(id: AnyHashable, in coordinateSpace: String) -> some View {
        modifier(SourceSelectionFrameModifier(id: id, coordinateSpace: coordinateSpace))
    }
}

@MainActor
struct SourceManagementView: View {
    private struct InstalledSourceRowSnapshot: Identifiable {
        let id: String
        let source: InstalledSource
        let isCurrentSource: Bool
        let isBatchSelected: Bool
        let updateVersion: String?
    }

    private struct SourceManagementSnapshot {
        let installedRows: [InstalledSourceRowSnapshot]
        let selectedRows: [InstalledSourceRowSnapshot]
        let selectedUpdatableRows: [InstalledSourceRowSnapshot]
        let visibleSourceKeys: Set<String>

        var selectedUpdatableCount: Int {
            selectedUpdatableRows.count
        }

        init(
            installedSources: [InstalledSource],
            selectedSourceKey: String?,
            availableUpdates: [String: String],
            selectedKeys: Set<String>,
            normalizedQuery: String
        ) {
            var rows: [InstalledSourceRowSnapshot] = []
            var selectedRows: [InstalledSourceRowSnapshot] = []
            var selectedUpdatableRows: [InstalledSourceRowSnapshot] = []
            var visibleKeys = Set<String>()
            rows.reserveCapacity(installedSources.count)
            visibleKeys.reserveCapacity(installedSources.count)

            for source in installedSources {
                guard Self.matches(source.name, normalizedQuery: normalizedQuery) ||
                    Self.matches(source.key, normalizedQuery: normalizedQuery)
                else {
                    continue
                }

                let row = InstalledSourceRowSnapshot(
                    id: source.key,
                    source: source,
                    isCurrentSource: selectedSourceKey == source.key,
                    isBatchSelected: selectedKeys.contains(source.key),
                    updateVersion: availableUpdates[source.key]
                )
                rows.append(row)
                visibleKeys.insert(source.key)
                if row.isBatchSelected {
                    selectedRows.append(row)
                    if row.updateVersion != nil {
                        selectedUpdatableRows.append(row)
                    }
                }
            }

            self.installedRows = rows
            self.selectedRows = selectedRows
            self.selectedUpdatableRows = selectedUpdatableRows
            self.visibleSourceKeys = visibleKeys
        }

        private static func matches(_ candidate: String, normalizedQuery keyword: String) -> Bool {
            guard !keyword.isEmpty else { return true }
            return candidate.lowercased().contains(keyword)
        }
    }

    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @State private var query = ""
    @State private var isSelecting = false
    @State private var selectedSourceKeys: Set<String> = []
    @State private var batchWorking = false
    @State private var batchProgressText = ""
    @State private var showBatchUpdateConfirm = false
    @State private var showBatchDeleteConfirm = false

    private var updateCount: Int {
        sourceManager.availableSourceUpdates.count
    }

    var body: some View {
        let snapshot = makeSnapshot()
        let rows = snapshot.installedRows
        let selectedRows = snapshot.selectedRows
        let selectedUpdatableCount = snapshot.selectedUpdatableCount

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                repositorySection
                installedSection(rows: rows)
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle(AppLocalization.text("source.management.installed", "Sources"))
        .searchable(text: $query, prompt: AppLocalization.text("source.management.search_placeholder", "Search installed sources"))
        .toolbar {
            if !rows.isEmpty {
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button(isSelecting ? AppLocalization.text("common.done", "Done") : AppLocalization.text("source.action.select", "Select")) {
                        toggleSelecting()
                    }
                }
            }
        }
        .alert(AppLocalization.text("source.alert.batch_update.title", "Update selected sources?"), isPresented: $showBatchUpdateConfirm) {
            Button(AppLocalization.text("source.action.update", "Update"), role: .none) {
                Task { await updateSelectedSources() }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) { }
        } message: {
            Text(AppLocalization.format(
                "source.alert.batch_update.message",
                "Update %lld selected sources with available updates?",
                Int64(selectedUpdatableCount)
            ))
        }
        .alert(AppLocalization.text("source.alert.batch_delete.title", "Delete selected sources?"), isPresented: $showBatchDeleteConfirm) {
            Button(AppLocalization.text("source.action.delete", "Delete"), role: .destructive) {
                Task { await deleteSelectedSources() }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) { }
        } message: {
            Text(AppLocalization.format(
                "source.alert.batch_delete.message",
                "Delete %lld selected installed sources? This action cannot be undone.",
                Int64(selectedRows.count)
            ))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                selectionBar(snapshot: snapshot)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
    }

    private var repositorySection: some View {
        NavigationLink {
            SourceRepositoryView(vm: vm, sourceManager: sourceManager)
        } label: {
            ComicDetailSectionCard(
                title: AppLocalization.text("source.management.repository", "Source Index"),
                subtitle: sourceManager.remoteSources.isEmpty
                    ? AppLocalization.text("source.management.repository_hint", "Provide your own source index, then install and update sources from it")
                    : AppLocalization.format(
                        "source.management.repository_cached_format",
                        "%lld remote sources cached",
                        Int64(sourceManager.remoteSources.count)
                    )
            ) {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack(spacing: 10) {
                        metricPill(
                            title: AppLocalization.text("source.management.metric.remote", "Remote"),
                            value: sourceManager.remoteSources.isEmpty ? "-" : "\(sourceManager.remoteSources.count)",
                            tint: AppTint.success
                        )
                        metricPill(
                            title: AppLocalization.text("source.management.metric.updates", "Updates"),
                            value: "\(updateCount)",
                            tint: updateCount == 0 ? .secondary : AppTint.warning
                        )
                    }

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sourceManager.autoLoadRemoteSources ? AppLocalization.text("source.management.auto_load", "Auto-load enabled") : AppLocalization.text("source.management.manual_load", "Manual load"))
                                .font(.subheadline.weight(.semibold))
                            Text(sourceManager.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(sourceManager.lastRemoteRefreshDescription)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func installedSection(rows: [InstalledSourceRowSnapshot]) -> some View {
        ComicDetailSectionCard(
            title: AppLocalization.text("source.management.installed", "Installed Sources"),
            subtitle: sourceManager.installedSources.isEmpty
                ? AppLocalization.text("source.management.installed_hint", "Manage active sources, updates, and selection")
                : AppLocalization.text("source.management.installed_hint", "Manage active sources, updates, and selection")
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if sourceManager.installedSources.isEmpty {
                    emptyState(
                        title: AppLocalization.text("source.management.empty", "No installed sources"),
                        subtitle: AppLocalization.text("source.management.empty_hint", "Add your own source index and install a source to start browsing.")
                    )
                } else if rows.isEmpty {
                    emptyState(
                        title: AppLocalization.text("source.management.no_matches_title", "No matching sources"),
                        subtitle: AppLocalization.text("source.management.no_matches_subtitle", "Try a different keyword or clear the search field.")
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: AppSpacing.md) {
                        ForEach(rows) { row in
                            installedSourceEntry(row)
                        }
                    }
                }
            }
        }
    }

    private func selectionBar(snapshot: SourceManagementSnapshot) -> some View {
        HStack(spacing: 10) {
            Text(AppLocalization.format("source.management.selected", "%lld selected", Int64(snapshot.selectedRows.count)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppSurface.subtle, in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            Button(snapshot.selectedRows.count == snapshot.installedRows.count ? AppLocalization.text("common.clear", "Clear") : AppLocalization.text("source.management.select_all", "Select All")) {
                if snapshot.selectedRows.count == snapshot.installedRows.count {
                    selectedSourceKeys.removeAll()
                } else {
                    selectedSourceKeys = snapshot.visibleSourceKeys
                }
            }
            .font(.subheadline.weight(.semibold))
            .controlSize(.small)
            .buttonStyle(.bordered)

            Button {
                showBatchUpdateConfirm = true
            } label: {
                if batchWorking {
                    HStack(spacing: 6) {
                        ProgressView()
                        if !batchProgressText.isEmpty {
                            Text(batchProgressText)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                } else {
                    Text(AppLocalization.text("source.action.update", "Update"))
                        .font(.subheadline.weight(.semibold))
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(snapshot.selectedUpdatableCount == 0 || batchWorking)

            Button(role: .destructive) {
                showBatchDeleteConfirm = true
            } label: {
                if batchWorking {
                    HStack(spacing: 6) {
                        ProgressView()
                        if !batchProgressText.isEmpty {
                            Text(batchProgressText)
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                } else {
                    Text(AppLocalization.text("source.action.delete", "Delete"))
                        .font(.subheadline.weight(.semibold))
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(snapshot.selectedRows.isEmpty || batchWorking)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppSurface.border, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func installedSourceEntry(_ row: InstalledSourceRowSnapshot) -> some View {
        Group {
            if isSelecting {
                Button {
                    toggleSelection(for: row.source.key)
                } label: {
                    selectableCard(isSelected: row.isBatchSelected) {
                        installedSourceCard(row)
                    }
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    SourceDetailView(
                        vm: vm,
                        sourceManager: sourceManager,
                        login: vm.login,
                        source: row.source
                    )
                } label: {
                    installedSourceCard(row)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func installedSourceCard(_ row: InstalledSourceRowSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.source.name)
                        .font(.headline)

                    Text("\(row.source.key) · v\(row.source.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if row.isCurrentSource {
                    statusBadge(AppLocalization.text("source.management.status.selected", "Selected"), tint: AppTint.accent)
                }
                if let updateVersion = row.updateVersion {
                    statusBadge("v\(updateVersion)", tint: AppTint.warning)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Label(
                    row.isCurrentSource
                        ? AppLocalization.text("source.management.current_source", "Current source")
                        : AppLocalization.text("source.management.tap_for_details", "Tap for details"),
                    systemImage: row.isCurrentSource ? "checkmark.circle.fill" : "slider.horizontal.3"
                )
                    .font(.caption)
                    .foregroundStyle(row.isCurrentSource ? AppTint.accent : .secondary)
                if let updateVersion = row.updateVersion {
                    Text(AppLocalization.format("source.management.update_available", "Update available: %@", updateVersion))
                        .font(.caption)
                        .foregroundStyle(AppTint.warning)
                }
            }
        }
        .padding(AppSpacing.md)
        .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func selectableCard<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppTint.accent : .secondary)
                    .padding(8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .stroke(isSelected ? AppTint.accent : Color.clear, lineWidth: 2)
            }
    }

    private func toggleSelecting() {
        isSelecting.toggle()
        if !isSelecting {
            selectedSourceKeys.removeAll()
        }
    }

    private func toggleSelection(for key: String) {
        if selectedSourceKeys.contains(key) {
            selectedSourceKeys.remove(key)
        } else {
            selectedSourceKeys.insert(key)
        }
    }

    private func updateSelectedSources() async {
        guard !batchWorking else { return }
        let targets = makeSnapshot().selectedUpdatableRows.map(\.source)
        guard !targets.isEmpty else { return }
        batchWorking = true
        batchProgressText = AppLocalization.text("source.action.preparing", "Preparing...")
        defer {
            batchWorking = false
            batchProgressText = ""
        }
        for (index, source) in targets.enumerated() {
            batchProgressText = "\(index + 1) / \(targets.count)"
            await sourceManager.updateSource(source)
        }
        selectedSourceKeys.removeAll()
        isSelecting = false
    }

    private func deleteSelectedSources() async {
        guard !batchWorking else { return }
        let targets = makeSnapshot().selectedRows.map(\.source)
        guard !targets.isEmpty else { return }
        batchWorking = true
        batchProgressText = AppLocalization.text("source.action.preparing", "Preparing...")
        defer {
            batchWorking = false
            batchProgressText = ""
        }
        for (index, source) in targets.enumerated() {
            batchProgressText = "\(index + 1) / \(targets.count)"
            await sourceManager.uninstallSource(source)
        }
        selectedSourceKeys.removeAll()
        isSelecting = false
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

    private func makeSnapshot() -> SourceManagementSnapshot {
        SourceManagementSnapshot(
            installedSources: sourceManager.installedSources,
            selectedSourceKey: sourceManager.selectedSourceKey,
            availableUpdates: sourceManager.availableSourceUpdates,
            selectedKeys: selectedSourceKeys,
            normalizedQuery: normalizedQuery
        )
    }
}

private struct SourceSelectionButtonStyleModifier: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if isSelected {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}
