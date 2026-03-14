import Foundation
import Observation

@MainActor
@Observable
final class FavoritesScreenModel {
    var selectedSourceKey = ""
    var refreshing = false
    var sourceFavorites: [ComicSummary] = []
    var sourceFolders: [FavoriteFolder] = []
    var selectedFolderID: String?
    var currentPage = 1
    var sourceError = ""
    var cachedFoldersBySource: [String: [FavoriteFolder]] = [:]
    var cachedFavoritesByScope: [String: [ComicSummary]] = [:]
    var cachedNextTokenByPage: [String: String] = [:]
    var cursorModeByScope: [String: Bool] = [:]
    var showPagePicker = false
    var pageInput = ""
    var refreshTask: Task<Void, Never>?
    var refreshGeneration = 0
    var isSelecting = false
    var selectedComicKeys: Set<String> = []
    var batchWorking = false
    var batchProgressText = ""
    var showBatchRemoveConfirm = false

    var hasFolders: Bool { !sourceFolders.isEmpty }
    var selectedCount: Int { selectedComicKeys.count }

    func selectionKey(for item: ComicSummary) -> String {
        "\(item.sourceKey)::\(item.id)"
    }

    func isSelected(_ item: ComicSummary) -> Bool {
        selectedComicKeys.contains(selectionKey(for: item))
    }

    func toggleSelection(_ item: ComicSummary) {
        let key = selectionKey(for: item)
        if selectedComicKeys.contains(key) {
            selectedComicKeys.remove(key)
        } else {
            selectedComicKeys.insert(key)
        }
    }

    func select(_ item: ComicSummary) {
        selectedComicKeys.insert(selectionKey(for: item))
    }

