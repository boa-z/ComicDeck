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

    private struct RemoteSourceRowSnapshot: Identifiable {
        let id: String
        let item: SourceConfigIndexItem
        let key: String
        let isInstalled: Bool
        let updateVersion: String?
    }

    private struct InstalledSourceRowSnapshot: Identifiable {
        let id: String
        let source: InstalledSource
        let isActive: Bool
        let isBatchSelected: Bool
        let updateVersion: String?
    }

    private struct SourceWorkspaceSnapshot {
        let installedRows: [InstalledSourceRowSnapshot]
        let remoteRows: [RemoteSourceRowSnapshot]
        let selectedInstalledSources: [InstalledSource]
        let selectedUpdatableSources: [InstalledSource]
        let allUpdatableSources: [InstalledSource]

        init(
            installedSources: [InstalledSource],
            remoteSources: [SourceConfigIndexItem],
            selectedSourceKey: String?,
            availableUpdates: [String: String],
            batchSelection: Set<String>,
            normalizedQuery: String,
            showInstalledOnly: Bool,
            resolvedKey: (SourceConfigIndexItem) -> String
        ) {
            let installedKeys = Self.installedKeySet(from: installedSources)
            var installedRows: [InstalledSourceRowSnapshot] = []
            installedRows.reserveCapacity(installedSources.count)
            var selectedInstalledSources: [InstalledSource] = []
            var selectedUpdatableSources: [InstalledSource] = []
            var allUpdatableSources: [InstalledSource] = []

            for source in installedSources {
                let updateVersion = availableUpdates[source.key]
                if updateVersion != nil {
                    allUpdatableSources.append(source)
                }
                if batchSelection.contains(source.key) {
                    selectedInstalledSources.append(source)
                    if updateVersion != nil {
                        selectedUpdatableSources.append(source)
                    }
                }
                guard Self.matches(source.name, normalizedQuery: normalizedQuery) ||
                    Self.matches(source.key, normalizedQuery: normalizedQuery)
                else {
                    continue
                }
                installedRows.append(InstalledSourceRowSnapshot(
                    id: source.key,
                    source: source,
                    isActive: source.key == selectedSourceKey,
                    isBatchSelected: batchSelection.contains(source.key),
                    updateVersion: updateVersion
                ))
            }

            var remoteRows: [RemoteSourceRowSnapshot] = []
            remoteRows.reserveCapacity(remoteSources.count)
            for item in remoteSources {
                let key = resolvedKey(item)
                let isInstalled = installedKeys.contains(key)
                guard !showInstalledOnly || isInstalled else { continue }
                guard Self.matches(key, normalizedQuery: normalizedQuery) ||
                    Self.matches(item.name, normalizedQuery: normalizedQuery) ||
                    Self.matches(item.description ?? "", normalizedQuery: normalizedQuery)
                else {
                    continue
                }
                remoteRows.append(RemoteSourceRowSnapshot(
                    id: "\(key)|\(item.id)",
                    item: item,
                    key: key,
                    isInstalled: isInstalled,
                    updateVersion: availableUpdates[key]
                ))
            }

            self.installedRows = installedRows
            self.remoteRows = remoteRows
            self.selectedInstalledSources = selectedInstalledSources
            self.selectedUpdatableSources = selectedUpdatableSources
            self.allUpdatableSources = allUpdatableSources
        }

        private static func matches(_ candidate: String, normalizedQuery keyword: String) -> Bool {
            guard !keyword.isEmpty else { return true }
            return candidate.lowercased().contains(keyword)
        }

        private static func installedKeySet(from sources: [InstalledSource]) -> Set<String> {
            var keys = Set<String>()
            keys.reserveCapacity(sources.count)
            for source in sources {
                keys.insert(source.key)
            }
            return keys
        }
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

    var body: some View {
        let snapshot = makeSnapshot()

        HStack(spacing: 0) {
            unifiedList(snapshot: snapshot)
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
                        Label(AppLocalization.text("common.refresh", "Refresh"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(sourceManager.refreshingIndex)
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if !batchSelection.isEmpty {
                        if !snapshot.selectedUpdatableSources.isEmpty {
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

                    Button(AppLocalization.text("source.repository.check_updates", "Check Updates")) {
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
        .onAppear { ensureSelection(snapshot: snapshot) }
        .onAppear {
            configureSelectionCommands(snapshot: snapshot)
            configureSearchCommands()
        }
        .onChange(of: selection) { _, _ in configureSelectionCommands(snapshot: snapshot) }
        .onChange(of: query) { _, _ in
            ensureSelection(snapshot: snapshot)
            configureSelectionCommands(snapshot: snapshot)
        }
        .onChange(of: showInstalledOnly) { _, _ in
            ensureSelection(snapshot: snapshot)
            configureSelectionCommands(snapshot: snapshot)
        }
        .onChange(of: sourceManager.installedSources) { _, sources in
            guard case let .installed(key) = selection else { return }
            if !sources.contains(where: { $0.key == key }) {
                selection = sources.first.map { .installed($0.key) } ?? .index
            }
            let updatedSnapshot = makeSnapshot()
            configureSelectionCommands(snapshot: updatedSnapshot)
        }
        .onChange(of: sourceManager.remoteSources) { _, _ in
            let updatedSnapshot = makeSnapshot()
            ensureSelection(snapshot: updatedSnapshot)
            configureSelectionCommands(snapshot: updatedSnapshot)
        }
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
        .focusedSceneValue(\.macSearchCommandController, searchCommandController)
    }

    private func configureSearchCommands() {
        searchCommandController.focusSearch = { isSearchPresented = true }
        searchCommandController.canFocusSearch = true
    }

    private func makeSnapshot() -> SourceWorkspaceSnapshot {
        SourceWorkspaceSnapshot(
            installedSources: sourceManager.installedSources,
            remoteSources: sourceManager.remoteSources,
            selectedSourceKey: sourceManager.selectedSourceKey,
            availableUpdates: sourceManager.availableSourceUpdates,
            batchSelection: batchSelection,
            normalizedQuery: normalizedQuery,
            showInstalledOnly: showInstalledOnly,
            resolvedKey: { sourceManager.resolvedKey(for: $0) }
        )
    }

    // MARK: - Unified list

    private func unifiedList(snapshot: SourceWorkspaceSnapshot) -> some View {
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
                if snapshot.installedRows.isEmpty {
                    Text(sourceManager.installedSources.isEmpty
                         ? AppLocalization.text("source.management.empty", "No installed sources")
                         : AppLocalization.text("source.management.no_matches_title", "No matching sources"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.installedRows) { row in
                        MacInstalledSourceRow(
                            source: row.source,
                            isActive: row.isActive,
                            updateVersion: row.updateVersion,
                            isBatchSelected: row.isBatchSelected
                        )
                        .tag(DetailSelection.installed(row.source.key))
                        .contextMenu {
                            installedRowContextMenu(for: row.source)
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
                    Text(AppLocalization.text("source.repository.empty_title", "Source index not loaded"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if snapshot.remoteRows.isEmpty {
                    Text(AppLocalization.text("source.repository.no_matches_title", "No matching sources"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.remoteRows) { row in
                        MacRemoteSourceRow(
                            item: row.item,
                            key: row.key,
                            isInstalled: row.isInstalled,
                            updateVersion: row.updateVersion
                        )
                        .tag(DetailSelection.remote(row.key))
                        .contextMenu {
                            remoteRowContextMenu(for: row)
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
    private func remoteRowContextMenu(for row: RemoteSourceRowSnapshot) -> some View {
        Button(row.isInstalled ? AppLocalization.text("source.action.update", "Update") : AppLocalization.text("source.repository.install", "Install")) {
            Task { await installRemoteSource(row.item) }
        }
        .disabled(sourceManager.isOperating(on: row.key))

        Divider()

        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyRemoteSourceTitle(row.item)
        }

        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyRemoteSourceKey(row)
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
                .navigationSubtitle(AppLocalization.text("source.repository.status.installed", "Installed"))
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

    private func ensureSelection(snapshot: SourceWorkspaceSnapshot) {
        guard selection == nil else { return }
        selection = snapshot.installedRows.first.map { .installed($0.source.key) } ?? .index
    }

    // MARK: - Batch operations

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var hasAvailableUpdates: Bool {
        !sourceManager.availableSourceUpdates.isEmpty
    }

    private func updateAllInstalledSources() async {
        guard !batchWorking else { return }
        let targets = makeSnapshot().allUpdatableSources
        guard !targets.isEmpty else { return }
        batchWorking = true
        defer { batchWorking = false }
        for source in targets {
            await sourceManager.updateSource(source)
        }
    }

    private func updateSelectedSources() async {
        guard !batchWorking else { return }
        let targets = makeSnapshot().selectedUpdatableSources
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
        let targets = makeSnapshot().selectedInstalledSources
        guard !targets.isEmpty else { return }
        batchWorking = true
        defer { batchWorking = false }
        for source in targets {
            await sourceManager.uninstallSource(source)
        }
        batchSelection.removeAll()
    }

    private func configureSelectionCommands(snapshot: SourceWorkspaceSnapshot) {
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
            guard let row = snapshot.remoteRows.first(where: { $0.key == key }) ?? remoteRow(for: key) else { return }
            selectionCommandController.open = { Task { await installRemoteSource(row.item) } }
            selectionCommandController.copyTitle = { copyRemoteSourceTitle(row.item) }
            selectionCommandController.copyID = { copyRemoteSourceKey(row) }
            selectionCommandController.openTitle = row.isInstalled
                ? AppLocalization.text("source.action.update", "Update")
                : AppLocalization.text("source.repository.install", "Install")
            selectionCommandController.canOpen = !sourceManager.isOperating(on: key)
            selectionCommandController.canCopyTitle = true
            selectionCommandController.canCopyID = true
        case .index, nil:
            break
        }
    }

    private func remoteRow(for key: String) -> RemoteSourceRowSnapshot? {
        let installedKeys = installedSourceKeySet()
        guard let item = sourceManager.remoteSources.first(where: { sourceManager.resolvedKey(for: $0) == key }) else {
            return nil
        }
        let isInstalled = installedKeys.contains(key)
        return RemoteSourceRowSnapshot(
            id: "\(key)|\(item.id)",
            item: item,
            key: key,
            isInstalled: isInstalled,
            updateVersion: sourceManager.availableSourceUpdates[key]
        )
    }

    private func installedSourceKeySet() -> Set<String> {
        var keys = Set<String>()
        keys.reserveCapacity(sourceManager.installedSources.count)
        for source in sourceManager.installedSources {
            keys.insert(source.key)
        }
        return keys
    }

    private func useInstalledSource(_ source: InstalledSource) {
        selection = .installed(source.key)
        sourceManager.selectSource(source)
        configureSelectionCommands(snapshot: makeSnapshot())
    }

    private func updateInstalledSource(_ source: InstalledSource) async {
        selection = .installed(source.key)
        await sourceManager.updateSource(source)
        configureSelectionCommands(snapshot: makeSnapshot())
    }

    private func deleteInstalledSource(_ source: InstalledSource) async {
        selection = .installed(source.key)
        await sourceManager.uninstallSource(source)
        if selection == .installed(source.key) {
            selection = makeSnapshot().installedRows.first.map { .installed($0.source.key) } ?? .index
        }
        configureSelectionCommands(snapshot: makeSnapshot())
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
        configureSelectionCommands(snapshot: makeSnapshot())
    }

    private func copyRemoteSourceTitle(_ item: SourceConfigIndexItem) {
        selection = .remote(sourceManager.resolvedKey(for: item))
        PlatformPasteboard.copy(item.name)
    }

    private func copyRemoteSourceKey(_ row: RemoteSourceRowSnapshot) {
        selection = .remote(row.key)
        PlatformPasteboard.copy(row.key)
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

                Toggle(AppLocalization.text("source.repository.auto_load_toggle", "Auto-load source index on open"), isOn: $sourceManager.autoLoadRemoteSources)

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
                LabeledContent(AppLocalization.text("source.repository.metric.installed", "Installed"), value: "\(sourceManager.installedSources.count)")
                LabeledContent(AppLocalization.text("source.management.metric.updates", "Updates"), value: "\(sourceManager.availableSourceUpdates.count)")
                LabeledContent(AppLocalization.text("source.repository.last_refreshed", "Last Refreshed"), value: sourceManager.lastRemoteRefreshDescription)
            }

            Section(AppLocalization.text("common.status", "Status")) {
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
                    Label(AppLocalization.text("common.refresh", "Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(sourceManager.refreshingIndex)

            Button(AppLocalization.text("source.repository.check_updates", "Check Updates")) {
                sourceManager.checkSourceUpdates()
            }

            if !sourceManager.availableSourceUpdates.isEmpty {
                Button {
                    Task { await sourceManager.updateAllSources() }
                } label: {
                    if sourceManager.updatingAll {
                        Label(AppLocalization.text("source.management.status.updating", "Updating..."), systemImage: "square.and.arrow.down")
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
                        Label(AppLocalization.text("source.repository.working", "Working..."), systemImage: "arrow.down.circle")
                    } else if hasUpdate {
                        Label(AppLocalization.text("source.action.update", "Update"), systemImage: "square.and.arrow.down")
                    } else if installed != nil {
                        Label(AppLocalization.text("source.repository.reinstall", "Reinstall"), systemImage: "arrow.clockwise")
                    } else {
                        Label(AppLocalization.text("source.repository.install", "Install"), systemImage: "arrow.down.circle")
                    }
                }
                .disabled(sourceManager.isOperating(on: key))
            }

            if let installed {
                Section(AppLocalization.text("source.repository.status.installed", "Installed")) {
                    LabeledContent(AppLocalization.text("source.detail.version", "Version"), value: installed.version)
                    LabeledContent(AppLocalization.text("source.detail.script", "Script"), value: installed.scriptFileName)
                }
            }

            Section(AppLocalization.text("common.status", "Status")) {
                Text(sourceManager.status)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(item.name)
    }
}
#endif
