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

                Button("Add to Shelf") {
                    addToShelfAction()
                }
                .font(.subheadline.weight(.semibold))
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(selectedCount == 0 || isWorking)

                Button("Remove", role: .destructive) {
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

    private var browseMode: ComicBrowseDisplayMode {
        get { ComicBrowseDisplayMode(rawValue: browseModeRaw) ?? .list }
        nonmutating set { browseModeRaw = newValue.rawValue }
    }

    private var filteredBookmarks: [FavoriteComic] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let shelfFiltered = bookmarksForSelectedShelf()
        guard !trimmed.isEmpty else { return shelfFiltered }
        return shelfFiltered.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) ||
            $0.sourceKey.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.section) {
                headerSection
                contentSection
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle("Bookmarks")
        .searchable(text: $searchText, prompt: "Search bookmarks")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Shelves") {
                    showShelfManager = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.isSelecting ? "Done" : "Select") {
                    model.toggleSelecting()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ComicBrowseModePicker(
                    mode: Binding(
                        get: { browseMode },
                        set: { browseMode = $0 }
                    )
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelecting, !filteredBookmarks.isEmpty {
                BookmarkBatchSelectionBar(
                    selectedCount: model.selectedKeys.count,
                    totalCount: filteredBookmarks.count,
                    isWorking: model.isWorking,
                    selectAllAction: { model.selectAll(from: filteredBookmarks) },
                    addToShelfAction: { model.showAddToShelfSheet = true },
                    removeAction: { model.showRemoveConfirm = true }
                )
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        .navigationDestination(item: $selectedDetailItem) { item in
            ComicDetailView(vm: vm, item: item, onTagSelected: onTagSearchRequested)
        }
        .navigationDestination(isPresented: $showShelfManager) {
            BookmarkShelvesView(vm: vm, onTagSearchRequested: onTagSearchRequested)
        }
        .confirmationDialog(
            "Add selected bookmarks to shelf",
            isPresented: Binding(
                get: { model.showAddToShelfSheet },
                set: { model.showAddToShelfSheet = $0 }
            ),
            titleVisibility: .visible
        ) {
            if library.favoriteCategories.isEmpty {
                Button("No Shelves Available", role: .cancel) {}
            } else {
                ForEach(library.favoriteCategories) { shelf in
                    Button(shelf.name) {
                        Task { await addSelectedBookmarks(to: shelf) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text(library.favoriteCategories.isEmpty ? "Create a shelf first in Library -> Shelves." : "Choose where to place \(model.selectedKeys.count) bookmark\(model.selectedKeys.count == 1 ? "" : "s").")
        }
        .alert("Remove selected bookmarks?", isPresented: Binding(
            get: { model.showRemoveConfirm },
            set: { model.showRemoveConfirm = $0 }
        )) {
            Button("Remove", role: .destructive) {
                Task { await removeSelectedBookmarks() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \(model.selectedKeys.count) selected bookmark\(model.selectedKeys.count == 1 ? "" : "s") from your local library?")
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(spacing: AppSpacing.md) {
                statCard(title: "Bookmarks", value: "\(library.favorites.count)", subtitle: "Saved locally")
                statCard(title: "Shelves", value: "\(library.favoriteCategories.count)", subtitle: "Organization")
            }
            shelfFilterRow
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Saved Comics")
                .font(.title3.weight(.semibold))

            if filteredBookmarks.isEmpty {
                Text(searchText.isEmpty ? "Bookmark comics from detail pages to keep them in your local library." : "No bookmarks match your search.")
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
                    ForEach(filteredBookmarks) { favorite in
                        bookmarkGridItem(for: favorite)
                    }
                }
            } else {
                VStack(spacing: AppSpacing.md) {
                    ForEach(filteredBookmarks) { favorite in
                        bookmarkListItem(for: favorite)
                    }
                }
            }
        }
    }

    private func bookmarkGridItem(for favorite: FavoriteComic) -> some View {
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
                    subtitle: shelfSubtitle(for: favorite)
                )

                if model.isSelecting {
                    selectionBadge(isSelected: model.isSelected(favorite))
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func bookmarkListItem(for favorite: FavoriteComic) -> some View {
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
                    subtitle: shelfSubtitle(for: favorite)
                )

                if model.isSelecting {
                    selectionBadge(isSelected: model.isSelected(favorite))
                        .padding(10)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !model.isSelecting {
                Button("Remove", role: .destructive) {
                    Task {
                        await library.removeBookmark(
                            ComicSummary(
                                id: favorite.id,
                                sourceKey: favorite.sourceKey,
                                title: favorite.title,
                                coverURL: favorite.coverURL
                            )
                        )
                    }
                }
            }
        }
    }

    private func selectionBadge(isSelected: Bool) -> some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? AppTint.accent : Color(uiColor: .tertiaryLabel))
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
                shelfFilterChip(title: "All", isSelected: model.selectedShelfID == nil) {
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
        if model.isSelecting {
            model.toggleSelection(for: favorite)
        } else {
            openDetail(for: favorite)
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

    private func shelfSubtitle(for favorite: FavoriteComic) -> String? {
        let shelves = library.favoriteCategories.compactMap { category -> String? in
            let members = library.favoriteCategoryMemberships[category.id] ?? []
            return members.contains("\(favorite.sourceKey)::\(favorite.id)") ? category.name : nil
        }
        return shelves.isEmpty ? "Bookmark" : shelves.prefix(2).joined(separator: " · ")
    }

    private func bookmarksForSelectedShelf() -> [FavoriteComic] {
        guard let selectedShelfID = model.selectedShelfID else { return library.favorites }
        guard let shelf = library.favoriteCategories.first(where: { $0.id == selectedShelfID }) else {
            return library.favorites
        }
        return library.bookmarks(in: shelf)
    }

    private func addSelectedBookmarks(to shelf: LibraryCategory) async {
        let selected = model.selectedFavorites(from: filteredBookmarks)
        guard !selected.isEmpty else { return }
        model.isWorking = true
        await library.addBookmarks(selected, to: shelf)
        model.showAddToShelfSheet = false
        model.finishWork()
    }

    private func removeSelectedBookmarks() async {
        let selected = model.selectedFavorites(from: filteredBookmarks)
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
}
