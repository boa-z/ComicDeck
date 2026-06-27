#if os(macOS)
import SwiftUI
import Observation

/// macOS Sources workspace.
///
/// Rendered as a stable two-pane HStack inside `MacMainView`'s split view.
/// Installed and indexed sources are folded into a single unified list; the
/// detail pane is always a native `Form/.grouped` view (installed to
/// `MacSourceDetailView`, remote/index to existing detail views).
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
    @State private var selectionCommandController = MacSelectionCommandController()
    @State private var searchCommandController = MacSearchCommandController()
    @State private var isSearchPresented = false

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
        HStack(spacing: 0) {
            unifiedList
                .frame(width: 300)

            Divider()

            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(AppLocalization.text("source.management.title", "Sources"))
        .searchable(
            text: $query,
            isPresented: $isSearchPresented,
            prompt: AppLocalization.text("source.management.search_placeholder", "Search sources")
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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

            ToolbarItem(placement: .primaryAction) {
                Menu {
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

                    Button {
                        Task { await updateAllInstalledSources() }
                    } label: {
                        Label(AppLocalization.text("source.action.update_all", "Update All"), systemImage: "arrow.down.circle")
                    }
                    .disabled(!hasAvailableUpdates || batchWorking)

                    Button(AppLocalization.text("source.action.check_updates", "Check Updates")) {
                        sourceManager.checkSourceUpdates()
                    }
                } label: {
                    if batchWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(AppLocalization.text("tracking.sync.more", "More"), systemImage: "ellipsis.circle")
                    }
                }
                .menuStyle(.button)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(
            AppLocalization.text("source.alert.batch_delete.title", "Delete selected sources?"),
            isPresented: $showBatchDeleteConfirm
        ) {
            Button(AppLocalization.text("source.action.delete", "Delete"), role: .destructive) {
                Task { await deleteSelectedSources() }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) { }
        } message: {
            Text(AppLocalization.format("source.alert.batch_delete.message", "Delete %lld selected installed sources? This action cannot be undone.", Int64(batchSelection.count)))
        }
        .onAppear { ensureSelection() }
        .onAppear {
            configureSelectionCommands()
            configureSearchCommands()
        }
        .onChange(of: selection) { _, _ in configureSelectionCommands() }
        .onChange(of: query) { _, _ in
            ensureSelection()
            configureSelectionCommands()
        }
        .onChange(of: showInstalledOnly) { _, _ in
            ensureSelection()
            configureSelectionCommands()
        }
        .onChange(of: sourceManager.installedSources) { _, sources in
            guard case let .installed(key) = selection else { return }
            if !sources.contains(where: { $0.key == key }) {
                selection = sources.first.map { .installed($0.key) } ?? .index
            }
            configureSelectionCommands()
        }
        .onChange(of: sourceManager.remoteSources) { _, _ in
            ensureSelection()
            configureSelectionCommands()
        }
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
        .focusedSceneValue(\.macSearchCommandController, searchCommandController)
    }

    private func configureSearchCommands() {
        searchCommandController.focusSearch = { isSearchPresented = true }
        searchCommandController.canFocusSearch = true
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
                        Text(AppLocalization.format("source.management.batch_count_format", "%lld selected", Int64(batchSelection.count)))
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
                        .contextMenu {
                            remoteRowContextMenu(for: item)
                        }
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
            useInstalledSource(source)
        }
        .disabled(source.key == sourceManager.selectedSourceKey)

        if sourceManager.availableSourceUpdates[source.key] != nil {
            Button(AppLocalization.text("source.action.update", "Update")) {
                Task { await updateInstalledSource(source) }
            }
        }

        Button(AppLocalization.text("source.action.delete", "Delete"), role: .destructive) {
            Task { await deleteInstalledSource(source) }
        }

        Divider()

        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyInstalledSourceTitle(source)
        }

        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyInstalledSourceKey(source)
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

    @ViewBuilder
    private func remoteRowContextMenu(for item: SourceConfigIndexItem) -> some View {
        let key = sourceManager.resolvedKey(for: item)
        Button(sourceManager.installedSource(for: key) == nil ? AppLocalization.text("source.action.install", "Install") : AppLocalization.text("source.action.update", "Update")) {
            Task { await installRemoteSource(item) }
        }
        .disabled(sourceManager.isOperating(on: key))

        Divider()

        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyRemoteSourceTitle(item)
        }

        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyRemoteSourceKey(item)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationSubtitle(AppLocalization.text("source.detail.installed", "Installed"))
            } else {
                emptyDetail
            }
        case .remote(let key):
            if let item = sourceManager.remoteSources.first(where: { sourceManager.resolvedKey(for: $0) == key }) {
                MacRemoteSourceDetailView(sourceManager: sourceManager, item: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyDetail
            }
        case .index, nil:
            MacSourceIndexDetailView(sourceManager: sourceManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func configureSelectionCommands() {
        selectionCommandController.reset()

        switch selection {
        case .installed(let key):
            guard let source = sourceManager.installedSource(for: key) else { return }
            selectionCommandController.open = { useInstalledSource(source) }
            selectionCommandController.delete = { Task { await deleteInstalledSource(source) } }
            selectionCommandController.copyTitle = { copyInstalledSourceTitle(source) }
            selectionCommandController.copyID = { copyInstalledSourceKey(source) }
            selectionCommandController.export = { Task { await updateInstalledSource(source) } }
            selectionCommandController.openTitle = AppLocalization.text("source.action.use", "Use Source")
            selectionCommandController.exportTitle = AppLocalization.text("source.action.update", "Update")
            selectionCommandController.canOpen = source.key != sourceManager.selectedSourceKey
            selectionCommandController.canDelete = true
            selectionCommandController.canCopyTitle = true
            selectionCommandController.canCopyID = true
            selectionCommandController.canExport = sourceManager.availableSourceUpdates[source.key] != nil
        case .remote(let key):
            guard let item = sourceManager.remoteSources.first(where: { sourceManager.resolvedKey(for: $0) == key }) else { return }
            selectionCommandController.open = { Task { await installRemoteSource(item) } }
            selectionCommandController.copyTitle = { copyRemoteSourceTitle(item) }
            selectionCommandController.copyID = { copyRemoteSourceKey(item) }
            selectionCommandController.openTitle = sourceManager.installedSource(for: key) == nil
                ? AppLocalization.text("source.action.install", "Install")
                : AppLocalization.text("source.action.update", "Update")
            selectionCommandController.canOpen = !sourceManager.isOperating(on: key)
            selectionCommandController.canCopyTitle = true
            selectionCommandController.canCopyID = true
        case .index, nil:
            break
        }
    }

    private func useInstalledSource(_ source: InstalledSource) {
        selection = .installed(source.key)
        sourceManager.selectSource(source)
        configureSelectionCommands()
    }

    private func updateInstalledSource(_ source: InstalledSource) async {
        selection = .installed(source.key)
        await sourceManager.updateSource(source)
        configureSelectionCommands()
    }

    private func deleteInstalledSource(_ source: InstalledSource) async {
        selection = .installed(source.key)
        await sourceManager.uninstallSource(source)
        if selection == .installed(source.key) {
            selection = filteredInstalledSources.first.map { .installed($0.key) } ?? .index
        }
        configureSelectionCommands()
    }

    private func copyInstalledSourceTitle(_ source: InstalledSource) {
        selection = .installed(source.key)
        PlatformPasteboard.copy(source.name)
    }

    private func copyInstalledSourceKey(_ source: InstalledSource) {
        selection = .installed(source.key)
        PlatformPasteboard.copy(source.key)
    }

    private func installRemoteSource(_ item: SourceConfigIndexItem) async {
        let key = sourceManager.resolvedKey(for: item)
        selection = .remote(key)
        await sourceManager.installFromIndex(item)
        configureSelectionCommands()
    }

    private func copyRemoteSourceTitle(_ item: SourceConfigIndexItem) {
        selection = .remote(sourceManager.resolvedKey(for: item))
        PlatformPasteboard.copy(item.name)
    }

    private func copyRemoteSourceKey(_ item: SourceConfigIndexItem) {
        let key = sourceManager.resolvedKey(for: item)
        selection = .remote(key)
        PlatformPasteboard.copy(key)
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
                TextField(AppLocalization.text("source.repository.index_url_placeholder", "index.json URL"), text: $sourceManager.indexURL)
                    .platformTextInputAutocapitalizationNever()
                    .autocorrectionDisabled()

                Toggle(AppLocalization.text("source.management.auto_load_toggle", "Auto-load source index on open"), isOn: $sourceManager.autoLoadRemoteSources)

                ViewThatFits(in: .horizontal) {
                    HStack {
                        indexActionButtons
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        indexActionButtons
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

    @ViewBuilder
    private var indexActionButtons: some View {
        Group {
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
