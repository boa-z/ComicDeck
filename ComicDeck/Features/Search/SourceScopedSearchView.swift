import SwiftUI

@MainActor
struct SourceScopedSearchView: View {
    @Bindable var vm: ReaderViewModel
    let sourceKey: String
    let initialKeyword: String

    @Environment(LibraryViewModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue
    @State private var didInitialSearch = false
    @State private var model: SearchScreenModel
    @State private var showSearchSettings = false

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    init(vm: ReaderViewModel, sourceKey: String, initialKeyword: String) {
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
        searchWorkspace
            .navigationTitle(sourceTitle)
            .searchable(
                text: Binding(
                    get: { model.keyword },
                    set: { model.keyword = $0 }
                ),
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "Search keyword"
            )
            .onSubmit(of: .search) {
                Task { await search(model.keyword, sourceKey: sourceKey) }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ComicBrowseModePicker(mode: Binding(
                        get: { browseMode },
                        set: { browseMode = $0 }
                    ))
                    Button {
                        showSearchSettings = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    Button("Done") { dismiss() }
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
            }
            .task {
                guard !didInitialSearch else { return }
                didInitialSearch = true
                await search(initialKeyword, sourceKey: sourceKey)
            }
    }

    @ViewBuilder
    private var searchWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                searchOverviewCard
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.top, AppSpacing.md)

                if !quickCardGroups.isEmpty {
                    searchQuickCardsSection
                }

                if !model.recentKeywords.isEmpty {
                    recentKeywordsSection
                }

                if model.results.isEmpty {
                    emptyState
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.bottom, AppSpacing.xl)
                } else if browseMode == .list {
                    listResults
                } else {
                    gridResults
                }

                if model.searchHasMore {
                    loadMoreButton
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.bottom, AppSpacing.xl)
                }
            }
        }
        .background(AppSurface.grouped.ignoresSafeArea())
    }

    private var listResults: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader(title: "Results", subtitle: "\(model.results.count) comics")
                .padding(.horizontal, AppSpacing.md)

            LazyVStack(spacing: AppSpacing.md) {
                ForEach(model.results) { item in
                    resultNavigationLink(for: item) {
                        SearchResultCard(item: item)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.md)
        }
    }

    private var gridResults: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader(title: "Results", subtitle: "\(model.results.count) comics")
                .padding(.horizontal, AppSpacing.md)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: AppSpacing.md),
                GridItem(.flexible(), spacing: AppSpacing.md)
            ], spacing: AppSpacing.md) {
                ForEach(model.results) { item in
                    resultNavigationLink(for: item) {
                        SearchResultGridCard(item: item)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.md)
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
                    Label("Load More", systemImage: "arrow.down.circle")
                }
                Spacer()
            }
        }
        .disabled(model.isSearching)
        .buttonStyle(.bordered)
    }

    private func resultNavigationLink<Label: View>(
        for item: ComicSummary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink {
            ComicDetailView(vm: vm, item: item) { tag, tagSourceKey in
                Task { await search(tag, sourceKey: tagSourceKey) }
            }
            .environment(library)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

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

    private var searchOverviewCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                VStack(alignment: .leading, spacing: AppSpacing.xs) {
                    Text(sourceTitle)
                        .font(.headline)
                    Text(searchOverviewSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if model.isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: AppSpacing.sm) {
                statusPill(title: "Mode", value: browseMode.title)
                statusPill(title: "Results", value: "\(model.results.count)")
                switch model.lastSearchTrigger {
                case .keyword:
                    statusPill(title: "Context", value: "Keyword")
                case .tag:
                    statusPill(title: "Context", value: "Tag")
                }
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .appCardStyle()
    }

    private var searchOverviewSubtitle: String {
        switch model.lastSearchTrigger {
        case .keyword:
            let keyword = model.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            if keyword.isEmpty {
                return "Search this source directly."
            }
            return "Searching for “\(keyword)”"
        case .tag(let tag):
            return "Results started from the tag “\(tag)”."
        }
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: model.isSearching ? "hourglass" : "text.magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(model.isSearching ? "Searching..." : "No results")
                .foregroundStyle(.secondary)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(AppSpacing.lg)
        .appCardStyle()
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var quickCardGroups: [(index: Int, group: SearchOptionGroup)] {
        Array(vm.login.searchOptionGroups.enumerated())
            .filter { _, group in
                group.type != "multi-select" && !group.options.isEmpty
            }
            .map { (index: $0.offset, group: $0.element) }
    }

    @ViewBuilder
    private var searchQuickCardsSection: some View {
        if !quickCardGroups.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                sectionHeader(title: "Quick Filters", subtitle: "Source-defined shortcuts")
                    .padding(.horizontal, AppSpacing.md)

                ForEach(quickCardGroups, id: \.group.id) { pair in
                    let index = pair.index
                    let group = pair.group
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text(group.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AppSpacing.md)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppSpacing.sm) {
                                ForEach(group.options, id: \.id) { option in
                                    Button {
                                        Task { await applyQuickOption(index: index, value: option.value) }
                                    } label: {
                                        Text(option.label)
                                            .font(.subheadline)
                                            .padding(.horizontal, AppSpacing.md)
                                            .padding(.vertical, AppSpacing.sm)
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
                            .padding(.horizontal, AppSpacing.md)
                        }
                    }
                }
            }
            .padding(.vertical, AppSpacing.sm)
            .background(AppSurface.grouped)
        }
    }

    private var recentKeywordsSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            sectionHeader(title: "Recent Keywords", subtitle: "Tap to search again")
                .padding(.horizontal, AppSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(model.recentKeywords, id: \.self) { keyword in
                        Button {
                            model.keyword = keyword
                            Task { await search(keyword, sourceKey: sourceKey) }
                        } label: {
                            Text(keyword)
                                .font(.subheadline)
                                .padding(.horizontal, AppSpacing.md)
                                .padding(.vertical, AppSpacing.sm)
                                .background(AppSurface.subtle)
                                .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppSpacing.md)
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .background(AppSurface.grouped)
    }

    private func isOptionSelected(index: Int, value: String) -> Bool {
        vm.login.searchOptionValues.indices.contains(index) && vm.login.searchOptionValues[index] == value
    }

    private func applyQuickOption(index: Int, value: String) async {
        vm.login.updateSearchOption(at: index, value: value)
        await search(model.keyword, sourceKey: sourceKey)
    }
}
