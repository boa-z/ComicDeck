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
        let groups = bindingGroups.compactMap { bindings -> TrackerSubscriptionLocalGroupSnapshot? in
            guard let providerBinding = bindings[provider] else { return nil }
            let localComic = localIndex.comic(for: providerBinding)
            let localGroup = TrackerSubscriptionLocalGroup(
                sourceKey: providerBinding.sourceKey,
                comicID: providerBinding.comicID,
                title: localComic?.title ?? providerBinding.sourceTitle ?? providerBinding.remoteTitle,
                coverURL: localComic?.coverURL ?? providerBinding.sourceCoverURL ?? providerBinding.remoteCoverURL,
                bindings: bindings
            )
            let sortedBindings = TrackerProvider.mangaListWorkspaceProviders.compactMap { bindings[$0] }
            return TrackerSubscriptionLocalGroupSnapshot(
                group: localGroup,
                localHistory: localIndex.history(for: providerBinding),
                sortedBindings: sortedBindings
            )
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
        favoriteComics = Dictionary(
            library.favorites.map { favorite in
                (
                    Self.key(sourceKey: favorite.sourceKey, comicID: favorite.id),
                    ComicSummary(
                        id: favorite.id,
                        sourceKey: favorite.sourceKey,
                        title: favorite.title,
                        coverURL: favorite.coverURL
                    )
                )
            },
            uniquingKeysWith: { current, _ in current }
        )
        historyItems = Dictionary(
            library.history.map { history in
                (Self.key(sourceKey: history.sourceKey, comicID: history.comicID), history)
            },
            uniquingKeysWith: { current, _ in current }
        )
        offlineComics = Dictionary(
            library.offlineChapters.map { offline in
                (
                    Self.key(sourceKey: offline.sourceKey, comicID: offline.comicID),
                    ComicSummary(
                        id: offline.comicID,
                        sourceKey: offline.sourceKey,
                        title: offline.comicTitle,
                        coverURL: offline.coverURL
                    )
                )
            },
            uniquingKeysWith: { current, _ in current }
        )
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
