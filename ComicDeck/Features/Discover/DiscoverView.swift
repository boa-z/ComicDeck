import SwiftUI
import Observation

@MainActor
struct DiscoverView: View {
    @Bindable var vm: ReaderViewModel
    var onOpenSearch: () -> Void = {}
    @State private var mode: DiscoverMode = .explore

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $mode) {
                    ForEach(DiscoverMode.allCases, id: \.self) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, AppSpacing.md)
                .padding(.top, AppSpacing.sm)
                .padding(.bottom, 6)

                Group {
                    switch mode {
                    case .explore:
                        ExploreView(vm: vm)
                    case .category:
                        CategoryView(vm: vm)
                    }
                }
            }
            .background(AppSurface.grouped)
            .navigationTitle("Discover")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSearch) {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Open search")
                }
            }
        }
    }
}

private enum DiscoverMode: CaseIterable {
    case explore
    case category

    var title: String {
        switch self {
        case .explore: return "Explore"
        case .category: return "Category"
        }
    }
}

@MainActor
struct ExploreView: View {
    @Bindable var vm: ReaderViewModel
    @State private var model = ExploreScreenModel()
    @State private var route: CategoryNavigationTarget?

    var body: some View {
        List {
            Section("Source") {
                if vm.sourceManager.installedSources.isEmpty {
                    Text("No source installed")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Active Source", selection: $vm.sourceManager.selectedSourceKey) {
                        ForEach(vm.sourceManager.installedSources) { source in
                            Text(source.name).tag(source.key)
                        }
                    }
                }
            }

            if !model.pages.isEmpty {
                Section("Explore Pages") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.sm) {
                            ForEach(model.pages) { item in
                                Button(item.title) {
                                    model.selectedPageID = item.id
                                    Task { await model.loadSelectedPage(using: vm, reset: true) }
                                }
                                .buttonStyle(.bordered)
                                .tint(model.selectedPageID == item.id ? .accentColor : nil)
                            }
                        }
                    }
                }
            }

            contentSection

            Section {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .background(AppSurface.grouped)
        .navigationDestination(item: $route) { target in
            switch target {
            case let .category(sourceKey, item):
                CategoryComicsPageView(vm: vm, sourceKey: sourceKey, item: item)
            case let .ranking(sourceKey):
                CategoryRankingPageView(vm: vm, sourceKey: sourceKey, initialProfile: .empty)
            case let .search(sourceKey, keyword):
                SourceScopedSearchView(vm: vm, sourceKey: sourceKey, initialKeyword: keyword)
            }
        }
        .task {
            guard !model.didInitialLoad else { return }
            model.didInitialLoad = true
            await model.reloadExplorePages(using: vm)
        }
        .task(id: vm.sourceManager.selectedSourceKey) {
            guard model.didInitialLoad else { return }
            await model.reloadExplorePages(using: vm)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if model.isLoading && model.comics.isEmpty && model.parts.isEmpty && model.mixedBlocks.isEmpty {
            Section {
                HStack {
                    Spacer()
                    ProgressView("Loading explore...")
                    Spacer()
                }
            }
        } else if let selected = model.pages.first(where: { $0.id == model.selectedPageID }) {
            switch selected.kind {
            case .multiPageComicList:
                Section(selected.title) {
                    ForEach(model.comics) { item in
                        NavigationLink {
                            ComicDetailView(vm: vm, item: item) { tag, sourceKey in
                                let keyword = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !keyword.isEmpty else { return }
                                route = .search(sourceKey: sourceKey, keyword: keyword)
                            }
                        } label: {
                            SearchResultCard(item: item)
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: AppSpacing.md, bottom: 8, trailing: AppSpacing.md))
                        .listRowBackground(Color.clear)
                    }
                    if model.hasMore {
                        loadMoreButton
                    }
                }
            case .singlePageWithMultiPart:
                ForEach(model.parts) { part in
                    Section(part.title) {
                        ForEach(part.comics) { item in
                            NavigationLink {
                                ComicDetailView(vm: vm, item: item) { tag, sourceKey in
                                    let keyword = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                                    guard !keyword.isEmpty else { return }
                                    route = .search(sourceKey: sourceKey, keyword: keyword)
                                }
                            } label: {
                                SearchResultCard(item: item)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: AppSpacing.md, bottom: 8, trailing: AppSpacing.md))
                            .listRowBackground(Color.clear)
                        }
                        if let target = part.viewMore {
                            Button("View More") { openJumpTarget(target: target, fallbackLabel: part.title) }
                        }
                    }
                }
            case .mixed:
                ForEach(model.mixedBlocks) { block in
                    switch block {
                    case let .comics(_, items):
                        Section {
                            ForEach(items) { item in
                                NavigationLink {
                                    ComicDetailView(vm: vm, item: item) { tag, sourceKey in
                                        let keyword = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !keyword.isEmpty else { return }
                                        route = .search(sourceKey: sourceKey, keyword: keyword)
                                    }
                                } label: {
                                    SearchResultCard(item: item)
                                }
                                .listRowInsets(EdgeInsets(top: 8, leading: AppSpacing.md, bottom: 8, trailing: AppSpacing.md))
                                .listRowBackground(Color.clear)
                            }
                        }
                    case let .part(part):
                        Section(part.title) {
                            ForEach(part.comics) { item in
                                NavigationLink {
                                    ComicDetailView(vm: vm, item: item) { tag, sourceKey in
                                        let keyword = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                                        guard !keyword.isEmpty else { return }
                                        route = .search(sourceKey: sourceKey, keyword: keyword)
                                    }
                                } label: {
                                    SearchResultCard(item: item)
                                }
                                .listRowInsets(EdgeInsets(top: 8, leading: AppSpacing.md, bottom: 8, trailing: AppSpacing.md))
                                .listRowBackground(Color.clear)
                            }
                            if let target = part.viewMore {
                                Button("View More") { openJumpTarget(target: target, fallbackLabel: part.title) }
                            }
                        }
                    }
                }
                if model.hasMore {
                    Section {
                        loadMoreButton
                    }
                }
            }
        } else {
            Section {
                Text("No explore page")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var loadMoreButton: some View {
        Button {
            Task { await model.loadMore(using: vm) }
        } label: {
            HStack {
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Load More", systemImage: "arrow.down.circle")
                }
                Spacer()
            }
        }
        .disabled(model.isLoading)
    }

    private func openJumpTarget(target: CategoryJumpTarget, fallbackLabel: String) {
        guard let source = vm.sourceManager.selectedSource else { return }
        switch target.page {
        case "search":
            let keyword = target.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallbackLabel
            guard !keyword.isEmpty else { return }
            route = .search(sourceKey: source.key, keyword: keyword)
        case "category":
            let item = CategoryItemData(
                id: UUID().uuidString,
                label: target.category ?? fallbackLabel,
                target: target
            )
            route = .category(sourceKey: source.key, item: item)
        case "ranking":
            route = .ranking(sourceKey: source.key)
        default:
            model.status = "Unsupported target: \(target.page)"
        }
    }
}

