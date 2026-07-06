import SwiftUI

private struct BookmarkBatchSelectionBar: View {
    let selectedCount: Int
    let totalCount: Int
    let isWorking: Bool
    let selectAllAction: () -> Void
    let addToShelfAction: () -> Void
    let removeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(AppLocalization.format("library.bookmarks.selected", "%lld selected", Int64(selectedCount)))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppSurface.subtle, in: Capsule(style: .continuous))

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button(selectedCount == totalCount ? AppLocalization.text("common.clear", "Clear") : AppLocalization.text("common.select_all", "Select All")) {
                    selectAllAction()
                }
                .font(.subheadline.weight(.semibold))
                .controlSize(.small)
                .buttonStyle(.bordered)

                Button(AppLocalization.text("library.bookmarks.add_to_shelf", "Add to Shelf")) {
                    addToShelfAction()
                }
                .font(.subheadline.weight(.semibold))
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(selectedCount == 0 || isWorking)

                Button(AppLocalization.text("library.bookmarks.remove", "Remove"), role: .destructive) {
                    removeAction()
                }
                .font(.subheadline.weight(.semibold))
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
@Observable
private final class LibraryBookmarksScreenModel {
    var isSelecting = false
    var selectedKeys: Set<String> = []
    var selectedShelfID: Int64?
    var showAddToShelfSheet = false
    var showRemoveConfirm = false
    var isWorking = false

    func favoriteKey(for favorite: FavoriteComic) -> String {
        "\(favorite.sourceKey)::\(favorite.id)"
    }

    func isSelected(_ favorite: FavoriteComic) -> Bool {
        selectedKeys.contains(favoriteKey(for: favorite))
    }

    func toggleSelecting() {
        isSelecting.toggle()
        if !isSelecting {
            selectedKeys.removeAll()
        }
    }

    func toggleSelection(for favorite: FavoriteComic) {
        let key = favoriteKey(for: favorite)
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
    }

    func selectAll(from favorites: [FavoriteComic]) {
        if selectedKeys.count == favorites.count {
            selectedKeys.removeAll()
        } else {
            selectedKeys = Set(favorites.map(favoriteKey(for:)))
        }
    }

    func selectedFavorites(from favorites: [FavoriteComic]) -> [FavoriteComic] {
        favorites.filter { selectedKeys.contains(favoriteKey(for: $0)) }
    }

    func finishWork() {
        isWorking = false
        isSelecting = false
        selectedKeys.removeAll()
    }
}

@MainActor
struct LibraryBookmarksView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library

    let onTagSearchRequested: (String, String) -> Void

    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue
    @State private var selectedDetailItem: ComicSummary?
    @State private var showShelfManager = false
    @State private var searchText = ""
    @State private var model = LibraryBookmarksScreenModel()
    @State private var selectedBookmarkKey: String?
#if os(macOS)
    @State private var selectionCommandController = MacSelectionCommandController()
    @State private var searchCommandController = MacSearchCommandController()
    @State private var isSearchPresented = false
