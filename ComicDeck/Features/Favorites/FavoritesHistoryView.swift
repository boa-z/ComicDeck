import SwiftUI
import Observation

private struct BatchSelectionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let isWorking: Bool
    let progressText: String
    let actionTitle: String
    let selectAllAction: () -> Void
    let confirmAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppSurface.subtle, in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(selectedCount == totalCount ? "Clear" : "Select All") {
                    selectAllAction()
                }
                .font(.subheadline.weight(.semibold))
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    confirmAction()
                } label: {
                    if isWorking {
                        HStack(spacing: 6) {
                            ProgressView()
                            if !progressText.isEmpty {
                                Text(progressText)
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                    } else {
                        Text(actionTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0 || isWorking)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.lg, style: .continuous)
                .stroke(AppSurface.border, lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

@MainActor
struct FavoritesView: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var sourceManager: SourceManagerViewModel
    @Environment(LibraryViewModel.self) private var library
    let onTagSearchRequested: (String, String) -> Void
    @State private var model = FavoritesScreenModel()
    @State private var selectedDetailItem: ComicSummary?
    @AppStorage("favorites.selectedSourceKey") private var persistedSourceKey: String = ""
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue

    private var sourceOptions: [(key: String, name: String, label: String)] {
        var map: [String: String] = [:]
        for source in sourceManager.installedSources {
            map[source.key] = source.name
        }
        for item in library.favorites where map[item.sourceKey] == nil {
            map[item.sourceKey] = item.sourceKey
        }
        let rows = map
            .map { (key: $0.key, name: $0.value, label: "\($0.value) (\($0.key))") }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return rows
    }

    private var hasFolders: Bool { model.hasFolders }
    private var selectedInstalledSource: InstalledSource? {
        sourceManager.installedSource(for: model.selectedSourceKey)
    }
    private var currentFolderLabel: String {
        guard hasFolders else { return "All" }
        guard let id = model.canonicalFolderID(model.selectedFolderID, availableFolders: model.sourceFolders) else { return defaultFolderTitle }
        return model.sourceFolders.first(where: { $0.id == id })?.title ?? defaultFolderTitle
    }

    private var defaultFolderTitle: String {
        model.sourceFolders.first(where: { $0.id == "-1" })?.title ?? "All"
    }
    private var shouldShowPager: Bool {
        !model.selectedSourceKey.isEmpty && model.sourceError.isEmpty && (model.currentPage > 1 || !model.sourceFavorites.isEmpty)
    }
    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    var body: some View {
        Group {
            if browseMode == .list {
                favoritesList
            } else {
                favoritesGrid
            }
        }
        .background(AppSurface.grouped)
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailView(
                vm: vm,
                item: item,
                onTagSelected: { tag, sourceKey in
                    onTagSearchRequested(tag, sourceKey)
                },
                onNavigateBack: { selectedDetailItem = nil }
            )
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomInset
        }
        .navigationTitle("Favorites")
        .toolbar {
            favoritesToolbar
        }
        .refreshable {
            await model.refreshNow(vm: vm, forceNetwork: true)
        }
        .alert("Remove selected favorites?", isPresented: Binding(
            get: { model.showBatchRemoveConfirm },
            set: { model.showBatchRemoveConfirm = $0 }
        )) {
            Button("Remove", role: .destructive) {
                Task { await model.removeSelected(using: vm) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Remove \(model.selectedCount) selected favorite\(model.selectedCount == 1 ? "" : "s") from this source folder?")
        }
        .onDisappear {
            model.refreshTask?.cancel()
            model.refreshTask = nil
        }
        .onChange(of: sourceOptions.map(\.key)) { _, optionKeys in
            guard !optionKeys.isEmpty else { return }
            if !optionKeys.contains(model.selectedSourceKey) {
                model.selectedSourceKey = restoredSourceKey(from: optionKeys)
            }
        }
        .onChange(of: model.selectedSourceKey) { _, key in
            guard !key.isEmpty else { return }
            if persistedSourceKey != key {
                persistedSourceKey = key
            }
            Task { await prepareFavoriteContext(for: key) }
            model.currentPage = 1
            model.setSelecting(false)
            requestRefresh()
        }
        .task {
            if model.selectedSourceKey.isEmpty {
                let keys = sourceOptions.map(\.key)
                guard !keys.isEmpty else { return }
                model.selectedSourceKey = restoredSourceKey(from: keys)
            } else if persistedSourceKey != model.selectedSourceKey {
                persistedSourceKey = model.selectedSourceKey
            }
            await prepareFavoriteContext(for: model.selectedSourceKey)
            await model.refreshNow(vm: vm)
        }
        .sheet(isPresented: Binding(
            get: { model.showPagePicker },
            set: { model.showPagePicker = $0 }
        )) {
            pagePickerSheet
        }
    }

    @ToolbarContentBuilder
    private var favoritesToolbar: some ToolbarContent {
        ToolbarItem(placement: .platformTopBarLeading) {
            Button {
                requestRefresh(forceNetwork: true)
            } label: {
                if model.refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(model.refreshing)
        }
        ToolbarItem(placement: .platformTopBarTrailing) {
            Button(model.isSelecting ? "Done" : "Select") {
                model.toggleSelecting()
            }
        }
        ToolbarItem(placement: .platformTopBarTrailing) {
            sourceContextMenu
        }
        ToolbarItem(placement: .platformTopBarTrailing) {
            folderContextMenu
        }
        ToolbarItem(placement: .platformTopBarTrailing) {
            Button {
                toggleBrowseMode()
            } label: {
                Label(browseModeToggleTitle, systemImage: browseModeToggleIcon)
            }
        }
    }

    @ViewBuilder
    private var bottomInset: some View {
        if model.isSelecting {
            selectionBar
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
        } else if shouldShowPager {
            pagerBar
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .background(.clear)
        }
    }

    private var pagePickerSheet: some View {
        NavigationStack {
            Form {
                Section("Jump to page") {
                    TextField("Page number", value: Binding(
                        get: { Int(model.pageInput) ?? model.currentPage },
                        set: { model.pageInput = String($0) }
                    ), format: .number)
                    .platformKeyboardNumberPad()
                }
            }
            .navigationTitle("Select Page")
            .platformNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.showPagePicker = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Go") {
                        guard let page = Int(model.pageInput), page > 0 else {
                            model.sourceError = "Invalid page number"
                            return
                        }
                        model.showPagePicker = false
                        Task { await model.jumpToPage(page, vm: vm) }
                    }
                }
            }
        }
        .platformPresentationDetentsPagePicker()
    }

    private var pagerBar: some View {
        HStack(spacing: 10) {
            Button {
                guard model.currentPage > 1 else { return }
                model.currentPage -= 1
                requestRefresh()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(model.refreshing || model.currentPage <= 1)

            Button {
                model.openPagePicker()
            } label: {
                Text("Page \(model.currentPage)")
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 72, minHeight: 28)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open page picker")

            Button {
                Task { await model.jumpToPage(model.currentPage + 1, vm: vm) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(model.refreshing)

            if model.refreshing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule(style: .continuous))
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func restoredSourceKey(from keys: [String]) -> String {
        if keys.contains(persistedSourceKey) {
            return persistedSourceKey
        }
        if keys.contains(sourceManager.selectedSourceKey) {
            return sourceManager.selectedSourceKey
        }
        return keys.first ?? ""
    }

    private func prepareFavoriteContext(for sourceKey: String) async {
        guard !sourceKey.isEmpty else { return }
        await vm.prepareSourceFavoriteSession(sourceKey: sourceKey)
    }

    private func switchFavoriteAccount(_ profile: WebLoginCookieStore.AuthProfile) {
        guard let source = selectedInstalledSource else { return }
        Task {
            await vm.login.switchAuthProfile(profile, for: source)
            model.currentPage = 1
            model.setSelecting(false)
            await model.refreshNow(vm: vm, forceNetwork: true)
        }
    }

    private var browseModeToggleTitle: String {
        switch browseMode {
        case .list:
            AppLocalization.text("favorites.action.show_grid", "Show Grid")
        case .grid:
            AppLocalization.text("favorites.action.show_list", "Show List")
        }
    }

    private var browseModeToggleIcon: String {
        switch browseMode {
        case .list:
            "square.grid.2x2"
        case .grid:
            "list.bullet"
        }
    }

    private func toggleBrowseMode() {
        browseMode = browseMode == .list ? .grid : .list
    }

    private func selectFavoriteFolder(_ folderID: String?) {
        model.selectedFolderID = model.canonicalFolderID(folderID, availableFolders: model.sourceFolders)
        model.currentPage = 1
        requestRefresh()
    }
    
    private func requestRefresh(forceNetwork: Bool = false) {
        model.requestRefresh(vm: vm, forceNetwork: forceNetwork)
    }

    private var favoritesList: some View {
        List {
            favoriteContent
        }
        .listStyle(.plain)
    }

    private var favoritesGrid: some View {
        ScrollView {
            if !model.sourceError.isEmpty {
                Text(model.sourceError)
                    .foregroundStyle(.red)
                    .padding(AppSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if model.sourceFavorites.isEmpty {
                Text("No source favorites")
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.lg)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: AppSpacing.md),
                    GridItem(.flexible(), spacing: AppSpacing.md)
                ], spacing: AppSpacing.md) {
                    ForEach(model.sourceFavorites) { item in
                        favoriteEntry(for: item) {
                            ComicPreviewGridCard(
                                title: item.title,
                                coverURL: item.coverURL,
                                sourceKey: item.sourceKey,
                                entityID: item.id,
                                author: item.author,
                                tags: item.tags,
                                subtitle: nil,
                                coverReloadToken: model.refreshGeneration
                            )
                        }
                    }
                }
                .padding(AppSpacing.md)
            }
        }
    }

    private var sourceContextMenu: some View {
        Menu {
            sourceContextMenuContent
        } label: {
            Label(AppLocalization.text("favorites.menu.source_account", "Source & Account"), systemImage: "person.crop.circle.badge.checkmark")
        }
    }

    private var folderContextMenu: some View {
        Menu {
            folderContextMenuContent
        } label: {
            Label(currentFolderLabel, systemImage: "folder")
        }
    }

    @ViewBuilder
    private var sourceContextMenuContent: some View {
        Section(AppLocalization.text("favorites.menu.source", "Source")) {
            ForEach(sourceOptions, id: \.key) { option in
                Button {
                    model.selectedSourceKey = option.key
                } label: {
                    if option.key == model.selectedSourceKey {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        }

        Section(AppLocalization.text("favorites.menu.account", "Account")) {
            if vm.login.authProfiles.isEmpty {
                Button(AppLocalization.text("favorites.account.no_saved", "No saved accounts")) { }
                    .disabled(true)
            } else {
                ForEach(vm.login.authProfiles) { profile in
                    Button {
                        switchFavoriteAccount(profile)
                    } label: {
                        if profile.id == vm.login.activeAuthProfileID {
                            Label(profile.label, systemImage: "checkmark")
                        } else {
                            Text(profile.label)
                        }
                    }
                }
            }

            if let source = selectedInstalledSource {
                Button(AppLocalization.text("source.detail.refresh_login", "Refresh Login Status")) {
                    Task { await vm.login.refreshCurrentSourceLoginState(for: source) }
                }
                Button(AppLocalization.text("source.detail.save_current_account", "Save Current Account")) {
                    Task { await vm.login.saveCurrentAuthProfile(for: source, replacingActive: false) }
                }
                .disabled(!vm.login.canSaveCurrentAuthProfile(sourceKey: source.key))
            }
        }
    }

    @ViewBuilder
    private var folderContextMenuContent: some View {
        Section(AppLocalization.text("favorites.menu.folder", "Folder")) {
            Button {
                selectFavoriteFolder(nil)
            } label: {
                if model.canonicalFolderID(model.selectedFolderID, availableFolders: model.sourceFolders) == model.canonicalFolderID(nil, availableFolders: model.sourceFolders) {
                    Label(defaultFolderTitle, systemImage: "checkmark")
                } else {
                    Text(defaultFolderTitle)
                }
            }

            if hasFolders {
                ForEach(model.selectableFolders) { folder in
                    Button {
                        selectFavoriteFolder(folder.id)
                    } label: {
                        if model.canonicalFolderID(model.selectedFolderID, availableFolders: model.sourceFolders) == folder.id {
                            Label(folder.title, systemImage: "checkmark")
                        } else {
                            Text(folder.title)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var favoriteContent: some View {
        if !model.sourceError.isEmpty {
            Text(model.sourceError)
                .foregroundStyle(.red)
        } else if model.sourceFavorites.isEmpty {
            Text("No source favorites")
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.sourceFavorites) { item in
                favoriteEntry(for: item) {
                    ComicPreviewCard(
                        title: item.title,
                        coverURL: item.coverURL,
                        sourceKey: item.sourceKey,
                        entityID: item.id,
                        author: item.author,
                        tags: item.tags,
                        subtitle: nil,
                        coverReloadToken: model.refreshGeneration
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }
        }
    }

    private var selectionBar: some View {
        BatchSelectionBar(
            selectedCount: model.selectedCount,
            totalCount: model.sourceFavorites.count,
            isWorking: model.batchWorking,
            progressText: model.batchProgressText,
            actionTitle: "Remove",
            selectAllAction: {
                if model.selectedCount == model.sourceFavorites.count {
                    model.clearSelection()
                } else {
                    model.selectAllVisible()
                }
            },
            confirmAction: {
                model.showBatchRemoveConfirm = true
            }
        )
    }

    private func favoriteEntry<Label: View>(
        for item: ComicSummary,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            if model.isSelecting {
                model.toggleSelection(item)
            } else {
                selectedDetailItem = ComicSummary(
                    id: item.id,
                    sourceKey: item.sourceKey,
                    title: item.title,
                    coverURL: item.coverURL,
                    author: item.author,
                    tags: item.tags
                )
            }
        } label: {
            if model.isSelecting {
                selectableCard(
                    isSelected: model.isSelected(item),
                    content: label
                )
            } else {
                label()
            }
        }
        .buttonStyle(.plain)
    }

    private func selectableCard<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppTint.accent : .secondary)
                    .padding(8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .stroke(isSelected ? AppTint.accent : Color.clear, lineWidth: 2)
            }
    }

}

@MainActor
struct HistoryView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    let onTagSearchRequested: (String, String) -> Void
    @State private var model = HistoryScreenModel()
    @State private var selectedDetailItem: ComicSummary?
    @State private var pendingDetailReadRoute: ReaderLaunchContext?
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    var body: some View {
        Group {
            if browseMode == .list {
                historyList
            } else {
                historyGrid
            }
        }
        .background(AppSurface.grouped)
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailView(
                vm: vm,
                item: item,
                onTagSelected: { tag, sourceKey in
                    onTagSearchRequested(tag, sourceKey)
                },
                initialReadRoute: pendingDetailReadRoute,
                onConsumeInitialReadRoute: { pendingDetailReadRoute = nil },
                onNavigateBack: { selectedDetailItem = nil }
            )
        }
        .navigationTitle("History")
        .toolbar {
            if !model.items.isEmpty {
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button(model.isSelecting ? "Done" : "Select") {
                        model.toggleSelecting()
                    }
                }
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button(role: .destructive) {
                        model.showClearConfirm = true
                    } label: {
                        Label(AppLocalization.text("history.action.clear", "Clear History"), systemImage: "trash")
                    }
                    .disabled(model.isSelecting)
                }
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button {
                        toggleHistoryBrowseMode()
                    } label: {
                        Label(historyBrowseModeToggleTitle, systemImage: historyBrowseModeToggleIcon)
                    }
                }
            }
        }
        .alert("Clear all history?", isPresented: $model.showClearConfirm) {
            Button("Clear", role: .destructive) {
                Task { await model.clear(using: library) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Delete selected history?", isPresented: Binding(
            get: { model.showBatchDeleteConfirm },
            set: { model.showBatchDeleteConfirm = $0 }
        )) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelected(using: library) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Delete \(model.selectedCount) selected history item\(model.selectedCount == 1 ? "" : "s")? This action cannot be undone.")
        }
        .task {
            model.sync(from: library)
        }
        .onChange(of: library.history) { _, items in
            model.sync(from: library)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelecting {
                historySelectionBar
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
            }
        }
    }

    private func historySubtitle(_ item: ReadingHistoryItem) -> String {
        if let chapter = item.chapter, !chapter.isEmpty {
            return "Page \(item.page) · \(chapter)"
        }
        return "Page \(item.page)"
    }

    private var historyList: some View {
        List {
            historyContent
        }
        .listStyle(.plain)
    }

    private var historyGrid: some View {
        ScrollView {
            if model.items.isEmpty {
                Text("No reading history")
                    .foregroundStyle(.secondary)
                    .padding(AppSpacing.lg)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: AppSpacing.md),
                    GridItem(.flexible(), spacing: AppSpacing.md)
                ], spacing: AppSpacing.md) {
                    ForEach(model.items) { item in
                        historyEntry(for: item) {
                            ComicPreviewGridCard(
                                title: item.title,
                                coverURL: item.coverURL,
                                sourceKey: item.sourceKey,
                                entityID: item.comicID,
                                author: item.author,
                                tags: item.tags,
                                subtitle: historySubtitle(item),
                                coverReloadToken: model.refreshGeneration
                            )
                        }
                    }
                }
                .padding(AppSpacing.md)
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if model.items.isEmpty {
            Text("No reading history")
                .foregroundStyle(.secondary)
        } else {
            ForEach(model.items) { item in
                historyEntry(for: item) {
                    ComicPreviewCard(
                        title: item.title,
                        coverURL: item.coverURL,
                        sourceKey: item.sourceKey,
                        entityID: item.comicID,
                        author: item.author,
                        tags: item.tags,
                        subtitle: historySubtitle(item),
                        coverReloadToken: model.refreshGeneration
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }
        }
    }

    private var historySelectionBar: some View {
        BatchSelectionBar(
            selectedCount: model.selectedCount,
            totalCount: model.items.count,
            isWorking: model.batchWorking,
            progressText: model.batchProgressText,
            actionTitle: "Delete",
            selectAllAction: {
                if model.selectedCount == model.items.count {
                    model.clearSelection()
                } else {
                    model.selectAllVisible()
                }
            },
            confirmAction: {
                model.showBatchDeleteConfirm = true
            }
        )
    }

    private func historyEntry<Label: View>(
        for item: ReadingHistoryItem,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            if model.isSelecting {
                model.toggleSelection(item)
            } else {
                selectedDetailItem = ComicSummary(
                    id: item.comicID,
                    sourceKey: item.sourceKey,
                    title: item.title,
                    coverURL: item.coverURL,
                    author: item.author,
                    tags: item.tags
                )
            }
        } label: {
            if model.isSelecting {
                selectableCard(
                    isSelected: model.isSelected(item),
                    content: label
                )
            } else {
                label()
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !model.isSelecting {
                if item.chapterID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Button {
                        resumeReading(item)
                    } label: {
                        SwiftUI.Label("Resume", systemImage: "play.fill")
                    }
                    .tint(AppTint.accent)
                }
                Button(role: .destructive) {
                    Task { await model.delete(item, using: library) }
                } label: {
                    SwiftUI.Label("Delete", systemImage: "trash")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func selectableCard<Content: View>(
        isSelected: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AppTint.accent : .secondary)
                    .padding(8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                    .stroke(isSelected ? AppTint.accent : Color.clear, lineWidth: 2)
            }
    }

    private func resumeReading(_ item: ReadingHistoryItem) {
        guard let context = ReaderLaunchContext.fromHistory(item, using: library) else {
            pendingDetailReadRoute = nil
            selectedDetailItem = ComicSummary(
                id: item.comicID,
                sourceKey: item.sourceKey,
                title: item.title,
                coverURL: item.coverURL,
                author: item.author,
                tags: item.tags
            )
            return
        }

        pendingDetailReadRoute = context
        selectedDetailItem = context.item
    }

    private var historyBrowseModeToggleTitle: String {
        switch browseMode {
        case .list:
            AppLocalization.text("favorites.action.show_grid", "Show Grid")
        case .grid:
            AppLocalization.text("favorites.action.show_list", "Show List")
        }
    }

    private var historyBrowseModeToggleIcon: String {
        switch browseMode {
        case .list:
            "square.grid.2x2"
        case .grid:
            "list.bullet"
        }
    }

    private func toggleHistoryBrowseMode() {
        browseMode = browseMode == .list ? .grid : .list
    }

}
