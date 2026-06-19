#if os(macOS)
import SwiftUI
import Observation

/// macOS Sources workspace.
///
/// Rendered as a **2-pane** `NavigationSplitView` (list + detail). Previously this
/// was a 3-pane split nested inside `MacMainView`'s own split view, which summed
/// to ~1200px of minimum width against a 980px window and caused column
/// squashing/layout corruption (显示错乱). Installed and indexed sources are now
/// folded into a single unified list; the detail pane is always a native
/// `Form/.grouped` view (installed → `MacSourceDetailView`, remote/index →
/// existing detail views).
@MainActor
struct MacSourceWorkspaceView: View {
    private enum DetailSelection: Hashable {
        case index
        case installed(String)
        case remote(String)
    }

    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @State private var selection: DetailSelection?
    @State private var query = ""
    @State private var showInstalledOnly = false
    @State private var batchSelection: Set<String> = []
    @State private var showBatchDeleteConfirm = false
    @State private var batchWorking = false

    private var filteredInstalledSources: [InstalledSource] {
        sourceManager.installedSources.filter { source in
            matchesKeyword(source.name) || matchesKeyword(source.key)
        }
    }

    private var filteredRemoteSources: [SourceConfigIndexItem] {
        sourceManager.remoteSources.filter { item in
            (!showInstalledOnly || sourceManager.installedSource(for: sourceManager.resolvedKey(for: item)) != nil)
            && (matchesKeyword(sourceManager.resolvedKey(for: item)) || matchesKeyword(item.name) || matchesKeyword(item.description ?? ""))
        }
    }

