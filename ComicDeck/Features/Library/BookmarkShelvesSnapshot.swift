import Foundation

struct BookmarkShelvesSnapshot: Hashable {
    let categories: [LibraryCategory]
    let assignedBookmarkCount: Int
    private let bookmarkCountByCategoryID: [Int64: Int]

    init(categories: [LibraryCategory], memberships: [Int64: Set<String>]) {
        self.categories = categories
        var counts: [Int64: Int] = [:]
        var assignedBookmarkCount = 0
        for category in categories {
            let count = memberships[category.id]?.count ?? 0
            counts[category.id] = count
            assignedBookmarkCount += count
        }
        self.bookmarkCountByCategoryID = counts
        self.assignedBookmarkCount = assignedBookmarkCount
    }

    func bookmarkCount(in category: LibraryCategory) -> Int {
        bookmarkCountByCategoryID[category.id] ?? 0
    }
}

struct BookmarkShelfAddFavoritesSnapshot: Hashable {
    struct Row: Identifiable, Hashable {
        let favorite: FavoriteComic
        let key: String

        var id: String { key }
    }

    let rows: [Row]

    init(
        category: LibraryCategory,
        favorites: [FavoriteComic],
        memberships: [Int64: Set<String>]
    ) {
        let assignedKeys = memberships[category.id] ?? []
        rows = favorites.compactMap { favorite in
            let key = Self.favoriteKey(for: favorite)
            guard !assignedKeys.contains(key) else { return nil }
            return Row(favorite: favorite, key: key)
        }
    }

    func selectedFavorites(matching selectedKeys: Set<String>) -> [FavoriteComic] {
        rows.compactMap { row in
            selectedKeys.contains(row.key) ? row.favorite : nil
        }
    }

    private static func favoriteKey(for favorite: FavoriteComic) -> String {
        "\(favorite.sourceKey)::\(favorite.id)"
    }
}

struct BookmarkShelfDetailSnapshot: Hashable {
    let favorites: [FavoriteComic]
    let favoriteKeys: [String]
    private let favoriteByKey: [String: FavoriteComic]

    init(favorites: [FavoriteComic]) {
        self.favorites = favorites
        var keys: [String] = []
        var favoritesByKey: [String: FavoriteComic] = [:]
        keys.reserveCapacity(favorites.count)
        favoritesByKey.reserveCapacity(favorites.count)
        for favorite in favorites {
            let key = Self.favoriteKey(for: favorite)
            keys.append(key)
            favoritesByKey[key] = favorite
        }
        self.favoriteKeys = keys
        self.favoriteByKey = favoritesByKey
    }

    func key(for favorite: FavoriteComic) -> String {
        Self.favoriteKey(for: favorite)
    }

    static func key(for favorite: FavoriteComic) -> String {
        favoriteKey(for: favorite)
    }

    func selectedFavorite(matching selectedKey: String?) -> FavoriteComic? {
        guard let selectedKey else { return nil }
        return favoriteByKey[selectedKey]
    }

    private static func favoriteKey(for favorite: FavoriteComic) -> String {
        "\(favorite.sourceKey)::\(favorite.id)"
    }
}
