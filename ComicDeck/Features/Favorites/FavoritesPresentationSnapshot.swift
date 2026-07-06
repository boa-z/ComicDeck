import Foundation

struct FavoriteSourceOption: Identifiable, Hashable {
    let key: String
    let name: String
    let label: String

    var id: String { key }
}

struct FavoritesPresentationSnapshot: Hashable {
    let sourceOptions: [FavoriteSourceOption]
    let sourceOptionKeys: [String]
    let favoriteKeys: [String]
    let selectedInstalledSource: InstalledSource?
    private let favoriteByKey: [String: ComicSummary]

    init(
        installedSources: [InstalledSource],
        libraryFavorites: [FavoriteComic],
        sourceFavorites: [ComicSummary],
        selectedSourceKey: String
    ) {
        var sourceNamesByKey: [String: String] = [:]
        sourceNamesByKey.reserveCapacity(installedSources.count + libraryFavorites.count)
        for source in installedSources {
            sourceNamesByKey[source.key] = source.name
        }
        for favorite in libraryFavorites where sourceNamesByKey[favorite.sourceKey] == nil {
            sourceNamesByKey[favorite.sourceKey] = favorite.sourceKey
        }

        self.sourceOptions = sourceNamesByKey
            .map { key, name in
                FavoriteSourceOption(key: key, name: name, label: "\(name) (\(key))")
            }
            .sorted { lhs, rhs in
                lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }
        self.sourceOptionKeys = sourceOptions.map(\.key)
        self.selectedInstalledSource = installedSources.first { $0.key == selectedSourceKey }

        var favoriteKeys: [String] = []
        var favoriteByKey: [String: ComicSummary] = [:]
        favoriteKeys.reserveCapacity(sourceFavorites.count)
        favoriteByKey.reserveCapacity(sourceFavorites.count)
        for favorite in sourceFavorites {
            let key = Self.favoriteKey(for: favorite)
            favoriteKeys.append(key)
            favoriteByKey[key] = favorite
        }
        self.favoriteKeys = favoriteKeys
        self.favoriteByKey = favoriteByKey
    }

    func favorite(matching key: String?) -> ComicSummary? {
        guard let key else { return nil }
        return favoriteByKey[key]
    }

    static func favoriteKey(for item: ComicSummary) -> String {
        "\(item.sourceKey)::\(item.id)"
    }
}
