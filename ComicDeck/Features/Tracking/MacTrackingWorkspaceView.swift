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
        NavigationSplitView {
            List(selection: $selectedSidebarItem) {
                Section(AppLocalization.text("tracking.workspace.providers", "Providers")) {
                    ForEach(TrackerProvider.allCases.filter(\.supportsMangaListWorkspace)) { provider in
                        MacTrackingProviderRow(provider: provider, account: tracker.account(for: provider))
                            .tag(SidebarItem.provider(provider))
                    }
                }

                Section {
                    Label(AppLocalization.text("tracking.workspace.settings", "Tracking Settings"), systemImage: "gearshape")
                        .tag(SidebarItem.settings)
                }
            }
            .navigationTitle(AppLocalization.text("tracking.navigation.title", "Tracking"))
            .frame(minWidth: 210)
        } content: {
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
        } detail: {
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
        .navigationSplitViewStyle(.balanced)
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

    private var filteredRows: [TrackerSubscriptionRow] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return model.rows }
        return model.rows.filter { row in
            row.entry.title.lowercased().contains(keyword) ||
            (row.entry.subtitle?.lowercased().contains(keyword) ?? false) ||
            row.localGroups.contains { $0.title.lowercased().contains(keyword) }
        }
    }

    var body: some View {
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
            } else if filteredRows.isEmpty {
                ContentUnavailableView(
                    AppLocalization.format("tracking.subscriptions.empty_format", "No %@ manga found", provider.title),
                    systemImage: "tray",
                    description: Text(AppLocalization.text("tracking.subscriptions.empty_hint", "Your tracker library will appear here after it has entries."))
                )
            } else {
                Section(AppLocalization.text("tracking.subscriptions.entries", "Entries")) {
                    ForEach(filteredRows) { row in
                        MacTrackerSubscriptionRowView(row: row)
                            .tag(row.id)
                    }
                }
            }
        }
        .navigationTitle(AppLocalization.format("tracking.subscriptions.title_format", "%@ Library", provider.title))
        .searchable(text: $query, prompt: AppLocalization.text("tracking.subscriptions.search", "Search tracker library"))
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
            await loadIfConnected()
        }
        .onChange(of: tracker.bindings) { _, _ in
            model.refreshLocalBindings(provider: provider, using: tracker, library: library)
        }
        .onChange(of: model.rows) { _, rows in
            guard let current = selection else {
                selection = rows.first
                return
            }
            selection = rows.first(where: { $0.id == current.id }) ?? rows.first
        }
    }

    private var rowSelection: Binding<String?> {
        Binding {
            selection?.id
        } set: { id in
            selection = model.rows.first { $0.id == id }
        }
    }

    private func loadIfConnected() async {
        guard tracker.account(for: provider) != nil else { return }
        await model.load(provider: provider, using: tracker, library: library)
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
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct MacTrackerSubscriptionRowView: View {
    let row: TrackerSubscriptionRow

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CoverArtworkView(urlString: row.entry.coverURL, width: 42, height: 58)
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
