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
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @State private var query = ""
    @State private var isSelecting = false
    @State private var selectedSourceKeys: Set<String> = []
    @State private var batchWorking = false
    @State private var batchProgressText = ""
    @State private var showBatchUpdateConfirm = false
    @State private var showBatchDeleteConfirm = false

    private var installedSources: [InstalledSource] {
        let base = sourceManager.installedSources
        guard !query.isEmpty else { return base }
        return base.filter { matches(query: query, name: $0.name, key: $0.key) }
    }

    private var updateCount: Int {
        sourceManager.availableSourceUpdates.count
    }

    private var selectedInstalledSources: [InstalledSource] {
        installedSources.filter { selectedSourceKeys.contains($0.key) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                repositorySection
                installedSection
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle("Sources")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search installed sources")
        .toolbar {
            if !installedSources.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "Done" : "Select") {
                        toggleSelecting()
                    }
                }
            }
        }
        .alert("Update selected sources?", isPresented: $showBatchUpdateConfirm) {
            Button("Update", role: .none) {
                Task { await updateSelectedSources() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Update \(selectedInstalledSources.filter { sourceManager.availableSourceUpdates[$0.key] != nil }.count) selected source\(selectedInstalledSources.count == 1 ? "" : "s") with available updates?")
        }
        .alert("Delete selected sources?", isPresented: $showBatchDeleteConfirm) {
            Button("Delete", role: .destructive) {
                Task { await deleteSelectedSources() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Delete \(selectedInstalledSources.count) selected installed source\(selectedInstalledSources.count == 1 ? "" : "s")? This action cannot be undone.")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting {
                selectionBar
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
                title: "Repository",
                subtitle: sourceManager.remoteSources.isEmpty
                    ? "Index settings, update checks, and remote source discovery"
                    : "\(sourceManager.remoteSources.count) remote sources cached"
            ) {
                VStack(alignment: .leading, spacing: AppSpacing.md) {
                    HStack(spacing: 10) {
                        metricPill(
                            title: "Remote",
                            value: sourceManager.remoteSources.isEmpty ? "-" : "\(sourceManager.remoteSources.count)",
                            tint: AppTint.success
                        )
                        metricPill(
                            title: "Updates",
                            value: "\(updateCount)",
                            tint: updateCount == 0 ? .secondary : AppTint.warning
                        )
                    }

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sourceManager.autoLoadRemoteSources ? "Auto-load enabled" : "Manual load")
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

    private var installedSection: some View {
        ComicDetailSectionCard(
            title: "Installed Sources",
            subtitle: sourceManager.installedSources.isEmpty
                ? "Install a source from the repository below"
                : "Manage active sources, updates, and selection"
        ) {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if sourceManager.installedSources.isEmpty {
                    emptyState(
                        title: "No installed sources",
                        subtitle: "Refresh the repository and install a source to start browsing."
                    )
                } else {
                    ForEach(installedSources) { source in
                        installedSourceEntry(source)
                    }
                }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedSourceKeys.count) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppSurface.subtle, in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            Button(selectedSourceKeys.count == installedSources.count ? "Clear" : "Select All") {
                if selectedSourceKeys.count == installedSources.count {
                    selectedSourceKeys.removeAll()
                } else {
                    selectedSourceKeys = Set(installedSources.map(\.key))
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
                    Text("Update")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .disabled(selectedInstalledSources.filter { sourceManager.availableSourceUpdates[$0.key] != nil }.isEmpty || batchWorking)

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
                    Text("Delete")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(selectedSourceKeys.isEmpty || batchWorking)
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

    private func installedSourceEntry(_ source: InstalledSource) -> some View {
        Group {
            if isSelecting {
                Button {
                    toggleSelection(for: source)
                } label: {
                    selectableCard(isSelected: selectedSourceKeys.contains(source.key)) {
                        installedSourceCard(source)
                    }
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    SourceDetailView(
                        vm: vm,
                        sourceManager: sourceManager,
                        login: vm.login,
                        source: source
                    )
                } label: {
                    installedSourceCard(source)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func installedSourceCard(_ source: InstalledSource) -> some View {
        let updateVersion = sourceManager.availableSourceUpdates[source.key]
        let isSelected = sourceManager.selectedSourceKey == source.key

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.name)
                        .font(.headline)

                    Text("\(source.key) · v\(source.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isSelected {
                    statusBadge("Selected", tint: AppTint.accent)
                }
                if let updateVersion {
                    statusBadge("v\(updateVersion)", tint: AppTint.warning)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Label(isSelected ? "Current source" : "Tap for details", systemImage: isSelected ? "checkmark.circle.fill" : "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(isSelected ? AppTint.accent : .secondary)
                if let updateVersion {
                    Text("Update available: \(updateVersion)")
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

    private func toggleSelection(for source: InstalledSource) {
        if selectedSourceKeys.contains(source.key) {
            selectedSourceKeys.remove(source.key)
        } else {
            selectedSourceKeys.insert(source.key)
        }
    }

    private func updateSelectedSources() async {
        guard !batchWorking else { return }
        let targets = selectedInstalledSources.filter { sourceManager.availableSourceUpdates[$0.key] != nil }
        guard !targets.isEmpty else { return }
        batchWorking = true
        batchProgressText = "Preparing..."
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
        let targets = selectedInstalledSources
        guard !targets.isEmpty else { return }
        batchWorking = true
        batchProgressText = "Preparing..."
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

    private func matches(query: String, name: String, key: String, description: String? = nil) -> Bool {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return true }
        if name.lowercased().contains(keyword) { return true }
        if key.lowercased().contains(keyword) { return true }
        if let description, description.lowercased().contains(keyword) { return true }
        return false
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
