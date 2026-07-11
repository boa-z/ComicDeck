import Observation
import SwiftUI

@MainActor
struct SearchView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var model = SearchScreenModel()
    @State private var showSearchSettings = false
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    var body: some View {
        let snapshot = SearchPresentationSnapshot(
            results: model.results,
            optionGroups: vm.login.searchOptionGroups,
            recentKeywords: model.recentKeywords
        )

        NavigationStack {
            searchWorkspace(snapshot: snapshot)
            .background(AppSurface.grouped.ignoresSafeArea())
            .navigationTitle(AppLocalization.text("search.title", "Search"))
            .searchable(
                text: Binding(
                    get: { model.keyword },
                    set: { model.keyword = $0 }
                ),
                prompt: AppLocalization.text("search.placeholder", "Search keyword")
            )
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
            .toolbar {
                ToolbarItem(placement: .platformTopBarLeading) {
                    if model.isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                ToolbarItemGroup(placement: .platformTopBarTrailing) {
                    ComicBrowseModePicker(mode: Binding(
                        get: { browseMode },
                        set: { browseMode = $0 }
                    ))

                    Button {
                        showSearchSettings = true
                    } label: {
                        Label(AppLocalization.text("search.action.open_filters", "Open search filters"), systemImage: "line.3.horizontal.decrease.circle")
                            .labelStyle(.iconOnly)
                    }

                    Button(AppLocalization.text("common.done", "Done")) { dismiss() }
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
            }
        }
    }

    @ViewBuilder
    private func searchWorkspace(snapshot: SearchPresentationSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.md) {
                if !snapshot.quickFilterGroups.isEmpty {
                    searchQuickCardsSection(groups: snapshot.quickFilterGroups)
                        .padding(.top, AppSpacing.md)
                }

                if searchContextVisible {
                    searchContextSection
                }

                if snapshot.hasRecentKeywords {
                    recentKeywordsSection(keywords: snapshot.recentKeywords)
                }

                if snapshot.results.isEmpty {
                    emptyState
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.bottom, AppSpacing.xl)
                } else if browseMode == .list {
                    listResults(results: snapshot.results)
                } else {
                    gridResults(results: snapshot.results)
                }

                if model.searchHasMore {
                    loadMoreButton
                        .padding(.horizontal, AppSpacing.md)
                        .padding(.bottom, AppSpacing.xl)
                }
            }
        }
    }

    private func gridResults(results: [ComicSummary]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader(
                title: AppLocalization.text("search.results", "Results"),
                subtitle: AppLocalization.format("search.results_count", "%lld comics", Int64(results.count))
            )
                .padding(.horizontal, AppSpacing.md)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: AppSpacing.md),
                GridItem(.flexible(), spacing: AppSpacing.md)
            ], spacing: AppSpacing.md) {
                ForEach(results) { item in
                    resultNavigationLink(for: item) {
                        SearchResultGridCard(item: item)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.md)
        }
    }

    private func listResults(results: [ComicSummary]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            sectionHeader(
                title: AppLocalization.text("search.results", "Results"),
                subtitle: AppLocalization.format("search.results_count", "%lld comics", Int64(results.count))
            )
                .padding(.horizontal, AppSpacing.md)

            LazyVStack(spacing: AppSpacing.md) {
                ForEach(results) { item in
                    resultNavigationLink(for: item) {
                        SearchResultCard(item: item)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.md)
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

    private func resultNavigationLink<Label: View>(
        for item: ComicSummary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        NavigationLink {
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
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: AppSpacing.sm) {
            Image(systemName: model.isSearching ? "hourglass" : "text.magnifyingglass")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            if model.isSearching {
                Text(AppLocalization.text("search.searching", "Searching..."))
                    .foregroundStyle(.secondary)
            } else if model.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(AppLocalization.text("search.comics", "Search comics"))
                    .foregroundStyle(.secondary)
            } else {
                Text(AppLocalization.text("search.no_results", "No results"))
                    .foregroundStyle(.secondary)
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(AppSpacing.lg)
        .appCardStyle()
    }

    @ViewBuilder
    private func searchQuickCardsSection(groups: [SearchQuickFilterGroup]) -> some View {
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                sectionHeader(
                    title: AppLocalization.text("search.quick_filters", "Quick Filters"),
                    subtitle: AppLocalization.text("search.quick_filters.subtitle", "Source-defined shortcuts")
                )
                    .padding(.horizontal, AppSpacing.md)

                ForEach(groups) { pair in
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

    private func recentKeywordsSection(keywords: [String]) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            sectionHeader(
                title: AppLocalization.text("search.recent_keywords", "Recent Keywords"),
                subtitle: AppLocalization.text("search.recent_keywords.subtitle", "Tap to search again")
            )
                .padding(.horizontal, AppSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    ForEach(keywords, id: \.self) { keyword in
                        Button {
                            model.keyword = keyword
                            Task { await performSearch() }
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

    private func isOptionSelected(index: Int, value: String) -> Bool {
        vm.login.searchOptionValues.indices.contains(index) && vm.login.searchOptionValues[index] == value
    }

    private func performSearch() async {
        await model.performSearch(
            using: vm,
            sourceKey: vm.sourceManager.selectedSourceKey,
            options: vm.login.searchOptionValues,
            profile: vm.login.searchFeatureProfile,
            append: false
        )
    }

    private func loadMore() async {
        await model.performSearch(
            using: vm,
            sourceKey: vm.sourceManager.selectedSourceKey,
            options: vm.login.searchOptionValues,
            profile: vm.login.searchFeatureProfile,
            append: true
        )
    }

    private func applyQuickOption(index: Int, value: String) async {
        vm.login.updateSearchOption(at: index, value: value)
        await performSearch()
    }

    private var searchContextVisible: Bool {
        !model.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchContextSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            sectionHeader(title: AppLocalization.text("search.context", "Search Context"), subtitle: searchContextSubtitle)
                .padding(.horizontal, AppSpacing.md)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    contextChip(title: activeSourceTitle, systemImage: "antenna.radiowaves.left.and.right")
                    switch model.lastSearchTrigger {
                    case .keyword:
                        contextChip(title: AppLocalization.text("search.context.keyword", "Keyword Search"), systemImage: "text.magnifyingglass")
                    case .tag(let tag):
                        contextChip(title: "#\(tag)", systemImage: "tag")
                    }
                }
                .padding(.horizontal, AppSpacing.md)
            }
        }
        .padding(.vertical, AppSpacing.sm)
        .background(AppSurface.grouped)
    }

    private var activeSourceTitle: String {
        vm.sourceManager.installedSources.first(where: { $0.key == vm.sourceManager.selectedSourceKey })?.name
            ?? AppLocalization.text("search.no_source_selected", "No Source Selected")
    }

    private var searchContextSubtitle: String {
        switch model.lastSearchTrigger {
        case .keyword:
            return AppLocalization.text("search.context.keyword_subtitle", "Searching the active source by keyword.")
        case .tag(let tag):
            return AppLocalization.format("search.results_started_from_tag", "Results started from the tag \"%@\".", tag)
        }
    }

    private func contextChip(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .background(AppSurface.subtle)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
    }

}

@MainActor
struct SearchSettingsSheet: View {
    @Bindable var model: SearchScreenModel
    @Bindable var vm: ReaderViewModel
    let onPickRecentKeyword: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(AppLocalization.text("search.section.source", "Source")) {
                    if vm.sourceManager.installedSources.isEmpty {
                        Text(AppLocalization.text("search.no_source_installed", "No source installed"))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(AppLocalization.text("search.active_source", "Active Source"), selection: $vm.sourceManager.selectedSourceKey) {
                            ForEach(vm.sourceManager.installedSources) { source in
                                Text(source.name).tag(source.key)
                            }
                        }
                    }
                }

                if !vm.login.searchOptionGroups.isEmpty {
                    Section(AppLocalization.text("search.filters", "Filters")) {
                        let groups = vm.login.searchOptionGroups
                        ForEach(groups.indices, id: \.self) { index in
                            let group = groups[index]
                            if group.type == "multi-select" {
                                MultiSelectOptionGroupView(
                                    group: group,
                                    selectedJSON: Binding(
                                        get: {
                                            vm.login.searchOptionValues.indices.contains(index) ? vm.login.searchOptionValues[index] : "[]"
                                        },
                                        set: { newValue in
                                            vm.login.updateSearchOption(at: index, value: newValue)
                                        }
                                    )
                                )
                            } else {
                                SingleSelectOptionGroupView(
                                    group: group,
                                    selection: Binding(
                                        get: {
                                            vm.login.searchOptionValues.indices.contains(index) ? vm.login.searchOptionValues[index] : ""
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

                if !model.recentKeywords.isEmpty {
                    Section(AppLocalization.text("search.recent_keywords", "Recent Keywords")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: AppSpacing.sm) {
                                ForEach(model.recentKeywords, id: \.self) { keyword in
                                    Button(keyword) {
                                        onPickRecentKeyword(keyword)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Button(AppLocalization.text("search.clear_history", "Clear History"), role: .destructive) {
                            model.clearRecentKeywords()
                        }
                    }
                }

                Section(AppLocalization.text("common.status", "Status")) {
                    Text(model.status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(AppLocalization.text("search.features", "Source Search Features")) {
                    featureRow(AppLocalization.text("search.feature.keyword", "Keyword Search"), enabled: vm.login.searchFeatureProfile.hasKeywordSearch)
                    featureRow(AppLocalization.text("search.feature.paged_keyword", "Paged Keyword Search"), enabled: vm.login.searchFeatureProfile.supportsPagedKeywordSearch)
                    featureRow("loadPage()", enabled: vm.login.searchFeatureProfile.supportsLoadPage)
                    featureRow("loadNext()", enabled: vm.login.searchFeatureProfile.supportsLoadNext)
                    HStack {
                        Text(AppLocalization.text("search.filter_groups", "Filter Groups"))
                        Spacer()
                        Text("\(vm.login.searchFeatureProfile.optionGroupCount)")
                            .foregroundStyle(.secondary)
                    }
                    if !vm.login.searchFeatureProfile.availableMethods.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(AppLocalization.text("search.exposed_methods", "Exposed Methods"))
                            Text(vm.login.searchFeatureProfile.availableMethods.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(AppLocalization.text("search.settings.navigation", "Search Settings"))
            .toolbar {
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button(AppLocalization.text("common.done", "Done")) { dismiss() }
                }
            }
        }
    }

    private func featureRow(_ title: String, enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: enabled ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(enabled ? AppTint.success : .secondary)
        }
    }
}

private struct SingleSelectOptionGroupView: View {
    let group: SearchOptionGroup
    @Binding var selection: String

    var body: some View {
        HStack {
            Text(group.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Picker(group.label, selection: $selection) {
                ForEach(group.options) { item in
                    Text(item.label).tag(item.value)
                }
            }
            .pickerStyle(.menu)
        }
    }
}

private struct MultiSelectOptionGroupView: View {
    let group: SearchOptionGroup
    @Binding var selectedJSON: String

    var body: some View {
        let selected = parseSelection(selectedJSON)
        VStack(alignment: .leading, spacing: 6) {
            Text(group.label)
                .font(.footnote)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: AppSpacing.sm)], spacing: AppSpacing.sm) {
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
                    .buttonStyle(.borderedProminent)
                    .tint(picked ? AppTint.accent : .gray.opacity(0.25))
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
