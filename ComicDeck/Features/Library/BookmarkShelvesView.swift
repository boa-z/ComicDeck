import SwiftUI
import Observation
#if os(macOS)
import UniformTypeIdentifiers
#endif

@MainActor
@Observable
final class BookmarkShelvesScreenModel {
    var createName = ""
    var renameName = ""
    var categoryToRename: LibraryCategory?
    var categoryToDelete: LibraryCategory?
    var categoryToAddFavorites: LibraryCategory?
    var selectedCategory: LibraryCategory?
    var selectedFavoriteKeys: Set<String> = []
    var showingCreate = false
    var showingReorder = false
    var reorderCategories: [LibraryCategory] = []

    func beginRename(_ category: LibraryCategory) {
        categoryToRename = category
        renameName = category.name
    }

    func beginAddFavorites(to category: LibraryCategory) {
        categoryToAddFavorites = category
        selectedFavoriteKeys = []
    }

    func beginReorder(with categories: [LibraryCategory]) {
        reorderCategories = categories
        showingReorder = true
    }

    func resetCreate() {
        createName = ""
        showingCreate = false
    }

    func favoriteKey(for favorite: FavoriteComic) -> String {
        "\(favorite.sourceKey)::\(favorite.id)"
    }
}

@MainActor
private struct BookmarkShelfReorderView: View {
    @Bindable var model: BookmarkShelvesScreenModel
    @Environment(LibraryViewModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @State private var editMode: EditMode = .active
    #else
    @State private var draggingCategoryID: LibraryCategory.ID?
    #endif

    var body: some View {
        NavigationStack {
            List {
                #if os(iOS)
                ForEach(model.reorderCategories) { category in
                    reorderRow(category)
                }
                .onMove { from, to in
                    model.reorderCategories.move(fromOffsets: from, toOffset: to)
                }
                #else
                ForEach(Array(model.reorderCategories.enumerated()), id: \.element.id) { index, category in
                    HStack(spacing: AppSpacing.md) {
                        reorderRow(category)

                        Spacer(minLength: 0)

                        Button {
                            moveCategory(at: index, by: -1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help(AppLocalization.text("library.shelves.move_up", "Move Up"))

                        Button {
                            moveCategory(at: index, by: 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == model.reorderCategories.count - 1)
                        .help(AppLocalization.text("library.shelves.move_down", "Move Down"))
                    }
                    .contentShape(Rectangle())
                    .opacity(draggingCategoryID == category.id ? 0.55 : 1)
                    .onDrag {
                        draggingCategoryID = category.id
                        return NSItemProvider(object: String(category.id) as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: BookmarkShelfDropDelegate(
                            targetCategory: category,
                            categories: $model.reorderCategories,
                            draggingCategoryID: $draggingCategoryID
                        )
                    )
                }
                #endif
            }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
            .navigationTitle(AppLocalization.text("library.shelves.reorder", "Reorder Shelves"))
            .platformNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .platformTopBarLeading) {
                    Button(AppLocalization.text("common.cancel", "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .platformTopBarTrailing) {
                    Button(AppLocalization.text("common.save", "Save")) {
                        Task {
                            await library.reorderBookmarkShelves(model.reorderCategories)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func reorderRow(_ category: LibraryCategory) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.name)
                    .font(.headline)
                Text(AppLocalization.format("library.shelves.bookmark_count_format", "%lld bookmarks", Int64(library.bookmarkCount(in: category))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func moveCategory(at index: Int, by offset: Int) {
        let destination = index + offset
        guard model.reorderCategories.indices.contains(index),
              model.reorderCategories.indices.contains(destination)
        else { return }
        model.reorderCategories.swapAt(index, destination)
    }
}

#if os(macOS)
private struct BookmarkShelfDropDelegate: DropDelegate {
    let targetCategory: LibraryCategory
    @Binding var categories: [LibraryCategory]
    @Binding var draggingCategoryID: LibraryCategory.ID?

    func dropEntered(info: DropInfo) {
        guard let draggingCategoryID,
              draggingCategoryID != targetCategory.id,
              let sourceIndex = categories.firstIndex(where: { $0.id == draggingCategoryID }),
              let targetIndex = categories.firstIndex(where: { $0.id == targetCategory.id })
        else { return }

        withAnimation(.easeInOut(duration: 0.16)) {
            let item = categories.remove(at: sourceIndex)
            categories.insert(item, at: targetIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingCategoryID = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if !info.hasItemsConforming(to: [UTType.text]) {
            draggingCategoryID = nil
        }
    }
}
#endif

@MainActor
struct BookmarkShelvesView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library

    let onTagSearchRequested: (String, String) -> Void

    @State private var model = BookmarkShelvesScreenModel()
    @State private var selectedCategoryID: LibraryCategory.ID?
#if os(macOS)
    @State private var selectionCommandController = MacSelectionCommandController()
#endif

    private var selectedCategory: LibraryCategory? {
        guard let selectedCategoryID else { return nil }
        return library.favoriteCategories.first { $0.id == selectedCategoryID }
    }

    var body: some View {
        List {
            Section {
                summarySection
                    .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.screen, bottom: AppSpacing.sm, trailing: AppSpacing.screen))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section(AppLocalization.text("library.shelves.your_shelves", "Your Shelves")) {
                categoriesSection
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppSurface.grouped.ignoresSafeArea())
        .platformInsetGroupedListStyle()
        .navigationTitle(AppLocalization.text("library.shelves.title", "Shelves"))
        .toolbar {
            ToolbarItemGroup(placement: .platformTopBarTrailing) {
                if library.favoriteCategories.count > 1 {
                    Button(AppLocalization.text("library.shelves.reorder", "Reorder")) {
                        model.beginReorder(with: library.favoriteCategories)
                    }
                }
                Button(AppLocalization.text("library.shelves.new", "New")) {
                    model.showingCreate = true
                }
            }
        }
        .alert(AppLocalization.text("library.shelves.new_shelf", "New Shelf"), isPresented: $model.showingCreate) {
            TextField(AppLocalization.text("library.shelves.name_placeholder", "Shelf name"), text: $model.createName)
            Button(AppLocalization.text("common.create", "Create")) {
                let name = model.createName
                Task { await library.createBookmarkShelf(name: name) }
                model.resetCreate()
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {
                model.resetCreate()
            }
        } message: {
            Text(AppLocalization.text("library.shelves.new_hint", "Create a shelf for organizing your bookmarked comics."))
        }
        .alert(AppLocalization.text("library.shelves.rename", "Rename Shelf"), isPresented: renameAlertBinding) {
            TextField(AppLocalization.text("library.shelves.name_placeholder", "Shelf name"), text: $model.renameName)
            Button(AppLocalization.text("common.save", "Save")) {
                guard let category = model.categoryToRename else { return }
                let name = model.renameName
                Task { await library.renameBookmarkShelf(category, name: name) }
                model.categoryToRename = nil
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {
                model.categoryToRename = nil
            }
        }
        .alert(AppLocalization.text("library.shelves.delete", "Delete Shelf"), isPresented: deleteAlertBinding) {
            Button(AppLocalization.text("common.delete", "Delete"), role: .destructive) {
                guard let category = model.categoryToDelete else { return }
                Task { await library.deleteBookmarkShelf(category) }
                model.categoryToDelete = nil
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {
                model.categoryToDelete = nil
            }
        } message: {
            if let category = model.categoryToDelete {
                Text(AppLocalization.text("library.shelves.delete_confirm", "Delete \"\(category.name)\"? Comics will remain in Bookmarks."))
            }
        }
        .sheet(item: addFavoritesSheetBinding) { category in
            NavigationStack {
                addFavoritesSheet(for: category)
            }
            .platformPresentationDetentsMediumLarge()
        }
        .sheet(isPresented: $model.showingReorder) {
            BookmarkShelfReorderView(model: model)
                .environment(library)
        }
        .navigationDestination(item: selectedCategoryBinding) { category in
            BookmarkShelfDetailView(
                vm: vm,
                category: category,
                onTagSearchRequested: onTagSearchRequested
            )
        }
        .onAppear {
            reconcileSelectedCategory()
            configureSelectionCommands()
        }
        .onChange(of: library.favoriteCategories) { _, _ in
            reconcileSelectedCategory()
            configureSelectionCommands()
        }
        .onChange(of: selectedCategoryID) { _, _ in
            configureSelectionCommands()
        }
#if os(macOS)
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
#endif
    }

    private var summarySection: some View {
        HStack(spacing: AppSpacing.md) {
            statCard(title: AppLocalization.text("library.shelves.shelves", "Shelves"), value: "\(library.favoriteCategories.count)", subtitle: AppLocalization.text("library.shelves.groups", "Groups"))
            statCard(title: AppLocalization.text("library.shelves.assigned", "Assigned"), value: "\(library.favoriteCategoryMemberships.values.reduce(0) { $0 + $1.count })", subtitle: AppLocalization.text("library.bookmarks.title", "Bookmarks"))
        }
    }

    private var categoriesSection: some View {
        Group {
            if library.favoriteCategories.isEmpty {
                Text(AppLocalization.text("library.shelves.empty_hint", "Create shelves to group bookmarks by project, mood, or reading priority."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppSpacing.sm)
            } else {
                ForEach(library.favoriteCategories) { category in
                    categoryRow(category)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedCategoryID = category.id
                            model.selectedCategory = category
                        }
                        .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.screen, bottom: AppSpacing.sm, trailing: AppSpacing.screen))
                        .listRowSeparator(.hidden)
                        .listRowBackground(AppSurface.card)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 0)
                        .contextMenu {
                            categoryContextMenu(for: category)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(AppLocalization.text("library.shelves.rename", "Rename Shelf")) {
                                beginRename(category)
                            }
                            .tint(AppTint.accent)

                            Button(AppLocalization.text("library.shelves.delete", "Delete Shelf"), role: .destructive) {
                                beginDelete(category)
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button(AppLocalization.text("library.shelves.add_bookmarks", "Add Bookmarks")) {
                                beginAddFavorites(to: category)
                            }
                            .tint(AppTint.success)
                        }
                }
            }
        }
    }

    private func categoryRow(_ category: LibraryCategory) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: "square.stack.3d.up")
                .font(.headline)
                .foregroundStyle(AppTint.accent)
                .frame(width: 40, height: 40)
                .background(AppTint.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(category.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(AppLocalization.format("library.shelves.bookmark_count_format", "%lld bookmarks", Int64(library.bookmarkCount(in: category))))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                Button(AppLocalization.text("library.shelves.add_bookmarks", "Add Bookmarks"), systemImage: "plus") {
                    beginAddFavorites(to: category)
                }
                Button(AppLocalization.text("library.shelves.rename", "Rename Shelf"), systemImage: "pencil") {
                    beginRename(category)
                }
                Button(AppLocalization.text("library.shelves.delete", "Delete Shelf"), systemImage: "trash", role: .destructive) {
                    beginDelete(category)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, AppSpacing.sm)
    }

    @ViewBuilder
    private func categoryContextMenu(for category: LibraryCategory) -> some View {
        Button(AppLocalization.text("common.open", "Open"), systemImage: "arrow.up.right.square") {
            openCategory(category)
        }
        Button(AppLocalization.text("library.shelves.add_bookmarks", "Add Bookmarks"), systemImage: "plus") {
            beginAddFavorites(to: category)
        }
        Button(AppLocalization.text("library.shelves.rename", "Rename Shelf"), systemImage: "pencil") {
            beginRename(category)
        }
        Divider()
        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyCategoryTitle(category)
        }
        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyCategoryID(category)
        }
        Divider()
        Button(AppLocalization.text("library.shelves.delete", "Delete Shelf"), systemImage: "trash", role: .destructive) {
            beginDelete(category)
        }
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

    @ViewBuilder
    private func addFavoritesSheet(for category: LibraryCategory) -> some View {
        let assignedKeys = library.favoriteCategoryMemberships[category.id] ?? []
        let availableFavorites = library.favorites.filter { !assignedKeys.contains(model.favoriteKey(for: $0)) }

        List {
            if availableFavorites.isEmpty {
                Text(AppLocalization.text("library.shelves.all_assigned_hint", "All bookmarks are already in this shelf."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableFavorites) { favorite in
                    Button {
                        let key = model.favoriteKey(for: favorite)
                        if model.selectedFavoriteKeys.contains(key) {
                            model.selectedFavoriteKeys.remove(key)
                        } else {
                            model.selectedFavoriteKeys.insert(key)
                        }
                    } label: {
                        HStack(spacing: AppSpacing.md) {
                            CoverArtworkView(urlString: favorite.coverURL, width: 44, height: 62)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(favorite.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                Text(favorite.sourceKey)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: model.selectedFavoriteKeys.contains(model.favoriteKey(for: favorite)) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(
                                    model.selectedFavoriteKeys.contains(model.favoriteKey(for: favorite))
                                        ? AppTint.accent
                                        : PlatformColors.tertiaryLabel
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(AppLocalization.format("library.shelves.add_to_title_format", "Add to %@", category.name))
        .toolbar {
            ToolbarItem(placement: .platformTopBarLeading) {
                Button(AppLocalization.text("common.cancel", "Cancel")) {
                    model.categoryToAddFavorites = nil
                }
            }
            ToolbarItem(placement: .platformTopBarTrailing) {
                Button(AppLocalization.text("common.add", "Add")) {
                    let favorites = availableFavorites.filter { model.selectedFavoriteKeys.contains(model.favoriteKey(for: $0)) }
                    Task { await library.addBookmarks(favorites, to: category) }
                    model.categoryToAddFavorites = nil
                }
                .disabled(model.selectedFavoriteKeys.isEmpty)
            }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { model.categoryToRename != nil },
            set: { if !$0 { model.categoryToRename = nil } }
        )
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { model.categoryToDelete != nil },
            set: { if !$0 { model.categoryToDelete = nil } }
        )
    }

    private var addFavoritesSheetBinding: Binding<LibraryCategory?> {
        Binding(
            get: { model.categoryToAddFavorites },
            set: { model.categoryToAddFavorites = $0 }
        )
    }

    private var selectedCategoryBinding: Binding<LibraryCategory?> {
        Binding(
            get: { model.selectedCategory },
            set: { model.selectedCategory = $0 }
        )
    }

    private func openCategory(_ category: LibraryCategory) {
        selectedCategoryID = category.id
        model.selectedCategory = category
    }

    private func beginRename(_ category: LibraryCategory) {
        selectedCategoryID = category.id
        model.beginRename(category)
        configureSelectionCommands()
    }

    private func beginDelete(_ category: LibraryCategory) {
        selectedCategoryID = category.id
        model.categoryToDelete = category
        configureSelectionCommands()
    }

    private func beginAddFavorites(to category: LibraryCategory) {
        selectedCategoryID = category.id
        model.beginAddFavorites(to: category)
        configureSelectionCommands()
    }

    private func copyCategoryTitle(_ category: LibraryCategory) {
        selectedCategoryID = category.id
        PlatformPasteboard.copy(category.name)
    }

    private func copyCategoryID(_ category: LibraryCategory) {
        selectedCategoryID = category.id
        PlatformPasteboard.copy(String(category.id))
    }

    private func reconcileSelectedCategory() {
        if let selectedCategoryID, library.favoriteCategories.contains(where: { $0.id == selectedCategoryID }) {
            return
        }
        selectedCategoryID = library.favoriteCategories.first?.id
    }

    private func configureSelectionCommands() {
#if os(macOS)
        selectionCommandController.reset()
        guard let category = selectedCategory else { return }

        selectionCommandController.open = { openCategory(category) }
        selectionCommandController.delete = { beginDelete(category) }
        selectionCommandController.copyTitle = { copyCategoryTitle(category) }
        selectionCommandController.copyID = { copyCategoryID(category) }
        selectionCommandController.export = { beginAddFavorites(to: category) }
        selectionCommandController.openTitle = AppLocalization.text("common.open", "Open")
        selectionCommandController.exportTitle = AppLocalization.text("library.shelves.add_bookmarks", "Add Bookmarks")
        selectionCommandController.canOpen = true
        selectionCommandController.canDelete = true
        selectionCommandController.canCopyTitle = true
        selectionCommandController.canCopyID = true
        selectionCommandController.canExport = true
#endif
    }
}

@MainActor
private struct BookmarkShelfDetailView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library

    let category: LibraryCategory
    let onTagSearchRequested: (String, String) -> Void

    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue
    @State private var selectedDetailItem: ComicSummary?
    @State private var selectedFavoriteKey: String?
#if os(macOS)
    @State private var selectionCommandController = MacSelectionCommandController()
#endif

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    private var favorites: [FavoriteComic] {
        library.bookmarks(in: category)
    }

    private var favoriteKeys: [String] {
        favorites.map(favoriteKey(for:))
    }

    private var selectedFavorite: FavoriteComic? {
        guard let selectedFavoriteKey else { return nil }
        return favorites.first { favoriteKey(for: $0) == selectedFavoriteKey }
    }

    var body: some View {
        Group {
            if browseMode == .grid {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: AppSpacing.md),
                            GridItem(.flexible(), spacing: AppSpacing.md)
                        ],
                        spacing: AppSpacing.md
                    ) {
                        ForEach(favorites) { favorite in
                            Button {
                                selectedFavoriteKey = favoriteKey(for: favorite)
                                openDetail(for: favorite)
                            } label: {
                                ComicPreviewGridCard(
                                    title: favorite.title,
                                    coverURL: favorite.coverURL,
                                    sourceKey: favorite.sourceKey,
                                    entityID: favorite.id,
                                    author: nil,
                                    tags: [],
                                    subtitle: category.name
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                shelfBookmarkContextMenu(for: favorite)
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.screen)
                    .padding(.top, AppSpacing.md)
                    .padding(.bottom, AppSpacing.xl)
                }
                .background(AppSurface.grouped.ignoresSafeArea())
            } else {
                ScrollView {
                    VStack(spacing: AppSpacing.md) {
                        ForEach(favorites) { favorite in
                            Button {
                                selectedFavoriteKey = favoriteKey(for: favorite)
                                openDetail(for: favorite)
                            } label: {
                                ComicPreviewCard(
                                    title: favorite.title,
                                    coverURL: favorite.coverURL,
                                    sourceKey: favorite.sourceKey,
                                    entityID: favorite.id,
                                    author: nil,
                                    tags: [],
                                    subtitle: category.name
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                shelfBookmarkContextMenu(for: favorite)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(AppLocalization.text("common.remove", "Remove"), role: .destructive) {
                                    Task { await library.removeBookmark(favorite, from: category) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.screen)
                    .padding(.top, AppSpacing.md)
                    .padding(.bottom, AppSpacing.xl)
                }
                .background(AppSurface.grouped.ignoresSafeArea())
            }
        }
        .navigationTitle(category.name)
        .toolbar {
            ToolbarItem(placement: .platformTopBarTrailing) {
                ComicBrowseModePicker(
                    mode: Binding(
                        get: { browseMode },
                        set: { browseMode = $0 }
                    )
                )
            }
        }
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailRoutingView(vm: vm, item: item, onTagSelected: onTagSearchRequested, onNavigateBack: { selectedDetailItem = nil })
        }
        .onAppear {
            reconcileSelectedFavorite()
            configureSelectionCommands()
        }
        .onChange(of: favoriteKeys) { _, _ in
            reconcileSelectedFavorite()
            configureSelectionCommands()
        }
        .onChange(of: selectedFavoriteKey) { _, _ in
            configureSelectionCommands()
        }
#if os(macOS)
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
#endif
    }

    private func openDetail(for favorite: FavoriteComic) {
        selectedFavoriteKey = favoriteKey(for: favorite)
        selectedDetailItem = ComicSummary(
            id: favorite.id,
            sourceKey: favorite.sourceKey,
            title: favorite.title,
            coverURL: favorite.coverURL
        )
    }

    @ViewBuilder
    private func shelfBookmarkContextMenu(for favorite: FavoriteComic) -> some View {
        Button(AppLocalization.text("common.open", "Open"), systemImage: "arrow.up.right.square") {
            openDetail(for: favorite)
        }
        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            copyFavoriteTitle(favorite)
        }
        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            copyFavoriteID(favorite)
        }
        Button(AppLocalization.text("search.action.copy_source", "Copy Source"), systemImage: "shippingbox") {
            copyFavoriteSource(favorite)
        }
        Divider()
        Button(AppLocalization.text("library.shelves.remove_from_shelf", "Remove from Shelf"), systemImage: "trash", role: .destructive) {
            Task { await removeFavoriteFromShelf(favorite) }
        }
    }

    private func favoriteKey(for favorite: FavoriteComic) -> String {
        "\(favorite.sourceKey)::\(favorite.id)"
    }

    private func removeFavoriteFromShelf(_ favorite: FavoriteComic) async {
        selectedFavoriteKey = favoriteKey(for: favorite)
        await library.removeBookmark(favorite, from: category)
        reconcileSelectedFavorite()
        configureSelectionCommands()
    }

    private func copyFavoriteTitle(_ favorite: FavoriteComic) {
        selectedFavoriteKey = favoriteKey(for: favorite)
        PlatformPasteboard.copy(favorite.title)
    }

    private func copyFavoriteID(_ favorite: FavoriteComic) {
        selectedFavoriteKey = favoriteKey(for: favorite)
        PlatformPasteboard.copy(favorite.id)
    }

    private func copyFavoriteSource(_ favorite: FavoriteComic) {
        selectedFavoriteKey = favoriteKey(for: favorite)
        PlatformPasteboard.copy(favorite.sourceKey)
    }

    private func reconcileSelectedFavorite() {
        if let selectedFavoriteKey, favoriteKeys.contains(selectedFavoriteKey) {
            return
        }
        selectedFavoriteKey = favoriteKeys.first
    }

    private func configureSelectionCommands() {
#if os(macOS)
        selectionCommandController.reset()
        guard let favorite = selectedFavorite else { return }

        selectionCommandController.open = { openDetail(for: favorite) }
        selectionCommandController.delete = { Task { await removeFavoriteFromShelf(favorite) } }
        selectionCommandController.copyTitle = { copyFavoriteTitle(favorite) }
        selectionCommandController.copyID = { copyFavoriteID(favorite) }
        selectionCommandController.export = { copyFavoriteSource(favorite) }
        selectionCommandController.exportTitle = AppLocalization.text("search.action.copy_source", "Copy Source")
        selectionCommandController.canOpen = true
        selectionCommandController.canDelete = true
        selectionCommandController.canCopyTitle = true
        selectionCommandController.canCopyID = true
        selectionCommandController.canExport = true
#endif
    }
}
