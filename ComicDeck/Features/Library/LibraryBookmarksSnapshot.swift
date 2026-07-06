import Foundation

struct LibraryBookmarksSnapshot: Hashable {
    let visibleBookmarks: [FavoriteComic]
    let visibleBookmarkKeys: [String]
    let shelfSubtitleByBookmarkKey: [String: String]

    init(
        favorites: [FavoriteComic],
        categories: [LibraryCategory],
        memberships: [Int64: Set<String>],
        selectedShelfID: Int64?,
        searchText: String,
        defaultShelfTitle: String
    ) {
        let selectedMemberships: Set<String>?
        if let selectedShelfID, categories.contains(where: { $0.id == selectedShelfID }) {
            selectedMemberships = memberships[selectedShelfID] ?? []
        } else {
            selectedMemberships = nil
        }

        let shelfFiltered = selectedMemberships.map { keys in
            favorites.filter { keys.contains(Self.bookmarkKey(for: $0)) }
        } ?? favorites

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSearch.isEmpty {
            visibleBookmarks = shelfFiltered
        } else {
            visibleBookmarks = shelfFiltered.filter { favorite in
                favorite.title.localizedCaseInsensitiveContains(trimmedSearch) ||
                    favorite.sourceKey.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }

        visibleBookmarkKeys = visibleBookmarks.map(Self.bookmarkKey(for:))

        var shelfNamesByBookmarkKey: [String: [String]] = [:]
        for category in categories {
            guard let memberKeys = memberships[category.id], !memberKeys.isEmpty else {
                continue
            }
            for key in memberKeys {
                shelfNamesByBookmarkKey[key, default: []].append(category.name)
            }
        }

        var subtitles: [String: String] = [:]
        for favorite in visibleBookmarks {
            let key = Self.bookmarkKey(for: favorite)
            let shelfNames = shelfNamesByBookmarkKey[key] ?? []
            subtitles[key] = shelfNames.isEmpty ? defaultShelfTitle : shelfNames.prefix(2).joined(separator: " · ")
        }
        shelfSubtitleByBookmarkKey = subtitles
    }

    func subtitle(for favorite: FavoriteComic) -> String {
        shelfSubtitleByBookmarkKey[Self.bookmarkKey(for: favorite)] ?? ""
    }

    static func bookmarkKey(for favorite: FavoriteComic) -> String {
        "\(favorite.sourceKey)::\(favorite.id)"
    }
}