    func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        if !selecting {
            selectedComicKeys.removeAll()
        }
    }

    func toggleSelecting() {
        setSelecting(!isSelecting)
    }

    func selectAllVisible() {
        selectedComicKeys = Set(sourceFavorites.map(selectionKey(for:)))
    }

    func clearSelection() {
        selectedComicKeys.removeAll()
    }

    private func removeFromVisibleFavorites(_ item: ComicSummary) {
        sourceFavorites.removeAll { $0.id == item.id && $0.sourceKey == item.sourceKey }
        let scopeKey = cacheScopeKey(sourceKey: selectedSourceKey, folderID: selectedFolderID, page: currentPage)
        if var cached = cachedFavoritesByScope[scopeKey] {
            cached.removeAll { $0.id == item.id && $0.sourceKey == item.sourceKey }
            cachedFavoritesByScope[scopeKey] = cached
        }
    }

    func cacheScopeKey(sourceKey: String, folderID: String?, page: Int) -> String {
        "\(sourceKey)|\(folderID ?? "__default__")|p=\(page)"
    }

    func cursorScopeKey(sourceKey: String, folderID: String?) -> String {
        "\(sourceKey)|\(folderID ?? "__default__")"
    }

    func nextTokenCacheKey(sourceKey: String, folderID: String?, page: Int) -> String {
        "\(cursorScopeKey(sourceKey: sourceKey, folderID: folderID))|next:p=\(page)"
    }

    func openPagePicker() {
        pageInput = String(currentPage)
        showPagePicker = true
    }

    func requestRefresh(
        vm: ReaderViewModel,
        forceNetwork: Bool = false
    ) {
        refreshTask?.cancel()
        refreshTask = Task {
            await refreshNow(vm: vm, forceNetwork: forceNetwork)
            if !Task.isCancelled {
                refreshTask = nil
            }
        }
    }

    func jumpToPage(_ targetPage: Int, vm: ReaderViewModel) async {
        guard targetPage > 0 else { return }
        let scopeKey = cursorScopeKey(sourceKey: selectedSourceKey, folderID: selectedFolderID)
        if cursorModeByScope[scopeKey] == true && targetPage > 1 {
            let targetCacheKey = cacheScopeKey(sourceKey: selectedSourceKey, folderID: selectedFolderID, page: targetPage)
            if cachedFavoritesByScope[targetCacheKey] == nil {
                sourceError = "This source uses cursor pagination. Please load pages sequentially."
                return
            }
        }
        let previousPage = currentPage
        let previousFavorites = sourceFavorites
        currentPage = targetPage
        await refreshNow(vm: vm)
        if sourceFavorites.isEmpty, sourceError.isEmpty {
            currentPage = previousPage
            sourceFavorites = previousFavorites
            sourceError = "No more favorites pages"
        }
    }

    func refreshNow(vm: ReaderViewModel, forceNetwork: Bool = false) async {
        guard !selectedSourceKey.isEmpty else { return }
        let sourceKey = selectedSourceKey
        let folderID = selectedFolderID
        let page = max(1, currentPage)
        let scopeKey = cacheScopeKey(sourceKey: sourceKey, folderID: folderID, page: page)
        refreshGeneration += 1
        let generation = refreshGeneration

        if !forceNetwork {
            if let cachedFolders = cachedFoldersBySource[sourceKey] {
                sourceFolders = cachedFolders
            }
            if let cachedFavorites = cachedFavoritesByScope[scopeKey] {
                sourceFavorites = cachedFavorites
                sourceError = ""
                return
            }
        }

        refreshing = true
        defer {
            if refreshGeneration == generation {
                refreshing = false
            }
        }

        do {
            sourceError = ""
            let folders = try await vm.loadSourceFavoriteFolders(sourceKey: sourceKey)
            guard !Task.isCancelled, refreshGeneration == generation else { return }

            var effectiveFolderID = folderID
            if let selected = effectiveFolderID, !folders.contains(where: { $0.id == selected }) {
                effectiveFolderID = nil
            }

            let effectiveCursorScope = cursorScopeKey(sourceKey: sourceKey, folderID: effectiveFolderID)
            let previousPageToken: String? = {
                guard page > 1 else { return nil }
                return cachedNextTokenByPage[nextTokenCacheKey(sourceKey: sourceKey, folderID: effectiveFolderID, page: page - 1)]
            }()
            let cursorMode = cursorModeByScope[effectiveCursorScope] == true
            if cursorMode && page > 1 && previousPageToken == nil {
                sourceFavorites = []
                sourceError = "This source uses cursor pagination. Please load pages sequentially."
                return
            }

            let pageResult = try await vm.loadSourceFavoriteComicsPage(
                sourceKey: sourceKey,
                page: page,
                folderID: effectiveFolderID,
                nextToken: previousPageToken
            )
            guard !Task.isCancelled, refreshGeneration == generation else { return }

            sourceFolders = folders
            cachedFoldersBySource[sourceKey] = folders
            if effectiveFolderID != selectedFolderID {
                selectedFolderID = effectiveFolderID
                if folderID != nil && effectiveFolderID == nil {
                    currentPage = 1
                }
            }
            sourceFavorites = pageResult.comics
            let updatedScopeKey = cacheScopeKey(sourceKey: sourceKey, folderID: effectiveFolderID, page: page)
            cachedFavoritesByScope[updatedScopeKey] = pageResult.comics
            if let next = pageResult.nextToken, !next.isEmpty {
                cachedNextTokenByPage[nextTokenCacheKey(sourceKey: sourceKey, folderID: effectiveFolderID, page: page)] = next
            }
            let detectedCursorMode = (pageResult.maxPage == nil) && (pageResult.nextToken != nil || page > 1)
            if detectedCursorMode {
                cursorModeByScope[effectiveCursorScope] = true
            } else if page == 1 {
                cursorModeByScope[effectiveCursorScope] = false
            }
        } catch {
            guard !Task.isCancelled, refreshGeneration == generation else { return }
            sourceFavorites = []
            sourceError = "Load source favorites failed: \(error.localizedDescription)"
        }
    }

    func removeSelected(using vm: ReaderViewModel) async {
        guard !batchWorking else { return }
        let selectedItems = sourceFavorites.filter(isSelected)
        guard !selectedItems.isEmpty else { return }

        batchWorking = true
        batchProgressText = "Preparing..."
        defer {
            batchWorking = false
            batchProgressText = ""
        }

        var failures = 0
        let total = selectedItems.count
        for (index, item) in selectedItems.enumerated() {
            batchProgressText = "\(index + 1) / \(total)"
            do {
                try await vm.setSourceFavorite(
                    item,
                    favoriteId: nil,
                    folderID: selectedFolderID,
                    isAdding: false
                )
                removeFromVisibleFavorites(item)
            } catch {
                failures += 1
            }
        }

        clearSelection()
        setSelecting(false)
        requestRefresh(vm: vm, forceNetwork: true)
        if failures > 0 {
            sourceError = "Removed with \(failures) failures"
        }
    }
}
