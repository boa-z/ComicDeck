#if os(macOS)
import SwiftUI

/// macOS-specific source-scoped search workspace.
///
/// Presented when the user triggers a tag-based search from a detail view.
/// Uses a split layout with filters in the sidebar and adaptive results grid.
@MainActor
struct MacSourceScopedSearchView: View {
    @Bindable var vm: ReaderViewModel
    let sourceKey: String
    let initialKeyword: String

    @Environment(LibraryViewModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue
    @State private var didInitialSearch = false
    @State private var model: SearchScreenModel
    @State private var showSearchSettings = false
    @State private var detailItem: ComicSummary?
    @State private var searchCommandController = MacSearchCommandController()
    @State private var isSearchPresented = true

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    init(
        vm: ReaderViewModel,
        sourceKey: String,
        initialKeyword: String
    ) {
        self.vm = vm
        self.sourceKey = sourceKey
        self.initialKeyword = initialKeyword
        let model = SearchScreenModel()
        model.keyword = initialKeyword
        _model = State(initialValue: model)
    }

    private var sourceTitle: String {
        vm.sourceManager.installedSources.first(where: { $0.key == sourceKey })?.name ?? sourceKey
    }

    var body: some View {
        let snapshot = SearchPresentationSnapshot(
            results: model.results,
            optionGroups: vm.login.searchOptionGroups,
            recentKeywords: model.recentKeywords
        )

        NavigationSplitView {
            filterSidebar(snapshot: snapshot)
                .navigationTitle(sourceTitle)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            resultsPane(snapshot: snapshot)
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
            Task { await search(model.keyword, sourceKey: sourceKey) }
        }
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
                    Task { await search(keyword, sourceKey: sourceKey) }
                }
            )
            .platformPresentationDetentsMediumLarge()
        }
        .sheet(item: $detailItem) { item in
            NavigationStack {
                ComicDetailRoutingView(vm: vm, item: item) { tag, tagSourceKey in
                    Task { await search(tag, sourceKey: tagSourceKey) }
                }
                .environment(library)
            }
            .frame(minWidth: 880, minHeight: 640)
        }
        .onAppear {
            configureSearchCommands()
        }
        .focusedSceneValue(\.macSearchCommandController, searchCommandController)
        .task {
            guard !didInitialSearch else { return }
            didInitialSearch = true
            await search(initialKeyword, sourceKey: sourceKey)
        }
    }

    private func configureSearchCommands() {
        searchCommandController.focusSearch = { isSearchPresented = true }
        searchCommandController.canFocusSearch = true
    }

    // MARK: - Sidebar

    private func filterSidebar(snapshot: SearchPresentationSnapshot) -> some View {
        List {
            Section(AppLocalization.text("search.section.source", "Source")) {
                Text(sourceTitle)
                    .font(.subheadline.weight(.medium))
            }

            filterGroupsSection
            recentKeywordsSidebarSection(keywords: snapshot.sidebarRecentKeywords)
            searchInfoSection
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var filterGroupsSection: some View {
        let groups = vm.login.searchOptionGroups
        if !groups.isEmpty {
            Section(AppLocalization.text("search.filters", "Filters")) {
                ForEach(groups.indices, id: \.self) { index in
                    let group = groups[index]
                    if group.type == "multi-select" {
                        ScopedMultiSelectRow(
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
                        ScopedSingleSelectRow(
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
    private func recentKeywordsSidebarSection(keywords: [String]) -> some View {
        if !keywords.isEmpty {
            Section(AppLocalization.text("search.recent", "Recent")) {
                ForEach(keywords, id: \.self) { keyword in
                    Button {
                        model.keyword = keyword
                        Task { await search(keyword, sourceKey: sourceKey) }
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

    private func resultsPane(snapshot: SearchPresentationSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                overviewCard
                    .padding(.horizontal, AppSpacing.lg)
                    .padding(.top, AppSpacing.md)

                if !snapshot.quickFilterGroups.isEmpty {
                    quickFiltersBar(groups: snapshot.quickFilterGroups)
                }

                if snapshot.results.isEmpty {
                    emptyState
                        .padding(.horizontal, AppSpacing.lg)
                        .padding(.top, AppSpacing.lg)
                } else {
                    resultsHeader(resultCount: snapshot.results.count)
                    resultsContent(results: snapshot.results)
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

    private var overviewCard: some View {
        HStack(spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(sourceTitle)
                    .font(.headline)
                Text(overviewSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: AppSpacing.sm) {
                statusPill(title: AppLocalization.text("search.layout", "Layout"), value: browseMode.title)
                statusPill(title: AppLocalization.text("search.results", "Results"), value: "\(model.results.count)")
            }
            if model.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .appCardStyle()
    }

    private var overviewSubtitle: String {
        switch model.lastSearchTrigger {
        case .keyword:
            let keyword = model.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            if keyword.isEmpty {
                return AppLocalization.text("search.source_direct_hint", "Search this source directly.")
            }
            return AppLocalization.format("search.searching_for", "Searching for \"%@\"", keyword)
        case .tag(let tag):
            return AppLocalization.format("search.results_started_from_tag", "Results started from the tag \"%@\".", tag)
        }
    }

    private func statusPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, AppSpacing.xs)
        .background(AppSurface.subtle, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func resultsHeader(resultCount: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.text("search.results", "Results"))
                    .font(.title3.weight(.semibold))
                Text(AppLocalization.format("search.results_count", "%lld comics", Int64(resultCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showSearchSettings = true
            } label: {
                Label(AppLocalization.text("search.action.open_filters", "Open search filters"), systemImage: "line.3.horizontal.decrease.circle")
                    .labelStyle(.iconOnly)
            }
            .help(AppLocalization.text("search.settings.navigation", "Search Settings"))
        }
        .padding(.horizontal, AppSpacing.lg)
    }

    @ViewBuilder
    private func resultsContent(results: [ComicSummary]) -> some View {
        if browseMode == .list {
            LazyVStack(spacing: AppSpacing.md) {
                ForEach(results) { item in
                    resultNavigationLink(for: item) {
                        SearchResultCard(item: item)
                    }
                }
            }
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 240), spacing: AppSpacing.md)
                ],
                spacing: AppSpacing.md
            ) {
                ForEach(results) { item in
                    resultNavigationLink(for: item) {
                        SearchResultGridCard(item: item)
                    }
                }
            }
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await loadMore(sourceKey: sourceKey) }
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
            Text(model.isSearching ? AppLocalization.text("search.searching", "Searching...") : AppLocalization.text("search.no_results", "No results"))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .padding(AppSpacing.xl)
        .appCardStyle()
    }

    // MARK: - Quick Filters

    @ViewBuilder
    private func quickFiltersBar(groups: [SearchQuickFilterGroup]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            ForEach(groups) { pair in
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

    // MARK: - Navigation

    private func resultNavigationLink<Label: View>(
        for item: ComicSummary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            detailItem = item
        } label: {
            label()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(AppLocalization.text("common.open", "Open"), systemImage: "arrow.up.right.square") {
                detailItem = item
            }
            Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
                PlatformPasteboard.copy(item.title)
            }
            Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
                PlatformPasteboard.copy(item.id)
            }
            Button(AppLocalization.text("search.action.copy_source", "Copy Source"), systemImage: "shippingbox") {
                PlatformPasteboard.copy(item.sourceKey)
            }
        }
    }

    // MARK: - Actions

    private func search(_ text: String, sourceKey: String) async {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        model.keyword = keyword
        await model.performSearch(
            using: vm,
            sourceKey: sourceKey,
            options: vm.login.searchOptionValues,
            profile: vm.login.searchFeatureProfile,
            append: false,
            trigger: .keyword
        )
    }

    private func loadMore(sourceKey: String) async {
        await model.performSearch(
            using: vm,
            sourceKey: sourceKey,
            options: vm.login.searchOptionValues,
            profile: vm.login.searchFeatureProfile,
            append: true
        )
    }

    private func applyQuickOption(index: Int, value: String) async {
        vm.login.updateSearchOption(at: index, value: value)
        await search(model.keyword, sourceKey: sourceKey)
    }

    private func isOptionSelected(index: Int, value: String) -> Bool {
        vm.login.searchOptionValues.indices.contains(index) && vm.login.searchOptionValues[index] == value
    }
}

// MARK: - Sidebar Filter Rows

private struct ScopedSingleSelectRow: View {
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

private struct ScopedMultiSelectRow: View {
    let group: SearchOptionGroup
    @Binding var selectedJSON: String

    var body: some View {
        let selected = parseSelection(selectedJSON)
        VStack(alignment: .leading, spacing: 6) {
            Text(group.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScopedFlowLayout(spacing: 4) {
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

private struct ScopedFlowLayout: Layout {
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
