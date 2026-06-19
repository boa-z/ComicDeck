#if os(macOS)
import SwiftUI
import Observation

@MainActor
struct MacSourceWorkspaceView: View {
    private enum Pane: String, CaseIterable, Identifiable {
        case installed
        case index

        var id: String { rawValue }

        var title: String {
            switch self {
            case .installed:
                return AppLocalization.text("source.management.installed", "Installed Sources")
            case .index:
                return AppLocalization.text("source.management.repository", "Source Index")
            }
        }

        var systemImage: String {
            switch self {
            case .installed:
                return "puzzlepiece.extension"
            case .index:
                return "tray.and.arrow.down"
            }
        }
    }

    private enum DetailSelection: Hashable {
        case installed(String)
        case remote(String)
        case index
    }

    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @State private var pane: Pane? = .installed
    @State private var selection: DetailSelection? = .index
    @State private var installedQuery = ""
    @State private var remoteQuery = ""
    @State private var showInstalledOnly = false
    @State private var batchSelection: Set<String> = []
    @State private var showBatchDeleteConfirm = false
    @State private var batchWorking = false

    private var filteredInstalledSources: [InstalledSource] {
        let keyword = installedQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return sourceManager.installedSources }
        return sourceManager.installedSources.filter {
            $0.name.lowercased().contains(keyword) || $0.key.lowercased().contains(keyword)
        }
    }

    private var filteredRemoteSources: [SourceConfigIndexItem] {
        let base = sourceManager.remoteSources.filter { item in
            !showInstalledOnly || sourceManager.installedSource(for: sourceManager.resolvedKey(for: item)) != nil
        }
        let keyword = remoteQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return base }
        return base.filter { item in
            sourceManager.resolvedKey(for: item).lowercased().contains(keyword) ||
            item.name.lowercased().contains(keyword) ||
            (item.description?.lowercased().contains(keyword) ?? false)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationTitle(AppLocalization.text("source.management.title", "Sources"))
            .frame(minWidth: 190)
        } content: {
            sourceList
                .navigationTitle(paneTitle)
                .searchable(text: activeSearchBinding, prompt: searchPrompt)
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if pane == .installed {
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
        .navigationSplitViewStyle(.balanced)
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
        .onAppear {
            if selection == nil {
                selection = sourceManager.installedSources.first.map { .installed($0.key) } ?? .index
            }
        }
        .onChange(of: pane) { _, newPane in
            switch newPane {
            case .installed:
                selection = filteredInstalledSources.first.map { .installed($0.key) } ?? .index
            case .index:
                selection = .index
            case nil:
                selection = .index
            }
        }
        .onChange(of: sourceManager.installedSources) { _, sources in
            guard case let .installed(key) = selection else { return }
            if !sources.contains(where: { $0.key == key }) {
                selection = sources.first.map { .installed($0.key) } ?? .index
            }
        }
    }

    @ViewBuilder
    private var sourceList: some View {
        switch pane ?? .installed {
        case .installed:
            List(selection: $selection) {
                Section {
                    if filteredInstalledSources.isEmpty {
                        ContentUnavailableView(
                            AppLocalization.text("source.management.empty", "No installed sources"),
                            systemImage: "puzzlepiece.extension",
                            description: Text(AppLocalization.text("source.management.empty_hint", "Add your own source index and install a source to start browsing."))
                        )
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
                        }
                    }
                } header: {
                    HStack {
                        Text(AppLocalization.text("source.management.installed", "Installed Sources"))
                        Spacer()
                        if !batchSelection.isEmpty {
                            Text("\(batchSelection.count) selected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        case .index:
            List(selection: $selection) {
                Section {
                    MacSourceIndexStatusRow(sourceManager: sourceManager)
                        .tag(DetailSelection.index)
                }

                Section {
                    Toggle(AppLocalization.text("source.repository.show_installed_only", "Show installed only"), isOn: $showInstalledOnly)
                }

                Section {
                    if sourceManager.remoteSources.isEmpty {
                        ContentUnavailableView(
                            AppLocalization.text("source.repository.empty", "Source index not loaded"),
                            systemImage: "tray",
                            description: Text(AppLocalization.text("source.repository.empty_hint", "Enter your source index URL, then refresh."))
                        )
                    } else if filteredRemoteSources.isEmpty {
                        ContentUnavailableView(
                            AppLocalization.text("source.repository.no_matches", "No matching sources"),
                            systemImage: "magnifyingglass",
                            description: Text(AppLocalization.text("source.repository.no_matches_hint", "Try a different keyword or clear the installed-only filter."))
                        )
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
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .installed(let key):
            if let source = sourceManager.installedSource(for: key) {
                SourceDetailView(
                    vm: vm,
                    sourceManager: sourceManager,
                    login: vm.login,
                    source: source
                )
                .frame(minWidth: 520)
            } else {
                emptyDetail
            }
        case .remote(let key):
            if let item = sourceManager.remoteSources.first(where: { sourceManager.resolvedKey(for: $0) == key }) {
                MacRemoteSourceDetailView(sourceManager: sourceManager, item: item)
            } else {
                emptyDetail
            }
        case .index, nil:
            MacSourceIndexDetailView(sourceManager: sourceManager)
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

    private var paneTitle: String {
        (pane ?? .installed).title
    }

    private var activeSearchBinding: Binding<String> {
        switch pane ?? .installed {
        case .installed:
            return $installedQuery
        case .index:
            return $remoteQuery
        }
    }

    private var searchPrompt: String {
        switch pane ?? .installed {
        case .installed:
            return AppLocalization.text("source.management.search_placeholder", "Search installed sources")
        case .index:
            return AppLocalization.text("source.repository.search_placeholder", "Search source index")
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.text("source.management.repository", "Source Index"))
                .font(.body.weight(.medium))
            Text(sourceManager.lastRemoteRefreshDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(sourceManager.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
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
        .navigationTitle(AppLocalization.text("source.management.repository", "Source Index"))
        .frame(minWidth: 520)
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
        .navigationTitle(item.name)
        .frame(minWidth: 520)
    }
}
#endif
