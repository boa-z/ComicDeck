import SwiftUI
import Observation

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
    @State private var editMode: EditMode = .active

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.reorderCategories) { category in
                    HStack(spacing: AppSpacing.md) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category.name)
                                .font(.headline)
                            Text("\(library.bookmarkCount(in: category)) bookmarks")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onMove { from, to in
                    model.reorderCategories.move(fromOffsets: from, toOffset: to)
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle(AppLocalization.text("library.shelves.reorder", "Reorder Shelves"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(AppLocalization.text("common.cancel", "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
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
}

@MainActor
struct BookmarkShelvesView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library

    let onTagSearchRequested: (String, String) -> Void

    @State private var model = BookmarkShelvesScreenModel()

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
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.text("library.shelves.title", "Shelves"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
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
            .presentationDetents([.medium, .large])
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
                            model.selectedCategory = category
                        }
                        .listRowInsets(EdgeInsets(top: AppSpacing.sm, leading: AppSpacing.screen, bottom: AppSpacing.sm, trailing: AppSpacing.screen))
                        .listRowSeparator(.hidden)
                        .listRowBackground(AppSurface.card)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
                        .padding(.vertical, 2)
                        .padding(.horizontal, 0)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Rename") {
                                model.beginRename(category)
                            }
                            .tint(AppTint.accent)

                            Button("Delete", role: .destructive) {
                                model.categoryToDelete = category
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button("Add Bookmarks") {
                                model.beginAddFavorites(to: category)
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
                Text("\(library.bookmarkCount(in: category)) bookmarks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Menu {
                Button("Add Bookmarks", systemImage: "plus") {
                    model.beginAddFavorites(to: category)
                }
                Button("Rename", systemImage: "pencil") {
                    model.beginRename(category)
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    model.categoryToDelete = category
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
                Text("All bookmarks are already in this shelf.")
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
                                        : Color(uiColor: .tertiaryLabel)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Add to \(category.name)")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    model.categoryToAddFavorites = nil
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add") {
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
}

@MainActor
private struct BookmarkShelfDetailView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library

    let category: LibraryCategory
    let onTagSearchRequested: (String, String) -> Void

    @AppStorage("ui.comicBrowseMode") private var browseModeRaw = ComicBrowseDisplayMode.list.rawValue
    @State private var selectedDetailItem: ComicSummary?

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    private var favorites: [FavoriteComic] {
        library.bookmarks(in: category)
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
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Remove", role: .destructive) {
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
            ToolbarItem(placement: .topBarTrailing) {
                ComicBrowseModePicker(
                    mode: Binding(
                        get: { browseMode },
                        set: { browseMode = $0 }
                    )
                )
            }
        }
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailView(vm: vm, item: item, onTagSelected: onTagSearchRequested)
        }
    }

    private func openDetail(for favorite: FavoriteComic) {
        selectedDetailItem = ComicSummary(
            id: favorite.id,
            sourceKey: favorite.sourceKey,
            title: favorite.title,
            coverURL: favorite.coverURL
        )
    }
}
