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
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    selectionCountLabel

                    Spacer(minLength: 0)

                    selectionActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    selectionCountLabel

                    selectionActions
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            if isWorking, !progressText.isEmpty {
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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

    private var selectionCountLabel: some View {
        Text(AppLocalization.format("common.selected_count", "%lld selected", Int64(selectedCount)))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppSurface.subtle, in: Capsule(style: .continuous))
    }

    private var selectionActions: some View {
        HStack(spacing: 8) {
            Button(selectedCount == totalCount ? AppLocalization.text("common.clear", "Clear") : AppLocalization.text("common.select_all", "Select All"), action: selectAllAction)
                .font(.subheadline.weight(.semibold))
                .controlSize(.small)
                .buttonStyle(.bordered)

            Button(role: .destructive, action: confirmAction) {
                HStack(spacing: 6) {
                    if isWorking {
                        ProgressView()
                    }
                    Text(actionTitle)
                }
                .font(.subheadline.weight(.semibold))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(selectedCount == 0 || isWorking)
        }
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
    @State private var selectedFavoriteKey: String?
#if os(macOS)
    @State private var selectionCommandController = MacSelectionCommandController()
#endif
    @AppStorage("favorites.selectedSourceKey") private var persistedSourceKey: String = ""
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue

    private var hasFolders: Bool { model.hasFolders }
    private var currentFolderLabel: String {
        guard hasFolders else { return AppLocalization.text("favorites.folder.all", "All") }
        guard let id = model.canonicalFolderID(model.selectedFolderID, availableFolders: model.sourceFolders) else { return defaultFolderTitle }
        return model.sourceFolders.first(where: { $0.id == id })?.title ?? defaultFolderTitle
    }

    private var defaultFolderTitle: String {
        model.sourceFolders.first(where: { $0.id == "-1" })?.title ?? AppLocalization.text("favorites.folder.all", "All")
    }
    private var shouldShowPager: Bool {
        !model.selectedSourceKey.isEmpty && model.sourceError.isEmpty && (model.currentPage > 1 || !model.sourceFavorites.isEmpty)
    }
    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    private var presentationSnapshot: FavoritesPresentationSnapshot {
        FavoritesPresentationSnapshot(
            installedSources: sourceManager.installedSources,
            libraryFavorites: library.favorites,
            sourceFavorites: model.sourceFavorites,
            selectedSourceKey: model.selectedSourceKey
        )
    }

    private var selectedFavorite: ComicSummary? {
        presentationSnapshot.favorite(matching: selectedFavoriteKey)
    }

    var body: some View {
        let snapshot = presentationSnapshot

        Group {
            if browseMode == .list {
                favoritesList
            } else {
                favoritesGrid
            }
        }
        .background(AppSurface.grouped)
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailRoutingView(
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
        .navigationTitle(AppLocalization.text("favorites.navigation.title", "Favorites"))
        .toolbar {
            favoritesToolbar(snapshot: snapshot)
        }
        .refreshable {
            await model.refreshNow(vm: vm, forceNetwork: true)
        }
        .alert(AppLocalization.text("favorites.remove_selected", "Remove selected favorites?"), isPresented: Binding(
            get: { model.showBatchRemoveConfirm },
            set: { model.showBatchRemoveConfirm = $0 }
        )) {
            Button(AppLocalization.text("common.remove", "Remove"), role: .destructive) {
                Task { await model.removeSelected(using: vm) }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) { }
        } message: {
            Text(AppLocalization.format("favorites.remove_selected_confirm", "Remove %lld selected favorites from this source folder?", Int64(model.selectedCount)))
        }
        .onDisappear {
            model.refreshTask?.cancel()
            model.refreshTask = nil
        }
        .onChange(of: snapshot.sourceOptionKeys) { _, optionKeys in
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
        .onChange(of: snapshot.favoriteKeys) { _, _ in
            reconcileSelectedFavorite()
            configureSelectionCommands()
        }
        .onChange(of: selectedFavoriteKey) { _, _ in
            configureSelectionCommands()
        }
        .task {
            if model.selectedSourceKey.isEmpty {
                let keys = presentationSnapshot.sourceOptionKeys
                guard !keys.isEmpty else { return }
                model.selectedSourceKey = restoredSourceKey(from: keys)
            } else if persistedSourceKey != model.selectedSourceKey {
                persistedSourceKey = model.selectedSourceKey
            }
            await prepareFavoriteContext(for: model.selectedSourceKey)
            await model.refreshNow(vm: vm)
            reconcileSelectedFavorite()
            configureSelectionCommands()
        }
#if os(macOS)
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
#endif
        .sheet(isPresented: Binding(
            get: { model.showPagePicker },
            set: { model.showPagePicker = $0 }
        )) {
            pagePickerSheet
        }
    }

    @ToolbarContentBuilder
    private func favoritesToolbar(snapshot: FavoritesPresentationSnapshot) -> some ToolbarContent {
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
            Button(model.isSelecting ? AppLocalization.text("common.done", "Done") : AppLocalization.text("common.select", "Select")) {
                model.toggleSelecting()
            }
        }
        ToolbarItem(placement: .platformTopBarTrailing) {
            sourceContextMenu(snapshot: snapshot)
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
                Section(AppLocalization.text("favorites.page.jump_section", "Jump to page")) {
                    TextField(AppLocalization.text("favorites.page.number_placeholder", "Page number"), value: Binding(
                        get: { Int(model.pageInput) ?? model.currentPage },
                        set: { model.pageInput = String($0) }
                    ), format: .number)
                    .platformKeyboardNumberPad()
                }
            }
            .navigationTitle(AppLocalization.text("favorites.page.select_title", "Select Page"))
            .platformNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.text("common.cancel", "Cancel")) {
                        model.showPagePicker = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.text("favorites.page.go", "Go")) {
                        guard let page = Int(model.pageInput), page > 0 else {
                            model.sourceError = AppLocalization.text("favorites.page.invalid", "Invalid page number")
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
                Label(AppLocalization.text("favorites.page.previous", "Previous page"), systemImage: "chevron.left")
                    .labelStyle(.iconOnly)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(model.refreshing || model.currentPage <= 1)

            Button {
                model.openPagePicker()
            } label: {
                Text(AppLocalization.format("favorites.page.current_format", "Page %lld", Int64(model.currentPage)))
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 72, minHeight: 28)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)
            .accessibilityHint(AppLocalization.text("favorites.page.open_picker_hint", "Open page picker"))

            Button {
                Task { await model.jumpToPage(model.currentPage + 1, vm: vm) }
            } label: {
                Label(AppLocalization.text("favorites.page.next", "Next page"), systemImage: "chevron.right")
                    .labelStyle(.iconOnly)
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

    private func switchFavoriteAccount(_ profile: WebLoginCookieStore.AuthProfile, source: InstalledSource) {
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
                AppEmptyStateCard(
                    title: AppLocalization.text("favorites.empty.source", "No source favorites"),
                    message: AppLocalization.text("favorites.empty.source_hint", "Favorites from the active source will appear here after sync."),
                    systemImage: "star"
                )
                .padding(AppSpacing.md)
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

    private func sourceContextMenu(snapshot: FavoritesPresentationSnapshot) -> some View {
        Menu {
            sourceContextMenuContent(snapshot: snapshot)
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
    private func sourceContextMenuContent(snapshot: FavoritesPresentationSnapshot) -> some View {
        Section(AppLocalization.text("favorites.menu.source", "Source")) {
            ForEach(snapshot.sourceOptions) { option in
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
                        if let source = snapshot.selectedInstalledSource {
                            switchFavoriteAccount(profile, source: source)
                        }
                    } label: {
                        if profile.id == vm.login.activeAuthProfileID {
                            Label(profile.label, systemImage: "checkmark")
                        } else {
                            Text(profile.label)
                        }
                    }
                }
            }

            if let source = snapshot.selectedInstalledSource {
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
            AppEmptyStateCard(
                title: AppLocalization.text("favorites.empty.source", "No source favorites"),
                message: AppLocalization.text("favorites.empty.source_hint", "Favorites from the active source will appear here after sync."),
                systemImage: "star"
            )
            .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.md, bottom: AppSpacing.sm, trailing: AppSpacing.md))
            .listRowBackground(Color.clear)
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
            actionTitle: AppLocalization.text("common.remove", "Remove"),
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
            selectedFavoriteKey = model.selectionKey(for: item)
            if model.isSelecting {
                model.toggleSelection(item)
            } else {
                openFavorite(item)
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
        .contextMenu {
            favoriteContextMenu(for: item)
        }
    }

    @ViewBuilder
    private func favoriteContextMenu(for item: ComicSummary) -> some View {
        Button(AppLocalization.text("common.open", "Open"), systemImage: "arrow.up.right.square") {
            openFavorite(item)
        }
        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyFavoriteTitle(item)
        }
        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyFavoriteID(item)
        }
        Button(AppLocalization.text("search.action.copy_source", "Copy Source"), systemImage: "shippingbox") {
            copyFavoriteSource(item)
        }
        Divider()
        Button(AppLocalization.text("library.bookmarks.remove", "Remove"), systemImage: "trash", role: .destructive) {
            Task { await removeFavorite(item) }
        }
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

    private func openFavorite(_ item: ComicSummary) {
        selectedFavoriteKey = model.selectionKey(for: item)
        selectedDetailItem = ComicSummary(
            id: item.id,
            sourceKey: item.sourceKey,
            title: item.title,
            coverURL: item.coverURL,
            author: item.author,
            tags: item.tags
        )
    }

    private func removeFavorite(_ item: ComicSummary) async {
        selectedFavoriteKey = model.selectionKey(for: item)
        await model.remove(item, using: vm)
        reconcileSelectedFavorite()
        configureSelectionCommands()
    }

    private func copyFavoriteTitle(_ item: ComicSummary) {
        selectedFavoriteKey = model.selectionKey(for: item)
        PlatformPasteboard.copy(item.title)
    }

    private func copyFavoriteID(_ item: ComicSummary) {
        selectedFavoriteKey = model.selectionKey(for: item)
        PlatformPasteboard.copy(item.id)
    }

    private func copyFavoriteSource(_ item: ComicSummary) {
        selectedFavoriteKey = model.selectionKey(for: item)
        PlatformPasteboard.copy(item.sourceKey)
    }

    private func reconcileSelectedFavorite() {
        let snapshot = presentationSnapshot
        if let selectedFavoriteKey, snapshot.favoriteKeys.contains(selectedFavoriteKey) {
            return
        }
        selectedFavoriteKey = snapshot.favoriteKeys.first
    }

    private func configureSelectionCommands() {
#if os(macOS)
        selectionCommandController.reset()
        guard let item = selectedFavorite else { return }

        selectionCommandController.open = { openFavorite(item) }
        selectionCommandController.delete = { Task { await removeFavorite(item) } }
        selectionCommandController.copyTitle = { copyFavoriteTitle(item) }
        selectionCommandController.copyID = { copyFavoriteID(item) }
        selectionCommandController.export = { copyFavoriteSource(item) }
        selectionCommandController.exportTitle = AppLocalization.text("search.action.copy_source", "Copy Source")
        selectionCommandController.canOpen = true
        selectionCommandController.canDelete = true
        selectionCommandController.canCopyTitle = true
        selectionCommandController.canCopyID = true
        selectionCommandController.canExport = true
#endif
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
    @State private var selectedHistoryID: ReadingHistoryItem.ID?
#if os(macOS)
    @State private var selectionCommandController = MacSelectionCommandController()
#endif
    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    private var presentationSnapshot: HistoryPresentationSnapshot {
        HistoryPresentationSnapshot(items: model.items)
    }

    private var selectedHistoryItem: ReadingHistoryItem? {
        presentationSnapshot.item(matching: selectedHistoryID)
    }

    var body: some View {
        let snapshot = presentationSnapshot

        Group {
            if browseMode == .list {
                historyList
            } else {
                historyGrid
            }
        }
        .background(AppSurface.grouped)
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailRoutingView(
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
        .navigationTitle(AppLocalization.text("history.navigation.title", "History"))
        .toolbar {
            if !model.items.isEmpty {
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button(model.isSelecting ? AppLocalization.text("common.done", "Done") : AppLocalization.text("common.select", "Select")) {
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
        .alert(AppLocalization.text("history.clear_all", "Clear all history?"), isPresented: $model.showClearConfirm) {
            Button(AppLocalization.text("common.clear", "Clear"), role: .destructive) {
                Task { await model.clear(using: library) }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) { }
        } message: {
            Text(AppLocalization.text("history.clear_all_confirm", "This action cannot be undone."))
        }
        .alert(AppLocalization.text("history.delete_selected", "Delete selected history?"), isPresented: Binding(
            get: { model.showBatchDeleteConfirm },
            set: { model.showBatchDeleteConfirm = $0 }
        )) {
            Button(AppLocalization.text("common.delete", "Delete"), role: .destructive) {
                Task { await model.deleteSelected(using: library) }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) { }
        } message: {
            Text(AppLocalization.format("history.delete_selected_confirm", "Delete %lld selected history items? This action cannot be undone.", Int64(model.selectedCount)))
        }
        .task {
            model.sync(from: library)
            reconcileSelectedHistory()
            configureSelectionCommands()
        }
        .onChange(of: library.history) { _, items in
            model.sync(from: library)
            reconcileSelectedHistory()
            configureSelectionCommands()
        }
        .onChange(of: snapshot.itemIDs) { _, _ in
            reconcileSelectedHistory()
            configureSelectionCommands()
        }
        .onChange(of: selectedHistoryID) { _, _ in
            configureSelectionCommands()
        }
#if os(macOS)
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
#endif
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
            return AppLocalization.format("history.page_with_chapter_format", "Page %lld · %@", Int64(item.page), chapter)
        }
        return AppLocalization.format("history.page_format", "Page %lld", Int64(item.page))
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
                AppEmptyStateCard(
                    title: AppLocalization.text("history.empty", "No reading history"),
                    message: AppLocalization.text("history.empty_hint", "Open a chapter to start building your reading history."),
                    systemImage: "clock"
                )
                .padding(AppSpacing.md)
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
            AppEmptyStateCard(
                title: AppLocalization.text("history.empty", "No reading history"),
                message: AppLocalization.text("history.empty_hint", "Open a chapter to start building your reading history."),
                systemImage: "clock"
            )
            .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.md, bottom: AppSpacing.sm, trailing: AppSpacing.md))
            .listRowBackground(Color.clear)
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
            actionTitle: AppLocalization.text("common.delete", "Delete"),
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
            selectedHistoryID = item.id
            if model.isSelecting {
                model.toggleSelection(item)
            } else {
                openHistoryItem(item)
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
                        SwiftUI.Label(AppLocalization.text("history.action.resume", "Resume"), systemImage: "play.fill")
                    }
                    .tint(AppTint.accent)
                }
                Button(role: .destructive) {
                    Task { await deleteHistoryItem(item) }
                } label: {
                    SwiftUI.Label(AppLocalization.text("common.delete", "Delete"), systemImage: "trash")
                }
            }
        }
        .contextMenu {
            historyContextMenu(for: item)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func historyContextMenu(for item: ReadingHistoryItem) -> some View {
        if item.chapterID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            Button(AppLocalization.text("history.action.resume", "Resume"), systemImage: "play.fill") {
                resumeReading(item)
            }
        }
        Button(AppLocalization.text("common.open", "Open"), systemImage: "arrow.up.right.square") {
            openHistoryItem(item)
        }
        Divider()
        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyHistoryTitle(item)
        }
        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyHistoryID(item)
        }
        Button(AppLocalization.text("search.action.copy_source", "Copy Source"), systemImage: "shippingbox") {
            copyHistorySource(item)
        }
        Divider()
        Button(AppLocalization.text("common.delete", "Delete"), systemImage: "trash", role: .destructive) {
            Task { await deleteHistoryItem(item) }
        }
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
        selectedHistoryID = item.id
        guard let context = ReaderLaunchContext.fromHistory(item, using: library) else {
            openHistoryItem(item)
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

    private func openHistoryItem(_ item: ReadingHistoryItem) {
        selectedHistoryID = item.id
        pendingDetailReadRoute = nil
        selectedDetailItem = ComicSummary(
            id: item.comicID,
            sourceKey: item.sourceKey,
            title: item.title,
            coverURL: item.coverURL,
            author: item.author,
            tags: item.tags
        )
    }

    private func deleteHistoryItem(_ item: ReadingHistoryItem) async {
        selectedHistoryID = item.id
        await model.delete(item, using: library)
        reconcileSelectedHistory()
        configureSelectionCommands()
    }

    private func copyHistoryTitle(_ item: ReadingHistoryItem) {
        selectedHistoryID = item.id
        PlatformPasteboard.copy(item.title)
    }

    private func copyHistoryID(_ item: ReadingHistoryItem) {
        selectedHistoryID = item.id
        PlatformPasteboard.copy(item.comicID)
    }

    private func copyHistorySource(_ item: ReadingHistoryItem) {
        selectedHistoryID = item.id
        PlatformPasteboard.copy(item.sourceKey)
    }

    private func reconcileSelectedHistory() {
        let snapshot = presentationSnapshot
        if let selectedHistoryID, snapshot.itemIDs.contains(selectedHistoryID) {
            return
        }
        selectedHistoryID = snapshot.itemIDs.first
    }

    private func configureSelectionCommands() {
#if os(macOS)
        selectionCommandController.reset()
        guard let item = selectedHistoryItem else { return }

        selectionCommandController.open = { openHistoryItem(item) }
        selectionCommandController.delete = { Task { await deleteHistoryItem(item) } }
        selectionCommandController.copyTitle = { copyHistoryTitle(item) }
        selectionCommandController.copyID = { copyHistoryID(item) }
        selectionCommandController.export = { copyHistorySource(item) }
        selectionCommandController.exportTitle = AppLocalization.text("search.action.copy_source", "Copy Source")
        selectionCommandController.canOpen = true
        selectionCommandController.canDelete = true
        selectionCommandController.canCopyTitle = true
        selectionCommandController.canCopyID = true
        selectionCommandController.canExport = true
#endif
    }

}