@MainActor
struct CategoryView: View {
    @Bindable var vm: ReaderViewModel
    @State private var model = CategoryScreenModel()
    @State private var navTarget: CategoryNavigationTarget?

    var body: some View {
        List {
            Section("Source") {
                if vm.sourceManager.installedSources.isEmpty {
                    Text("No source installed")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Active Source", selection: $vm.sourceManager.selectedSourceKey) {
                        ForEach(vm.sourceManager.installedSources) { source in
                            Text(source.name).tag(source.key)
                        }
                    }
                }
            }

            if !model.profile.parts.isEmpty {
                Section("Categories") {
                    ForEach(model.profile.parts) { part in
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Text(part.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: AppSpacing.sm) {
                                    ForEach(part.items) { item in
                                        Button(item.label) {
                                            openTarget(item)
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if model.canShowRankingEntry, let source = vm.sourceManager.selectedSource {
                Section("Ranking") {
                    Button {
                        navTarget = .ranking(sourceKey: source.key)
                    } label: {
                        HStack {
                            Image(systemName: "chart.bar.fill")
                            Text("Open Ranking")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.visible)
        .background(AppSurface.grouped)
        .navigationDestination(item: $navTarget) { target in
            switch target {
            case let .category(sourceKey, item):
                CategoryComicsPageView(vm: vm, sourceKey: sourceKey, item: item)
            case let .ranking(sourceKey):
                CategoryRankingPageView(vm: vm, sourceKey: sourceKey, initialProfile: model.rankingProfile)
            case let .search(sourceKey, keyword):
                SourceScopedSearchView(vm: vm, sourceKey: sourceKey, initialKeyword: keyword)
            }
        }
        .task {
            guard !model.didInitialLoad else { return }
            model.didInitialLoad = true
            navTarget = nil
            await model.reload(using: vm)
        }
        .task(id: vm.sourceManager.selectedSourceKey) {
            guard model.didInitialLoad else { return }
            navTarget = nil
            await model.reload(using: vm)
        }
    }

    private func openTarget(_ item: CategoryItemData) {
        guard let source = vm.sourceManager.selectedSource else { return }
        let target = item.target
        if target.page == "search" {
            let keyword = target.keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? item.label
            guard !keyword.isEmpty else {
                model.status = "Search keyword is empty"
                return
            }
            navTarget = .search(sourceKey: source.key, keyword: keyword)
            return
        }
        if target.page == "category" {
            navTarget = .category(sourceKey: source.key, item: item)
        } else {
            model.status = "Unsupported category target: \(target.page)"
        }
    }
}

enum CategoryNavigationTarget: Hashable, Identifiable {
    case category(sourceKey: String, item: CategoryItemData)
    case ranking(sourceKey: String)
    case search(sourceKey: String, keyword: String)

    var id: String {
        switch self {
        case let .category(sourceKey, item):
            return "category:\(sourceKey):\(item.id)"
        case let .ranking(sourceKey):
            return "ranking:\(sourceKey)"
        case let .search(sourceKey, keyword):
            return "search:\(sourceKey):\(keyword)"
        }
    }
}

@MainActor
struct CategoryComicsPageView: View {
    @Bindable var vm: ReaderViewModel
    let sourceKey: String
    let item: CategoryItemData

    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue
    @State private var model: CategoryComicsScreenModel
    @State private var navTarget: CategoryNavigationTarget?

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    init(vm: ReaderViewModel, sourceKey: String, item: CategoryItemData) {
        self.vm = vm
        self.sourceKey = sourceKey
        self.item = item
        _model = State(initialValue: CategoryComicsScreenModel(sourceKey: sourceKey, item: item))
    }

    var body: some View {
        Group {
            if browseMode == .list {
                categoryList
            } else {
                categoryGrid
            }
        }
        .background(AppSurface.grouped)
        .navigationTitle(item.label)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ComicBrowseModePicker(mode: Binding(
                    get: { browseMode },
                    set: { browseMode = $0 }
                ))
            }
        }
        .navigationDestination(item: $navTarget) { target in
            switch target {
            case let .search(sourceKey, keyword):
                SourceScopedSearchView(vm: vm, sourceKey: sourceKey, initialKeyword: keyword)
            case let .category(sourceKey, item):
                CategoryComicsPageView(vm: vm, sourceKey: sourceKey, item: item)
            case let .ranking(sourceKey):
                CategoryRankingPageView(vm: vm, sourceKey: sourceKey, initialProfile: .empty)
            }
        }
        .task {
            guard !model.didInitialLoad else { return }
            model.didInitialLoad = true
            await model.prepareAndLoadInitial(using: vm)
        }
    }

    private var categoryList: some View {
        List {
            categoryFiltersSection
            categoryResultsSection
        }
        .listStyle(.insetGrouped)
    }

    private var categoryGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if !model.optionGroups.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Category Filters")
                            .font(.headline)
                            .padding(.horizontal, AppSpacing.md)
                        categoryFiltersCard
                    }
                }

                if model.results.isEmpty {
                    emptyCategoryState
                        .padding(.horizontal, AppSpacing.md)
                } else {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: AppSpacing.md),
                        GridItem(.flexible(), spacing: AppSpacing.md)
                    ], spacing: AppSpacing.md) {
                        ForEach(model.results) { comic in
                            comicNavigationLink(for: comic) {
                                SearchResultGridCard(item: comic)
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)

                    if model.hasMore {
                        loadMoreCategoryButton
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.bottom, AppSpacing.lg)
                    }
                }
            }
            .padding(.vertical, AppSpacing.md)
        }
    }

