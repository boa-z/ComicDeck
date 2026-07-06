#if os(macOS)
import SwiftUI
import Observation

@MainActor
struct MacTrackingWorkspaceView: View {
    private enum SidebarItem: Hashable, Identifiable {
        case provider(TrackerProvider)
        case settings

        var id: String {
            switch self {
            case .provider(let provider):
                return provider.rawValue
            case .settings:
                return "settings"
            }
        }

        var title: String {
            switch self {
            case .provider(let provider):
                return provider.title
            case .settings:
                return AppLocalization.text("settings.navigation.title", "Settings")
            }
        }

        var systemImage: String {
            switch self {
            case .provider:
                return "rectangle.stack.badge.person.crop"
            case .settings:
                return "gearshape"
            }
        }
    }

    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @Environment(TrackerViewModel.self) private var tracker
    @Environment(LibraryViewModel.self) private var library
    @State private var selectedSidebarItem: SidebarItem? = .provider(.aniList)
    @State private var selectedRows: [TrackerProvider: TrackerSubscriptionRow] = [:]

    private var selectedProvider: TrackerProvider? {
        guard case let .provider(provider) = selectedSidebarItem else { return nil }
        return provider
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)

            Divider()

            contentPane
                .frame(width: 380)

            Divider()

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(AppLocalization.text("tracking.navigation.title", "Tracking"))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebar: some View {
        List(selection: $selectedSidebarItem) {
            Section(AppLocalization.text("tracking.workspace.providers", "Providers")) {
                ForEach(TrackerProvider.mangaListWorkspaceProviders) { provider in
                    MacTrackingProviderRow(provider: provider, account: tracker.account(for: provider))
                        .tag(SidebarItem.provider(provider))
                }
            }

            Section {
                Label(AppLocalization.text("tracking.workspace.settings", "Tracking Settings"), systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var contentPane: some View {
        if let selectedProvider {
            MacTrackerSubscriptionListView(
                vm: vm,
                sourceManager: sourceManager,
                provider: selectedProvider,
                selection: binding(for: selectedProvider)
            )
            .id(selectedProvider)
        } else {
            TrackingSettingsView()
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let provider = selectedProvider, let row = selectedRows[provider] {
            TrackerSubscriptionDetailView(
                vm: vm,
                sourceManager: sourceManager,
                provider: provider,
                row: row
            )
            .environment(library)
        } else if selectedProvider != nil {
            ContentUnavailableView(
                AppLocalization.text("tracking.workspace.select_entry", "Select an entry"),
                systemImage: "rectangle.stack.badge.person.crop",
                description: Text(AppLocalization.text("tracking.workspace.select_entry_hint", "Choose a tracker library item to review bindings and sync progress."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TrackingSettingsView()
        }
    }

    private func binding(for provider: TrackerProvider) -> Binding<TrackerSubscriptionRow?> {
        Binding {
            selectedRows[provider]
        } set: { row in
            selectedRows[provider] = row
        }
    }
}

private struct MacTrackingProviderRow: View {
    let provider: TrackerProvider
    let account: TrackerAccount?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: account == nil ? "person.crop.circle.badge.exclamationmark" : "checkmark.circle.fill")
                .foregroundStyle(account == nil ? .secondary : AppTint.success)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.title)
                    .font(.body.weight(.medium))
                Text(account?.displayName ?? AppLocalization.text("library.workspace.tracker.disconnected", "Connect"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

@MainActor
private struct MacTrackerSubscriptionListView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    let provider: TrackerProvider
    @Binding var selection: TrackerSubscriptionRow?

    @Environment(TrackerViewModel.self) private var tracker
    @Environment(LibraryViewModel.self) private var library
    @State private var model = TrackerSubscriptionsScreenModel()
    @State private var query = ""
    @State private var selectionCommandController = MacSelectionCommandController()
    @State private var searchCommandController = MacSearchCommandController()
    @State private var isSearchPresented = false

    var body: some View {
        let snapshot = MacTrackerSubscriptionListSnapshot(rows: model.rows, query: query)
        List(selection: rowSelection) {
            Section {
                MacTrackingStatusHeader(provider: provider, model: model, account: tracker.account(for: provider))
            }

            if tracker.account(for: provider) == nil {
                ContentUnavailableView(
                    AppLocalization.format("tracking.subscriptions.connect_required.title_format", "Connect %@ first", provider.title),
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text(AppLocalization.format("tracking.subscriptions.connect_required.message_format", "Connect %@ in Settings > Tracking to load your manga list.", provider.title))
                )
            } else if model.loading && model.rows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if let errorMessage = model.errorMessage, model.rows.isEmpty {
                ContentUnavailableView(
                    AppLocalization.format("tracking.subscriptions.error_format", "Could not load %@", provider.title),
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if snapshot.visibleRows.isEmpty {
                ContentUnavailableView(
                    snapshot.isFiltering
                        ? AppLocalization.text("tracking.subscriptions.no_matches_title", "No matching entries")
                        : AppLocalization.format("tracking.subscriptions.empty_format", "No %@ manga found", provider.title),
                    systemImage: snapshot.isFiltering ? "magnifyingglass" : "tray",
                    description: Text(snapshot.isFiltering
                        ? AppLocalization.text("tracking.subscriptions.no_matches_subtitle", "Try a different keyword or clear the search field.")
                        : AppLocalization.format("tracking.subscriptions.empty.message_format", "Your %@ manga list will appear here after it has entries.", provider.title))
                )
            } else {
                Section(AppLocalization.text("tracking.subscriptions.entries", "Entries")) {
                    ForEach(snapshot.visibleRows) { row in
                        MacTrackerSubscriptionRowView(row: row)
                            .tag(row.id)
                            .contextMenu {
                                subscriptionRowContextMenu(for: row)
                            }
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.format("tracking.subscriptions.title_format", "%@ Library", provider.title))
        .searchable(
            text: $query,
            isPresented: $isSearchPresented,
            prompt: AppLocalization.text("tracking.subscriptions.search", "Search tracker library")
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await loadIfConnected() }
                } label: {
                    if model.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(AppLocalization.text("tracking.subscriptions.refresh", "Refresh"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.loading || tracker.account(for: provider) == nil)
            }
        }
        .task {
            configureSearchCommands()
            await loadIfConnected()
            reconcileSelection()
            configureSelectionCommands()
        }
        .onChange(of: tracker.bindings) { _, _ in
            model.refreshLocalBindings(provider: provider, using: tracker, library: library)
            reconcileSelection()
            configureSelectionCommands()
        }
        .onChange(of: model.rows) { _, _ in
            reconcileSelection()
            configureSelectionCommands()
        }
        .onChange(of: selection) { _, _ in
            configureSelectionCommands()
        }
        .onChange(of: query) { _, _ in
            reconcileSelection()
            configureSelectionCommands()
        }
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
        .focusedSceneValue(\.macSearchCommandController, searchCommandController)
    }

    private func configureSearchCommands() {
        searchCommandController.focusSearch = { isSearchPresented = true }
        searchCommandController.canFocusSearch = true
    }

    private var rowSelection: Binding<String?> {
        Binding {
            selection?.id
        } set: { id in
            selection = model.rows.first { $0.id == id }
        }
    }

    @ViewBuilder
    private func subscriptionRowContextMenu(for row: TrackerSubscriptionRow) -> some View {
        Button(AppLocalization.text("common.open", "Open"), systemImage: "arrow.up.right.square") {
            openSubscription(row)
        }

        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copySubscriptionTitle(row)
        }

        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copySubscriptionID(row)
        }

        Button(AppLocalization.text("tracking.action.copy_provider", "Copy Provider"), systemImage: "rectangle.stack.badge.person.crop") {
            copySubscriptionProvider(row)
        }
    }

    private func loadIfConnected() async {
        guard tracker.account(for: provider) != nil else { return }
        await model.load(provider: provider, using: tracker, library: library)
    }

    private func reconcileSelection() {
        let snapshot = MacTrackerSubscriptionListSnapshot(rows: model.rows, query: query)
        if let selection, snapshot.visibleRows.contains(where: { $0.id == selection.id }) {
            return
        }
        selection = snapshot.visibleRows.first
    }

    private func configureSelectionCommands() {
        selectionCommandController.reset()
        guard let selection else { return }

        selectionCommandController.open = { openSubscription(selection) }
        selectionCommandController.copyTitle = { copySubscriptionTitle(selection) }
        selectionCommandController.copyID = { copySubscriptionID(selection) }
        selectionCommandController.export = { copySubscriptionProvider(selection) }
        selectionCommandController.exportTitle = AppLocalization.text("tracking.action.copy_provider", "Copy Provider")
        selectionCommandController.canOpen = true
        selectionCommandController.canCopyTitle = true
        selectionCommandController.canCopyID = true
        selectionCommandController.canExport = true
    }

    private func openSubscription(_ row: TrackerSubscriptionRow) {
        selection = row
    }

    private func copySubscriptionTitle(_ row: TrackerSubscriptionRow) {
        selection = row
        PlatformPasteboard.copy(row.entry.title)
    }

    private func copySubscriptionID(_ row: TrackerSubscriptionRow) {
        selection = row
        PlatformPasteboard.copy(row.entry.mediaID)
    }

    private func copySubscriptionProvider(_ row: TrackerSubscriptionRow) {
        selection = row
        PlatformPasteboard.copy(provider.title)
    }
}

@MainActor
private struct MacTrackingStatusHeader: View {
    let provider: TrackerProvider
    let model: TrackerSubscriptionsScreenModel
    let account: TrackerAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AppLocalization.format("tracking.subscriptions.title_format", "%@ Library", provider.title))
                .font(.headline)
            Text(account?.displayName ?? AppLocalization.text("library.workspace.tracker.disconnected", "Connect"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Label("\(model.rows.count)", systemImage: "rectangle.stack")
                if let lastLoadedAt = model.lastLoadedAt {
                    Label(lastLoadedText(lastLoadedAt), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func lastLoadedText(_ date: Date) -> String {
        RelativeTimeText.short(from: date)
    }
}

private struct MacTrackerSubscriptionRowView: View {
    let row: TrackerSubscriptionRow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CoverArtworkView(urlString: row.entry.coverURL, refererURLString: row.entry.siteURL, width: 42, height: 58)
                .frame(width: 42, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.entry.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if let subtitle = row.entry.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Label("\(row.entry.progress)", systemImage: "bookmark")
                    if !row.localGroups.isEmpty {
                        Label("\(row.localGroups.count)", systemImage: "link")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
#endif
