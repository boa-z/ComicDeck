import Foundation

struct LibraryBookmarkRowSnapshot: Hashable, Identifiable {
    let id: String
    let favorite: FavoriteComic
    let subtitle: String
    let isSelected: Bool
}

struct LibraryBookmarksSnapshot: Hashable {
    let visibleRows: [LibraryBookmarkRowSnapshot]
    let visibleBookmarks: [FavoriteComic]
    let visibleBookmarkKeys: [String]
    let selectedVisibleBookmarks: [FavoriteComic]

    var selectedVisibleCount: Int {
        selectedVisibleBookmarks.count
    }

    init(
        favorites: [FavoriteComic],
        categories: [LibraryCategory],
        memberships: [Int64: Set<String>],
        selectedShelfID: Int64?,
        searchText: String,
        selectedKeys: Set<String> = [],
        defaultShelfTitle: String
    ) {
        let selectedMemberships: Set<String>?
        if let selectedShelfID, categories.contains(where: { $0.id == selectedShelfID }) {
            selectedMemberships = memberships[selectedShelfID] ?? []
        } else {
            selectedMemberships = nil
        }

        var shelfNamesByBookmarkKey: [String: [String]] = [:]
        for category in categories {
            guard let memberKeys = memberships[category.id], !memberKeys.isEmpty else {
                continue
            }
            for key in memberKeys {
                shelfNamesByBookmarkKey[key, default: []].append(category.name)
            }
        }

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [LibraryBookmarkRowSnapshot] = []
        var bookmarks: [FavoriteComic] = []
        var keys: [String] = []
        var selectedBookmarks: [FavoriteComic] = []
        rows.reserveCapacity(favorites.count)
        bookmarks.reserveCapacity(favorites.count)
        keys.reserveCapacity(favorites.count)

        for favorite in favorites {
            let key = Self.bookmarkKey(for: favorite)
            if let selectedMemberships, !selectedMemberships.contains(key) {
                continue
            }
            if !trimmedSearch.isEmpty,
               !favorite.title.localizedCaseInsensitiveContains(trimmedSearch),
               !favorite.sourceKey.localizedCaseInsensitiveContains(trimmedSearch) {
                continue
            }

            let shelfNames = shelfNamesByBookmarkKey[key] ?? []
            let isSelected = selectedKeys.contains(key)
            bookmarks.append(favorite)
            rows.append(
                LibraryBookmarkRowSnapshot(
                    id: key,
                    favorite: favorite,
                    subtitle: shelfNames.isEmpty ? defaultShelfTitle : shelfNames.prefix(2).joined(separator: " · "),
                    isSelected: isSelected
                )
            )
            keys.append(key)
            if isSelected {
                selectedBookmarks.append(favorite)
            }
        }

        visibleBookmarks = bookmarks
        visibleRows = rows
        visibleBookmarkKeys = keys
        selectedVisibleBookmarks = selectedBookmarks
    }

    static func bookmarkKey(for favorite: FavoriteComic) -> String {
        "\(favorite.sourceKey)::\(favorite.id)"
    }
}