    @ViewBuilder
    private var categoryFiltersSection: some View {
        if !model.optionGroups.isEmpty {
            Section("Category Filters") {
                categoryFiltersCard
            }
        }
    }

    private var categoryFiltersCard: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(Array(model.optionGroups.enumerated()), id: \.element.id) { index, group in
                HStack {
                    Text(group.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker(group.label, selection: Binding(
                        get: { model.optionValues.indices.contains(index) ? model.optionValues[index] : "" },
                        set: { newValue in
                            guard model.optionValues.indices.contains(index) else { return }
                            model.optionValues[index] = newValue
                        }
                    )) {
                        ForEach(group.options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            Button {
                Task { await model.loadCategory(using: vm, page: 1, append: false) }
            } label: {
                HStack {
                    Spacer()
                    SwiftUI.Label("Apply Filters", systemImage: "line.3.horizontal.decrease.circle")
                    Spacer()
                }
            }
            .disabled(model.isLoading)
        }
        .appCardStyle()
        .padding(.horizontal, AppSpacing.md)
    }

    @ViewBuilder
    private var categoryResultsSection: some View {
        if model.results.isEmpty {
            Section {
                emptyCategoryState
            }
        } else {
            Section("Comics") {
                ForEach(model.results) { comic in
                    comicNavigationLink(for: comic) {
                        SearchResultCard(item: comic)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: AppSpacing.md, bottom: 8, trailing: AppSpacing.md))
                    .listRowBackground(Color.clear)
                }
                if model.hasMore {
                    loadMoreCategoryButton
                }
            }
        }
    }

    private var emptyCategoryState: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if model.isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading category...")
                    Spacer()
                }
            } else {
                Text("No results")
                    .foregroundStyle(.secondary)
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loadMoreCategoryButton: some View {
        Button {
            Task { await model.loadCategory(using: vm, page: model.page + 1, append: true) }
        } label: {
            HStack {
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    SwiftUI.Label("Load More", systemImage: "arrow.down.circle")
                }
                Spacer()
            }
        }
        .disabled(model.isLoading)
    }

