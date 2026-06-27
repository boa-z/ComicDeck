#if os(macOS)
import Observation
import SwiftUI

@MainActor
struct MacSearchWorkspaceView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var model = SearchScreenModel()
    @State private var showSearchSettings = false
    @State private var detailItem: ComicSummary?
    @State private var selectedResultID: ComicSummary.ID?
    @State private var selectionCommandController = MacSelectionCommandController()
    @State private var searchCommandController = MacSearchCommandController()
    @State private var isSearchPresented = true
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    private var installedSources: [InstalledSource] {
        vm.sourceManager.installedSources
    }

    private var activeSourceTitle: String {
        installedSources.first { $0.key == vm.sourceManager.selectedSourceKey }?.name
            ?? AppLocalization.text("search.no_source_installed", "No source installed")
    }

    private var selectedResult: ComicSummary? {
        guard let selectedResultID else { return nil }
        return model.results.first { $0.id == selectedResultID }
    }

    private var resultIDs: [ComicSummary.ID] {
        model.results.map(\.id)
    }

    var body: some View {
        NavigationSplitView {
            filterSidebar
                .navigationTitle(AppLocalization.text("search.title", "Search"))
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            resultsPane
        }
        .searchable(
            text: Binding(
                get: { model.keyword },
                set: { model.keyword = $0 }
            ),
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: AppLocalization.text("search.placeholder", "Search keyword")
        )
        .onSubmit(of: .search) {
            Task { await performSearch() }
        }
        .onAppear {
            configureSelectionCommands()
            configureSearchCommands()
        }
        .onChange(of: selectedResultID) { _, _ in
            configureSelectionCommands()
        }
        .onChange(of: resultIDs) { _, _ in
            reconcileResultSelection()
            configureSelectionCommands()
        }
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
        .focusedSceneValue(\.macSearchCommandController, searchCommandController)
        .frame(minWidth: 880, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalization.text("common.done", "Done")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isSearching {
                    ProgressView().controlSize(.small)
                }
                ComicBrowseModePicker(mode: Binding(
                    get: { browseMode },
                    set: { browseMode = $0 }
                ))
            }
        }
        .sheet(isPresented: $showSearchSettings) {
            SearchSettingsSheet(
                model: model,
                vm: vm,
                onPickRecentKeyword: { keyword in
                    model.keyword = keyword
                    Task { await performSearch() }
                }
            )
            .platformPresentationDetentsMediumLarge()
        }
        .sheet(item: $detailItem) { item in
            NavigationStack {
                ComicDetailRoutingView(vm: vm, item: item) { tag, sourceKey in
                    Task {
                        await model.searchByTag(
                            tag,
                            sourceKey: sourceKey,
                            using: vm,
                            options: vm.login.searchOptionValues,
                            profile: vm.login.searchFeatureProfile
                        )
                    }
                }
                .environment(library)
            }
            .frame(minWidth: 880, minHeight: 640)
        }
    }

    private func configureSearchCommands() {
        searchCommandController.focusSearch = { isSearchPresented = true }
        searchCommandController.canFocusSearch = true
    }

    // MARK: - Sidebar

    private var filterSidebar: some View {
        List {
            sourcePickerSection
            filterGroupsSection
            recentKeywordsSidebarSection
            searchInfoSection
        }
        .listStyle(.sidebar)
    }

    private var sourcePickerSection: some View {
        Section(AppLocalization.text("search.section.source", "Source")) {
            if installedSources.isEmpty {
                Text(AppLocalization.text("search.no_source_installed", "No source installed"))
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                Picker(AppLocalization.text("search.active_source", "Active Source"), selection: $vm.sourceManager.selectedSourceKey) {
                    ForEach(installedSources) { source in
                        Text(source.name).tag(source.key)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder
    private var filterGroupsSection: some View {
        let groups = vm.login.searchOptionGroups
        if !groups.isEmpty {
            Section(AppLocalization.text("search.filters", "Filters")) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if group.type == "multi-select" {
                        MacMultiSelectFilterRow(
                            group: group,
                            selectedJSON: Binding(
                                get: {
                                    vm.login.searchOptionValues.indices.contains(index)
                                        ? vm.login.searchOptionValues[index] : "[]"
                                },
                                set: { newValue in
                                    vm.login.updateSearchOption(at: index, value: newValue)
                                }
                            )
                        )
                    } else {
                        MacSingleSelectFilterRow(
                            group: group,
                            selection: Binding(
                                get: {
                                    vm.login.searchOptionValues.indices.contains(index)
                                        ? vm.login.searchOptionValues[index] : ""
                                },
                                set: { newValue in
                                    vm.login.updateSearchOption(at: index, value: newValue)
                                }
                            )
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var recentKeywordsSidebarSection: some View {
        if !model.recentKeywords.isEmpty {
            Section(AppLocalization.text("search.recent", "Recent")) {
                ForEach(model.recentKeywords.prefix(8), id: \.self) { keyword in
                    Button {
                        model.keyword = keyword
                        Task { await performSearch() }
                    } label: {
                        Label(keyword, systemImage: "clock")
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                Button(AppLocalization.text("search.clear_history", "Clear History"), role: .destructive) {
                    model.clearRecentKeywords()
                }
                .font(.caption)
            }
        }
    }

    private var searchInfoSection: some View {
        Section(AppLocalization.text("common.status", "Status")) {
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }

    // MARK: - Results Pane

    private var resultsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if !quickCardGroups.isEmpty {
                    quickFiltersBar
                }

                if searchContextVisible {
                    contextBar
                }

                if model.results.isEmpty {
                    emptyState
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.top, AppSpacing.xl)
                } else {
                    resultsHeader
                    resultsContent
                        .padding(.horizontal, AppSpacing.lg)
                }

                if model.searchHasMore {
                    loadMoreButton
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.vertical, AppSpacing.md)
                }
            }
            .padding(.vertical, AppSpacing.md)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
    }

    private var resultsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.text("search.results", "Results"))
                    .font(.title3.weight(.semibold))
                Text(AppLocalization.format("search.results_from_source", "%lld comics from %@", Int64(model.results.count), activeSourceTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSearchSettings = true
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel(AppLocalization.text("search.action.open_filters", "Open search filters"))
            .help(AppLocalization.text("search.settings.navigation", "Search Settings"))
        }
        .padding(.horizontal, AppSpacing.lg)
    }

    @ViewBuilder
    private var resultsContent: some View {
        if browseMode == .list {
            LazyVStack(spacing: AppSpacing.md) {
                ForEach(model.results) { item in
                    resultNavigationLink(for: item) {
                        SearchResultCard(item: item)
                    }
                    .background(resultSelectionBackground(for: item))
                }
            }
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 240), spacing: AppSpacing.md)
                ],
                spacing: AppSpacing.md
            ) {
                ForEach(model.results) { item in
                    resultNavigationLink(for: item) {
                        SearchResultGridCard(item: item)
                    }
                    .background(resultSelectionBackground(for: item))
                }
            }
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await loadMore() }
        } label: {
            HStack {
                Spacer()
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Label(AppLocalization.text("common.load_more", "Load More"), systemImage: "arrow.down.circle")
                }
                Spacer()
            }
        }
        .disabled(model.isSearching)
        .buttonStyle(.bordered)
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: model.isSearching ? "hourglass" : "text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            if model.isSearching {
                Text(AppLocalization.text("search.searching", "Searching..."))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else if model.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(AppLocalization.text("search.empty_hint", "Type a keyword and press Return to search"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } else {
                Text(AppLocalization.text("search.no_results_found", "No results found"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .padding(AppSpacing.xl)
        .appCardStyle()
    }

    // MARK: - Quick Filters

    private var quickCardGroups: [(index: Int, group: SearchOptionGroup)] {
        Array(vm.login.searchOptionGroups.enumerated())
            .filter { _, group in
                group.type != "multi-select" && !group.options.isEmpty
            }
            .map { (index: $0.offset, group: $0.element) }
    }

    @ViewBuilder
    private var quickFiltersBar: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ForEach(quickCardGroups, id: \.group.id) { pair in
                let index = pair.index
                let group = pair.group
                HStack(spacing: AppSpacing.sm) {
                    Text(group.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.xs) {
                            ForEach(group.options, id: \.id) { option in
                                Button {
                                    Task { await applyQuickOption(index: index, value: option.value) }
                                } label: {
                                    Text(option.label)
                                        .font(.caption)
                                        .padding(.horizontal, AppSpacing.sm)
                                        .padding(.vertical, 4)
                                        .background(
                                            isOptionSelected(index: index, value: option.value)
                                                ? AppTint.accent.opacity(0.18)
                                                : AppSurface.subtle
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous)
                                                .stroke(
                                                    isOptionSelected(index: index, value: option.value)
                                                        ? AppTint.accent.opacity(0.45)
                                                        : Color.clear,
                                                    lineWidth: 1
                                                )
                                        }
                                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AppSpacing.lg)
    }

    // MARK: - Context Bar

    private var searchContextVisible: Bool {
        !model.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var contextBar: some View {
        HStack(spacing: AppSpacing.sm) {
            contextChip(title: activeSourceTitle, systemImage: "antenna.radiowaves.left.and.right")
            switch model.lastSearchTrigger {
            case .keyword:
                contextChip(title: "Keyword", systemImage: "text.magnifyingglass")
            case .tag(let tag):
                contextChip(title: "#\(tag)", systemImage: "tag")
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.lg)
    }

    private func contextChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 4)
            .background(AppSurface.subtle)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
    }

    // MARK: - Navigation

    private func resultNavigationLink<Label: View>(
        for item: ComicSummary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            openResult(item)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(AppLocalization.text("common.open", "Open"), systemImage: "arrow.up.right.square") {
                openResult(item)
            }
            Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
                copyResultTitle(item)
            }
            Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
                copyResultID(item)
            }
            Button(AppLocalization.text("search.action.copy_source", "Copy Source"), systemImage: "shippingbox") {
                copyResultSource(item)
            }
        }
    }

    @ViewBuilder
    private func resultSelectionBackground(for item: ComicSummary) -> some View {
        if selectedResultID == item.id {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .fill(AppTint.accent.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                        .stroke(AppTint.accent.opacity(0.45), lineWidth: 1)
                }
        }
    }

    // MARK: - Actions

    private func performSearch() async {
        await model.performSearch(
            using: vm,
            sourceKey: vm.sourceManager.selectedSourceKey,
            options: vm.login.searchOptionValues,
            profile: vm.login.searchFeatureProfile,
            append: false
        )
        reconcileResultSelection()
        configureSelectionCommands()
    }

    private func loadMore() async {
        await model.performSearch(
            using: vm,
            sourceKey: vm.sourceManager.selectedSourceKey,
            options: vm.login.searchOptionValues,
            profile: vm.login.searchFeatureProfile,
            append: true
        )
        reconcileResultSelection()
        configureSelectionCommands()
    }

    private func applyQuickOption(index: Int, value: String) async {
        vm.login.updateSearchOption(at: index, value: value)
        await performSearch()
    }

    private func isOptionSelected(index: Int, value: String) -> Bool {
        vm.login.searchOptionValues.indices.contains(index) && vm.login.searchOptionValues[index] == value
    }

    private func openResult(_ item: ComicSummary) {
        selectedResultID = item.id
        detailItem = item
    }

    private func copyResultTitle(_ item: ComicSummary) {
        selectedResultID = item.id
        PlatformPasteboard.copy(item.title)
    }

    private func copyResultID(_ item: ComicSummary) {
        selectedResultID = item.id
        PlatformPasteboard.copy(item.id)
    }

    private func copyResultSource(_ item: ComicSummary) {
        selectedResultID = item.id
        PlatformPasteboard.copy(item.sourceKey)
    }

    private func reconcileResultSelection() {
        if selectedResultID == nil {
            selectedResultID = model.results.first?.id
        } else if selectedResult == nil {
            selectedResultID = model.results.first?.id
        }
    }

    private func configureSelectionCommands() {
        selectionCommandController.reset()
        guard let item = selectedResult else { return }

        selectionCommandController.open = { openResult(item) }
        selectionCommandController.copyTitle = { copyResultTitle(item) }
        selectionCommandController.copyID = { copyResultID(item) }
        selectionCommandController.export = { copyResultSource(item) }
        selectionCommandController.exportTitle = AppLocalization.text("search.action.copy_source", "Copy Source")
        selectionCommandController.canOpen = true
        selectionCommandController.canCopyTitle = true
        selectionCommandController.canCopyID = true
        selectionCommandController.canExport = true
    }
}

// MARK: - Sidebar Filter Rows

private struct MacSingleSelectFilterRow: View {
    let group: SearchOptionGroup
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker(group.label, selection: $selection) {
                ForEach(group.options) { item in
                    Text(item.label).tag(item.value)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
}

private struct MacMultiSelectFilterRow: View {
    let group: SearchOptionGroup
    @Binding var selectedJSON: String

    var body: some View {
        let selected = parseSelection(selectedJSON)
        VStack(alignment: .leading, spacing: 6) {
            Text(group.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 4) {
                ForEach(group.options) { option in
                    let picked = selected.contains(option.value)
                    Button(option.label) {
                        var next = selected
                        if picked {
                            next.remove(option.value)
                        } else {
                            next.insert(option.value)
                        }
                        selectedJSON = encodeSelection(next)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(picked ? AppTint.accent : .gray.opacity(0.3))
                }
            }
        }
    }

    private func parseSelection(_ json: String) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return Set(array)
    }

    private func encodeSelection(_ values: Set<String>) -> String {
        let sorted = values.sorted()
        guard let data = try? JSONSerialization.data(withJSONObject: sorted),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }
}

// MARK: - Flow Layout (for filter chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
#endif