#endif

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    private var bookmarksSnapshot: LibraryBookmarksSnapshot {
        LibraryBookmarksSnapshot(
            favorites: library.favorites,
            categories: library.favoriteCategories,
            memberships: library.favoriteCategoryMemberships,
            selectedShelfID: model.selectedShelfID,
            searchText: searchText,
            defaultShelfTitle: AppLocalization.text("library.bookmark.default_shelf", "Bookmark")
        )
    }

    var body: some View {
        let snapshot = bookmarksSnapshot

        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                headerSection
                contentSection(snapshot: snapshot)
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle(AppLocalization.text("library.bookmarks.title", "Bookmarks"))
        .bookmarkSearchable(text: $searchText, isPresented: searchPresentationBinding)
        .toolbar {
            ToolbarItem(placement: .platformTopBarTrailing) {
                Button(AppLocalization.text("library.shelves.shelves", "Shelves")) {
                    showShelfManager = true
                }
            }
            ToolbarItem(placement: .platformTopBarTrailing) {
                Button(model.isSelecting ? AppLocalization.text("common.done", "Done") : AppLocalization.text("common.select", "Select")) {
                    model.toggleSelecting()
                }
            }
            ToolbarItem(placement: .platformTopBarTrailing) {
                ComicBrowseModePicker(
                    mode: Binding(
                        get: { browseMode },
                        set: { browseMode = $0 }
                    )
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelecting, !snapshot.visibleBookmarks.isEmpty {
                BookmarkBatchSelectionBar(
                    selectedCount: model.selectedKeys.count,
                    totalCount: snapshot.visibleBookmarks.count,
                    isWorking: model.isWorking,
                    selectAllAction: { model.selectAll(from: snapshot.visibleBookmarks) },
                    addToShelfAction: { model.showAddToShelfSheet = true },
                    removeAction: { model.showRemoveConfirm = true }
                )
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailRoutingView(vm: vm, item: item, onTagSelected: onTagSearchRequested, onNavigateBack: { selectedDetailItem = nil })
        }
        .navigationDestination(isPresented: $showShelfManager) {
            BookmarkShelvesView(vm: vm, onTagSearchRequested: onTagSearchRequested)
        }
        .confirmationDialog(
            AppLocalization.text("library.bookmarks.add_dialog.title", "Add selected bookmarks to shelf"),
            isPresented: Binding(
                get: { model.showAddToShelfSheet },
                set: { model.showAddToShelfSheet = $0 }
            ),
            titleVisibility: .visible
        ) {
            if library.favoriteCategories.isEmpty {
                Button(AppLocalization.text("library.shelves.empty", "No Shelves Available"), role: .cancel) {}
            } else {
                ForEach(library.favoriteCategories) { shelf in
                    Button(shelf.name) {
                        Task { await addSelectedBookmarks(to: shelf, from: snapshot.visibleBookmarks) }
                    }
                }
                Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {}
            }
        } message: {
            Text(addToShelfDialogMessage)
        }
        .alert(AppLocalization.text("library.bookmarks.remove_dialog.title", "Remove selected bookmarks?"), isPresented: Binding(
            get: { model.showRemoveConfirm },
            set: { model.showRemoveConfirm = $0 }
        )) {
            Button(AppLocalization.text("library.bookmarks.remove", "Remove"), role: .destructive) {
                Task { await removeSelectedBookmarks(from: snapshot.visibleBookmarks) }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalization.format("library.bookmarks.remove_dialog.message_format", "Remove %lld selected bookmarks from your local library?", Int64(model.selectedKeys.count)))
        }
        .onAppear {
            reconcileSelectedBookmark(visibleBookmarkKeys: snapshot.visibleBookmarkKeys)
            configureSelectionCommands(visibleBookmarks: snapshot.visibleBookmarks)
            configureSearchCommands()
        }
        .onChange(of: snapshot.visibleBookmarkKeys) { _, newValue in
            reconcileSelectedBookmark(visibleBookmarkKeys: newValue)
            configureSelectionCommands(visibleBookmarks: snapshot.visibleBookmarks)
        }
        .onChange(of: selectedBookmarkKey) { _, _ in
            configureSelectionCommands(visibleBookmarks: snapshot.visibleBookmarks)
        }
#if os(macOS)
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
        .focusedSceneValue(\.macSearchCommandController, searchCommandController)
#endif
    }

    private var searchPresentationBinding: Binding<Bool> {
#if os(macOS)
        $isSearchPresented
#else
        .constant(false)
#endif
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                statCard(
                    title: AppLocalization.text("library.bookmarks.title", "Bookmarks"),
                    value: "\(library.favorites.count)",
                    subtitle: AppLocalization.text("library.bookmarks.saved_locally", "Saved locally")
                )
                statCard(
                    title: AppLocalization.text("library.shelves.shelves", "Shelves"),
                    value: "\(library.favoriteCategories.count)",
                    subtitle: AppLocalization.text("library.shelves.organization", "Organization")
                )
            }
            shelfFilterRow
        }
    }

    @ViewBuilder
    private func contentSection(snapshot: LibraryBookmarksSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AppLocalization.text("library.bookmarks.saved_comics", "Saved Comics"))
                .font(.title3.weight(.semibold))

            if snapshot.visibleBookmarks.isEmpty {
                Text(searchText.isEmpty ? AppLocalization.text("library.bookmarks.empty_hint", "Bookmark comics from detail pages to keep them in your local library.") : AppLocalization.text("library.bookmarks.empty_search", "No bookmarks match your search."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appCardStyle()
            } else if browseMode == .grid {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: AppSpacing.md),
                        GridItem(.flexible(), spacing: AppSpacing.md)
                    ],
                    spacing: AppSpacing.md
                ) {
                    ForEach(snapshot.visibleBookmarks) { favorite in
                        bookmarkGridItem(for: favorite, subtitle: snapshot.subtitle(for: favorite))
                    }
                }
            } else {
                LazyVStack(spacing: AppSpacing.md) {
                    ForEach(snapshot.visibleBookmarks) { favorite in
                        bookmarkListItem(for: favorite, subtitle: snapshot.subtitle(for: favorite))
                    }
                }
            }
        }
    }

    private func bookmarkGridItem(for favorite: FavoriteComic, subtitle: String?) -> some View {
        Button {
            handleTap(on: favorite)
        } label: {
            ZStack(alignment: .topTrailing) {
                ComicPreviewGridCard(
                    title: favorite.title,
                    coverURL: favorite.coverURL,
                    sourceKey: favorite.sourceKey,
                    entityID: favorite.id,
                    author: nil,
                    tags: [],
                    subtitle: subtitle
                )

                if model.isSelecting {
                    selectionBadge(isSelected: model.isSelected(favorite))
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            bookmarkContextMenu(for: favorite)
        }
    }

    private func bookmarkListItem(for favorite: FavoriteComic, subtitle: String?) -> some View {
        Button {
            handleTap(on: favorite)
        } label: {
            ZStack(alignment: .topTrailing) {
                ComicPreviewCard(
                    title: favorite.title,
                    coverURL: favorite.coverURL,
                    sourceKey: favorite.sourceKey,
                    entityID: favorite.id,
                    author: nil,
                    tags: [],
                    subtitle: subtitle
                )

                if model.isSelecting {
                    selectionBadge(isSelected: model.isSelected(favorite))
                        .padding(10)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            bookmarkContextMenu(for: favorite)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !model.isSelecting {
                Button(AppLocalization.text("library.bookmarks.remove", "Remove"), role: .destructive) {
                    Task {
                        await removeBookmark(favorite)
                    }
                }
            }
        }
    }

    private func selectionBadge(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? AppTint.accent : PlatformColors.tertiaryLabel)
            .padding(4)
            .background(.thinMaterial, in: Circle())
    }

    private func statCard(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private var shelfFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                shelfFilterChip(title: AppLocalization.text("library.bookmarks.all", "All"), isSelected: model.selectedShelfID == nil) {
                    model.selectedShelfID = nil
                }

                ForEach(library.favoriteCategories) { shelf in
                    shelfFilterChip(title: shelf.name, isSelected: model.selectedShelfID == shelf.id) {
                        model.selectedShelfID = shelf.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func shelfFilterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? AppTint.accent : AppSurface.card, in: Capsule(style: .continuous))
                .overlay {
                    if !isSelected {
                        Capsule(style: .continuous)
                            .stroke(AppSurface.border, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func handleTap(on favorite: FavoriteComic) {
        selectedBookmarkKey = model.favoriteKey(for: favorite)
        if model.isSelecting {
            model.toggleSelection(for: favorite)
        } else {
            openDetail(for: favorite)
        }
    }

    private func openDetail(for favorite: FavoriteComic) {
        selectedBookmarkKey = model.favoriteKey(for: favorite)
        selectedDetailItem = ComicSummary(
            id: favorite.id,
            sourceKey: favorite.sourceKey,
            title: favorite.title,
            coverURL: favorite.coverURL
        )
    }

    @ViewBuilder
    private func bookmarkContextMenu(for favorite: FavoriteComic) -> some View {
        Button(AppLocalization.text("common.open", "Open"), systemImage: "arrow.up.right.square") {
            openDetail(for: favorite)
        }
        Menu(AppLocalization.text("library.bookmarks.add_to_shelf", "Add to Shelf"), systemImage: "square.stack.3d.up") {
            if library.favoriteCategories.isEmpty {
                Button(AppLocalization.text("library.shelves.empty", "No Shelves Available")) { }
                    .disabled(true)
            } else {
                ForEach(library.favoriteCategories) { shelf in
                    Button(shelf.name) {
                        Task { await library.addBookmarks([favorite], to: shelf) }
                    }
                }
            }
        }
        Divider()
        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyBookmarkTitle(favorite)
        }
        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyBookmarkID(favorite)
        }
        Button(AppLocalization.text("search.action.copy_source", "Copy Source"), systemImage: "shippingbox") {
            copyBookmarkSource(favorite)
        }
        Divider()
        Button(AppLocalization.text("library.bookmarks.remove", "Remove"), systemImage: "trash", role: .destructive) {
            Task { await removeBookmark(favorite) }
        }
    }

    private var addToShelfDialogMessage: String {
        if library.favoriteCategories.isEmpty {
            return AppLocalization.text("library.bookmarks.add_dialog.empty_hint", "Create a shelf first in Library -> Shelves.")
        }
        return AppLocalization.format(
            "library.bookmarks.add_dialog.message_format",
            "Choose where to place %lld bookmarks.",
            Int64(model.selectedKeys.count)
        )
    }

    private func addSelectedBookmarks(to shelf: LibraryCategory, from bookmarks: [FavoriteComic]) async {
        let selected = model.selectedFavorites(from: bookmarks)
        guard !selected.isEmpty else { return }
        model.isWorking = true
        await library.addBookmarks(selected, to: shelf)
        model.showAddToShelfSheet = false
        model.finishWork()
    }

    private func removeSelectedBookmarks(from bookmarks: [FavoriteComic]) async {
        let selected = model.selectedFavorites(from: bookmarks)
        guard !selected.isEmpty else { return }
        model.isWorking = true
        for favorite in selected {
            await library.removeBookmark(
                ComicSummary(
                    id: favorite.id,
                    sourceKey: favorite.sourceKey,
                    title: favorite.title,
                    coverURL: favorite.coverURL
                )
            )
        }
        model.showRemoveConfirm = false
        model.finishWork()
    }

    private func removeBookmark(_ favorite: FavoriteComic) async {
        selectedBookmarkKey = model.favoriteKey(for: favorite)
        await library.removeBookmark(
            ComicSummary(
                id: favorite.id,
                sourceKey: favorite.sourceKey,
                title: favorite.title,
                coverURL: favorite.coverURL
            )
        )
        reconcileSelectedBookmark()
        configureSelectionCommands()
    }

    private func copyBookmarkTitle(_ favorite: FavoriteComic) {
        selectedBookmarkKey = model.favoriteKey(for: favorite)
        PlatformPasteboard.copy(favorite.title)
    }

    private func copyBookmarkID(_ favorite: FavoriteComic) {
        selectedBookmarkKey = model.favoriteKey(for: favorite)
        PlatformPasteboard.copy(favorite.id)
    }

    private func copyBookmarkSource(_ favorite: FavoriteComic) {
        selectedBookmarkKey = model.favoriteKey(for: favorite)
        PlatformPasteboard.copy(favorite.sourceKey)
    }

    private func reconcileSelectedBookmark(visibleBookmarkKeys: [String]? = nil) {
        let keys = visibleBookmarkKeys ?? bookmarksSnapshot.visibleBookmarkKeys
        if let selectedBookmarkKey, keys.contains(selectedBookmarkKey) {
            return
        }
        selectedBookmarkKey = keys.first
    }

    private func configureSelectionCommands(visibleBookmarks: [FavoriteComic]? = nil) {
#if os(macOS)
        selectionCommandController.reset()
        let bookmarks = visibleBookmarks ?? bookmarksSnapshot.visibleBookmarks
        guard let selectedBookmarkKey,
              let favorite = bookmarks.first(where: { model.favoriteKey(for: $0) == selectedBookmarkKey })
        else { return }

        selectionCommandController.open = { openDetail(for: favorite) }
        selectionCommandController.delete = { Task { await removeBookmark(favorite) } }
        selectionCommandController.copyTitle = { copyBookmarkTitle(favorite) }
        selectionCommandController.copyID = { copyBookmarkID(favorite) }
        selectionCommandController.export = { copyBookmarkSource(favorite) }
        selectionCommandController.exportTitle = AppLocalization.text("search.action.copy_source", "Copy Source")
        selectionCommandController.canOpen = true
        selectionCommandController.canDelete = true
        selectionCommandController.canCopyTitle = true
        selectionCommandController.canCopyID = true
        selectionCommandController.canExport = true
#endif
    }

    private func configureSearchCommands() {
#if os(macOS)
        searchCommandController.focusSearch = { isSearchPresented = true }
        searchCommandController.canFocusSearch = true
#endif
    }
}

private extension View {
    @ViewBuilder
    func bookmarkSearchable(text: Binding<String>, isPresented: Binding<Bool>) -> some View {
#if os(macOS)
        searchable(
            text: text,
            isPresented: isPresented,
            prompt: AppLocalization.text("library.bookmarks.search_placeholder", "Search bookmarks")
        )
#else
        searchable(
            text: text,
            prompt: AppLocalization.text("library.bookmarks.search_placeholder", "Search bookmarks")
        )
#endif
    }
}