    private func comicNavigationLink<Label: View>(
        for comic: ComicSummary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink {
            ComicDetailView(vm: vm, item: comic) { tag, source in
                let keyword = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyword.isEmpty else { return }
                navTarget = .search(sourceKey: source, keyword: keyword)
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct CategoryRankingPageView: View {
    @Bindable var vm: ReaderViewModel
    let sourceKey: String
    let initialProfile: CategoryRankingProfile

    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue
    @State private var model: CategoryRankingScreenModel
    @State private var navTarget: CategoryNavigationTarget?

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    init(vm: ReaderViewModel, sourceKey: String, initialProfile: CategoryRankingProfile) {
        self.vm = vm
        self.sourceKey = sourceKey
        self.initialProfile = initialProfile
        _model = State(initialValue: CategoryRankingScreenModel(sourceKey: sourceKey, initialProfile: initialProfile))
    }

    var body: some View {
        Group {
            if browseMode == .list {
                rankingList
            } else {
                rankingGrid
            }
        }
        .background(AppSurface.grouped)
        .navigationTitle("Ranking")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ComicBrowseModePicker(mode: Binding(
                    get: { browseMode },
                    set: { browseMode = $0 }
                ))
            }
        }
        .navigationDestination(item: $navTarget) { target in
            switch target {
            case let .search(sourceKey, keyword):
                SourceScopedSearchView(vm: vm, sourceKey: sourceKey, initialKeyword: keyword)
            case let .category(sourceKey, item):
                CategoryComicsPageView(vm: vm, sourceKey: sourceKey, item: item)
            case let .ranking(sourceKey):
                CategoryRankingPageView(vm: vm, sourceKey: sourceKey, initialProfile: .empty)
            }
        }
        .task {
            guard !model.didInitialLoad else { return }
            model.didInitialLoad = true
            await model.prepareAndLoadInitial(using: vm)
        }
    }

    private var rankingList: some View {
        List {
            rankingFiltersSection
            rankingResultsSection
        }
        .listStyle(.insetGrouped)
    }

    private var rankingGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if !model.profile.options.isEmpty {
                    VStack(alignment: .leading, spacing: AppSpacing.sm) {
                        Text("Ranking Filters")
                            .font(.headline)
                            .padding(.horizontal, AppSpacing.md)
                        rankingFiltersCard
                    }
                }

                if model.results.isEmpty {
                    emptyRankingState
                        .padding(.horizontal, AppSpacing.md)
                } else {
                    LazyVGrid(columns: [
                        GridItem(.flexible(), spacing: AppSpacing.md),
                        GridItem(.flexible(), spacing: AppSpacing.md)
                    ], spacing: AppSpacing.md) {
                        ForEach(model.results) { comic in
                            rankingNavigationLink(for: comic) {
                                SearchResultGridCard(item: comic)
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)

                    if model.hasMore {
                        loadMoreRankingButton
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.bottom, AppSpacing.lg)
                    }
                }
            }
            .padding(.vertical, AppSpacing.md)
        }
    }

