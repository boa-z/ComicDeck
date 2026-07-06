import Foundation

struct TrackerSubscriptionDetailSnapshot {
    let localGroups: [TrackerSubscriptionLocalGroupSnapshot]

    @MainActor
    static func make(
        provider: TrackerProvider,
        bindingGroups: [[TrackerProvider: TrackerBinding]],
        library: LibraryViewModel
    ) -> TrackerSubscriptionDetailSnapshot {
        let localIndex = TrackerSubscriptionLocalComicIndex(library: library)
        var groups: [TrackerSubscriptionLocalGroupSnapshot] = []
        groups.reserveCapacity(bindingGroups.count)
        for bindings in bindingGroups {
            guard let providerBinding = bindings[provider] else { continue }
            let localComic = localIndex.comic(for: providerBinding)
            let localGroup = TrackerSubscriptionLocalGroup(
                sourceKey: providerBinding.sourceKey,
                comicID: providerBinding.comicID,
                title: localComic?.title ?? providerBinding.sourceTitle ?? providerBinding.remoteTitle,
                coverURL: localComic?.coverURL ?? providerBinding.sourceCoverURL ?? providerBinding.remoteCoverURL,
                bindings: bindings
            )
            let sortedBindings = TrackerProvider.mangaListWorkspaceProviders.compactMap { bindings[$0] }
            let snapshot = TrackerSubscriptionLocalGroupSnapshot(
                group: localGroup,
                localHistory: localIndex.history(for: providerBinding),
                sortedBindings: sortedBindings
            )
            groups.append(snapshot)
        }
        return TrackerSubscriptionDetailSnapshot(localGroups: groups)
    }
}

struct TrackerSubscriptionLocalGroupSnapshot: Identifiable {
    var id: String { group.id }
    let group: TrackerSubscriptionLocalGroup
    let localHistory: ReadingHistoryItem?
    let sortedBindings: [TrackerBinding]
}

private struct TrackerSubscriptionLocalComicIndex {
    private let favoriteComics: [String: ComicSummary]
    private let historyItems: [String: ReadingHistoryItem]
    private let offlineComics: [String: ComicSummary]

    @MainActor
    init(library: LibraryViewModel) {
        var favoriteComics: [String: ComicSummary] = [:]
        favoriteComics.reserveCapacity(library.favorites.count)
        for favorite in library.favorites {
            let key = Self.key(sourceKey: favorite.sourceKey, comicID: favorite.id)
            if favoriteComics[key] == nil {
                favoriteComics[key] = ComicSummary(
                    id: favorite.id,
                    sourceKey: favorite.sourceKey,
                    title: favorite.title,
                    coverURL: favorite.coverURL
                )
            }
        }

        var historyItems: [String: ReadingHistoryItem] = [:]
        historyItems.reserveCapacity(library.history.count)
        for history in library.history {
            let key = Self.key(sourceKey: history.sourceKey, comicID: history.comicID)
            if historyItems[key] == nil {
                historyItems[key] = history
            }
        }

        var offlineComics: [String: ComicSummary] = [:]
        offlineComics.reserveCapacity(library.offlineChapters.count)
        for offline in library.offlineChapters {
            let key = Self.key(sourceKey: offline.sourceKey, comicID: offline.comicID)
            if offlineComics[key] == nil {
                offlineComics[key] = ComicSummary(
                    id: offline.comicID,
                    sourceKey: offline.sourceKey,
                    title: offline.comicTitle,
                    coverURL: offline.coverURL
                )
            }
        }

        self.favoriteComics = favoriteComics
        self.historyItems = historyItems
        self.offlineComics = offlineComics
    }

    func comic(for binding: TrackerBinding) -> ComicSummary? {
        let key = Self.key(sourceKey: binding.sourceKey, comicID: binding.comicID)
        if let favorite = favoriteComics[key] {
            return favorite
        }
        if let history = historyItems[key] {
            return ComicSummary(
                id: history.comicID,
                sourceKey: history.sourceKey,
                title: history.title,
                coverURL: history.coverURL,
                author: history.author,
                tags: history.tags
            )
        }
        return offlineComics[key]
    }

    func history(for binding: TrackerBinding) -> ReadingHistoryItem? {
        historyItems[Self.key(sourceKey: binding.sourceKey, comicID: binding.comicID)]
    }

    private static func key(sourceKey: String, comicID: String) -> String {
        "\(sourceKey)::\(comicID)"
    }
}