    var body: some View {
        NavigationSplitView {
            unifiedList
                .navigationTitle(AppLocalization.text("source.management.title", "Sources"))
                .searchable(text: $query, prompt: AppLocalization.text("source.management.search_placeholder", "Search sources"))
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if !batchSelection.isEmpty {
                            if !selectedUpdatableSources.isEmpty {
                                Button {
                                    Task { await updateSelectedSources() }
                                } label: {
                                    Label(AppLocalization.text("source.action.update_selected", "Update Selected"), systemImage: "square.and.arrow.down")
                                }
                                .disabled(batchWorking)
                            }

                            Button(role: .destructive) {
                                showBatchDeleteConfirm = true
                            } label: {
                                Label(AppLocalization.text("source.action.delete_selected", "Delete Selected"), systemImage: "trash")
                            }
                            .disabled(batchWorking)

                            Divider()
                        }

                        if hasAvailableUpdates {
                            Button {
                                Task { await updateAllInstalledSources() }
                            } label: {
                                if batchWorking {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label(AppLocalization.text("source.action.update_all", "Update All"), systemImage: "arrow.down.circle")
                                }
                            }
                            .disabled(batchWorking)
                        }

                        Button {
                            Task { await sourceManager.refreshRemoteSources(forceRefresh: true) }
                        } label: {
                            if sourceManager.refreshingIndex {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(AppLocalization.text("source.action.refresh", "Refresh"), systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(sourceManager.refreshingIndex)
                    }
                }
        } detail: {
            detailView
        }
        .alert(
            AppLocalization.text("source.alert.batch_delete.title", "Delete selected sources?"),
            isPresented: $showBatchDeleteConfirm
        ) {
            Button(AppLocalization.text("source.action.delete", "Delete"), role: .destructive) {
                Task { await deleteSelectedSources() }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) { }
        } message: {
            Text(AppLocalization.text("source.alert.batch_delete.message", "Delete \(batchSelection.count) selected installed source\(batchSelection.count == 1 ? "" : "s")? This action cannot be undone."))
        }
        .onAppear { ensureSelection() }
        .onChange(of: query) { _, _ in ensureSelection() }
        .onChange(of: showInstalledOnly) { _, _ in ensureSelection() }
        .onChange(of: sourceManager.installedSources) { _, sources in
            guard case let .installed(key) = selection else { return }
            if !sources.contains(where: { $0.key == key }) {
                selection = sources.first.map { .installed($0.key) } ?? .index
            }
        }
        .onChange(of: sourceManager.remoteSources) { _, _ in
            ensureSelection()
        }
    }

    // MARK: - Unified list

    private var unifiedList: some View {
        List(selection: $selection) {
            Section {
                MacSourceIndexStatusRow(sourceManager: sourceManager)
                    .tag(DetailSelection.index)
            } header: {
                Text(AppLocalization.text("source.management.repository", "Source Index"))
            } footer: {
                Text(AppLocalization.text("source.management.index_footer", "Configure your source index URL and update checks."))
            }

            Toggle(AppLocalization.text("source.repository.show_installed_only", "Show installed only"), isOn: $showInstalledOnly)
                .padding(.horizontal, 4)

            Section {
                if filteredInstalledSources.isEmpty {
                    Text(AppLocalization.text("source.management.empty", "No installed sources"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredInstalledSources) { source in
                        MacInstalledSourceRow(
                            source: source,
                            isActive: source.key == sourceManager.selectedSourceKey,
                            updateVersion: sourceManager.availableSourceUpdates[source.key],
                            isBatchSelected: batchSelection.contains(source.key)
                        )
                        .tag(DetailSelection.installed(source.key))
                        .contextMenu {
                            installedRowContextMenu(for: source)
                        }
                    }
                }
            } header: {
                HStack {
                    Text(AppLocalization.text("source.management.installed", "Installed Sources"))
                    Spacer()
                    if !batchSelection.isEmpty {
                        Text(AppLocalization.format("source.management.batch_count_format", "%d selected", batchSelection.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                if sourceManager.remoteSources.isEmpty {
                    Text(AppLocalization.text("source.repository.empty", "Source index not loaded"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if filteredRemoteSources.isEmpty {
                    Text(AppLocalization.text("source.repository.no_matches", "No matching sources"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredRemoteSources) { item in
                        MacRemoteSourceRow(
                            item: item,
                            key: sourceManager.resolvedKey(for: item),
                            isInstalled: sourceManager.installedSource(for: sourceManager.resolvedKey(for: item)) != nil,
                            updateVersion: sourceManager.availableSourceUpdates[sourceManager.resolvedKey(for: item)]
                        )
                        .tag(DetailSelection.remote(sourceManager.resolvedKey(for: item)))
                    }
                }
            } header: {
                Text(AppLocalization.text("source.repository.indexed_sources", "Indexed Sources"))
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func installedRowContextMenu(for source: InstalledSource) -> some View {
        Button(AppLocalization.text("source.action.use", "Use Source")) {
            sourceManager.selectSource(source)
        }
        .disabled(source.key == sourceManager.selectedSourceKey)

        if sourceManager.availableSourceUpdates[source.key] != nil {
            Button(AppLocalization.text("source.action.update", "Update")) {
                Task { await sourceManager.updateSource(source) }
            }
        }

        Button(AppLocalization.text("source.action.delete", "Delete"), role: .destructive) {
            Task { await sourceManager.uninstallSource(source) }
        }

        Divider()

        if batchSelection.contains(source.key) {
            Button(AppLocalization.text("source.action.deselect", "Deselect")) {
                batchSelection.remove(source.key)
            }
        } else {
            Button(AppLocalization.text("source.action.select", "Select for Batch")) {
                batchSelection.insert(source.key)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .installed(let key):
            if let source = sourceManager.installedSource(for: key) {
                MacSourceDetailView(
                    vm: vm,
                    sourceManager: sourceManager,
                    login: vm.login,
                    source: source
                )
                .frame(minWidth: 460, idealWidth: 560)
                .navigationSubtitle(AppLocalization.text("source.detail.installed", "Installed"))
            } else {
                emptyDetail
            }
        case .remote(let key):
            if let item = sourceManager.remoteSources.first(where: { sourceManager.resolvedKey(for: $0) == key }) {
                MacRemoteSourceDetailView(sourceManager: sourceManager, item: item)
                    .frame(minWidth: 460, idealWidth: 560)
            } else {
                emptyDetail
            }
        case .index, nil:
            MacSourceIndexDetailView(sourceManager: sourceManager)
                .frame(minWidth: 460, idealWidth: 560)
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView(
            AppLocalization.text("source.detail.empty", "Select a source"),
            systemImage: "puzzlepiece.extension",
            description: Text(AppLocalization.text("source.detail.empty_hint", "Choose an installed or indexed source from the list."))
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection / filtering

    private func ensureSelection() {
        guard selection == nil else { return }
        selection = filteredInstalledSources.first.map { .installed($0.key) } ?? .index
    }

    private func matchesKeyword(_ candidate: String) -> Bool {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return true }
        return candidate.lowercased().contains(keyword)
    }

    // MARK: - Batch operations

    private var hasAvailableUpdates: Bool {
        !sourceManager.availableSourceUpdates.isEmpty
    }

    private var selectedInstalledSources: [InstalledSource] {
        batchSelection.compactMap { key in
            sourceManager.installedSources.first { $0.key == key }
        }
    }

    private var selectedUpdatableSources: [InstalledSource] {
        selectedInstalledSources.filter { sourceManager.availableSourceUpdates[$0.key] != nil }
    }

    private func updateAllInstalledSources() async {
        guard !batchWorking else { return }
        let targets = sourceManager.installedSources.filter { sourceManager.availableSourceUpdates[$0.key] != nil }
        guard !targets.isEmpty else { return }
        batchWorking = true
        defer { batchWorking = false }
        for source in targets {
            await sourceManager.updateSource(source)
        }
    }

    private func updateSelectedSources() async {
        guard !batchWorking else { return }
        let targets = selectedUpdatableSources
        guard !targets.isEmpty else { return }
        batchWorking = true
        defer { batchWorking = false }
        for source in targets {
            await sourceManager.updateSource(source)
        }
        batchSelection.removeAll()
    }

    private func deleteSelectedSources() async {
        guard !batchWorking else { return }
        let targets = selectedInstalledSources
        guard !targets.isEmpty else { return }
        batchWorking = true
        defer { batchWorking = false }
        for source in targets {
            await sourceManager.uninstallSource(source)
        }
        batchSelection.removeAll()
    }
}

private struct MacInstalledSourceRow: View {
    let source: InstalledSource
    let isActive: Bool
    let updateVersion: String?
    var isBatchSelected: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            if isBatchSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AppTint.accent)
                    .frame(width: 22)
            } else {
                Image(systemName: isActive ? "checkmark.circle.fill" : "puzzlepiece.extension")
                    .foregroundStyle(isActive ? AppTint.accent : .secondary)
                    .frame(width: 22)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(source.key) · v\(source.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let updateVersion {
                Text("v\(updateVersion)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTint.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(AppTint.warning.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 3)
    }
}

private struct MacRemoteSourceRow: View {
    let item: SourceConfigIndexItem
    let key: String
    let isInstalled: Bool
    let updateVersion: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isInstalled ? "checkmark.circle" : "arrow.down.circle")
                .foregroundStyle(isInstalled ? AppTint.success : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(key) · v\(item.version ?? "?")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if updateVersion != nil {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(AppTint.warning)
            }
        }
        .padding(.vertical, 3)
    }
}

@MainActor
private struct MacSourceIndexStatusRow: View {
    @Bindable var sourceManager: SourceManagerViewModel

    private var remoteCountText: String {
        sourceManager.remoteSources.isEmpty ? "-" : "\(sourceManager.remoteSources.count)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .foregroundStyle(AppTint.accent)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text("source.management.repository", "Source Index"))
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Label(remoteCountText, systemImage: "shippingbox")
                    Label("\(sourceManager.installedSources.count)", systemImage: "puzzlepiece.extension")
                    if sourceManager.availableSourceUpdates.count > 0 {
                        Label("\(sourceManager.availableSourceUpdates.count)", systemImage: "arrow.up.circle")
                            .foregroundStyle(AppTint.warning)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(sourceManager.lastRemoteRefreshDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

@MainActor
private struct MacSourceIndexDetailView: View {
    @Bindable var sourceManager: SourceManagerViewModel

    var body: some View {
        Form {
            Section(AppLocalization.text("source.management.repository", "Source Index")) {
                TextField("index.json URL", text: $sourceManager.indexURL)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled()

                Toggle(AppLocalization.text("source.management.auto_load_toggle", "Auto-load source index on open"), isOn: $sourceManager.autoLoadRemoteSources)

                HStack {
                    Button {
                        Task { await sourceManager.refreshRemoteSources(forceRefresh: true) }
                    } label: {
                        if sourceManager.refreshingIndex {
                            Label(AppLocalization.text("source.repository.refreshing", "Refreshing..."), systemImage: "arrow.clockwise")
                        } else {
                            Label(AppLocalization.text("source.action.refresh", "Refresh"), systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(sourceManager.refreshingIndex)

                    Button(AppLocalization.text("source.action.check_updates", "Check Updates")) {
                        sourceManager.checkSourceUpdates()
                    }

                    if !sourceManager.availableSourceUpdates.isEmpty {
                        Button {
                            Task { await sourceManager.updateAllSources() }
                        } label: {
                            if sourceManager.updatingAll {
                                Label(AppLocalization.text("source.action.updating", "Updating..."), systemImage: "square.and.arrow.down")
                            } else {
                                Label(AppLocalization.text("source.action.update_all", "Update All"), systemImage: "square.and.arrow.down")
                            }
                        }
                        .disabled(sourceManager.updatingAll)
                    }
                }
            }

            Section(AppLocalization.text("source.repository.summary", "Summary")) {
                LabeledContent(AppLocalization.text("source.management.metric.remote", "Remote"), value: sourceManager.remoteSources.isEmpty ? "-" : "\(sourceManager.remoteSources.count)")
                LabeledContent(AppLocalization.text("source.management.metric.installed", "Installed"), value: "\(sourceManager.installedSources.count)")
                LabeledContent(AppLocalization.text("source.management.metric.updates", "Updates"), value: "\(sourceManager.availableSourceUpdates.count)")
                LabeledContent(AppLocalization.text("source.repository.last_refreshed", "Last Refreshed"), value: sourceManager.lastRemoteRefreshDescription)
            }

            Section(AppLocalization.text("source.repository.status", "Status")) {
                Text(sourceManager.status)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(AppLocalization.text("source.management.repository", "Source Index"))
    }
}

@MainActor
private struct MacRemoteSourceDetailView: View {
    @Bindable var sourceManager: SourceManagerViewModel
    let item: SourceConfigIndexItem

    private var key: String {
        sourceManager.resolvedKey(for: item)
    }

    private var installed: InstalledSource? {
        sourceManager.installedSource(for: key)
    }

    private var hasUpdate: Bool {
        sourceManager.availableSourceUpdates[key] != nil
    }

    var body: some View {
        Form {
            Section(item.name) {
                LabeledContent(AppLocalization.text("source.detail.key", "Key"), value: key)
                LabeledContent(AppLocalization.text("source.detail.version", "Version"), value: item.version ?? "?")

                if let description = item.description, !description.isEmpty {
                    Text(description)
                        .foregroundStyle(.secondary)
                }
            }

            Section(AppLocalization.text("source.detail.actions", "Actions")) {
                Button {
                    Task { await sourceManager.installFromIndex(item) }
                } label: {
                    if sourceManager.isOperating(on: key) {
                        Label(AppLocalization.text("source.action.working", "Working..."), systemImage: "arrow.down.circle")
                    } else if hasUpdate {
                        Label(AppLocalization.text("source.action.update", "Update"), systemImage: "square.and.arrow.down")
                    } else if installed != nil {
                        Label(AppLocalization.text("source.action.reinstall", "Reinstall"), systemImage: "arrow.clockwise")
                    } else {
                        Label(AppLocalization.text("source.action.install", "Install"), systemImage: "arrow.down.circle")
                    }
                }
                .disabled(sourceManager.isOperating(on: key))
            }

            if let installed {
                Section(AppLocalization.text("source.detail.installed", "Installed")) {
                    LabeledContent(AppLocalization.text("source.detail.version", "Version"), value: installed.version)
                    LabeledContent(AppLocalization.text("source.detail.script", "Script"), value: installed.scriptFileName)
                }
            }

            Section(AppLocalization.text("source.repository.status", "Status")) {
                Text(sourceManager.status)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(item.name)
    }
}
#endif