    @ViewBuilder
    private var rankingFiltersSection: some View {
        if !model.profile.options.isEmpty {
            Section("Ranking Filters") {
                rankingFiltersCard
            }
        }
    }

    private var rankingFiltersCard: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack {
                Text("榜单")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("榜单", selection: Binding(
                    get: { model.selectedOption },
                    set: { model.selectedOption = $0 }
                )) {
                    ForEach(model.profile.options) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .pickerStyle(.menu)
            }
            Button {
                Task { await model.loadRanking(using: vm, page: 1, append: false) }
            } label: {
                HStack {
                    Spacer()
                    SwiftUI.Label("Apply Ranking", systemImage: "chart.line.uptrend.xyaxis")
                    Spacer()
                }
            }
            .disabled(model.isLoading || model.selectedOption.isEmpty)
        }
        .appCardStyle()
        .padding(.horizontal, AppSpacing.md)
    }

    @ViewBuilder
    private var rankingResultsSection: some View {
        if model.results.isEmpty {
            Section {
                emptyRankingState
            }
        } else {
            Section("Comics") {
                ForEach(model.results) { comic in
                    rankingNavigationLink(for: comic) {
                        SearchResultCard(item: comic)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: AppSpacing.md, bottom: 8, trailing: AppSpacing.md))
                    .listRowBackground(Color.clear)
                }
                if model.hasMore {
                    loadMoreRankingButton
                }
            }
        }
    }

    private var emptyRankingState: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            if model.isLoading {
                HStack {
                    Spacer()
                    ProgressView("Loading ranking...")
                    Spacer()
                }
            } else {
                Text("No ranking data")
                    .foregroundStyle(.secondary)
            }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loadMoreRankingButton: some View {
        Button {
            Task { await model.loadRanking(using: vm, page: model.page + 1, append: true) }
        } label: {
            HStack {
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    SwiftUI.Label("Load More", systemImage: "arrow.down.circle")
                }
                Spacer()
            }
        }
        .disabled(model.isLoading)
    }

    private func rankingNavigationLink<Label: View>(
        for comic: ComicSummary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink {
            ComicDetailView(vm: vm, item: comic) { tag, source in
                let keyword = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !keyword.isEmpty else { return }
                navTarget = .search(sourceKey: source, keyword: keyword)
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }
}
