import Foundation
import Observation

@MainActor
@Observable
final class ExploreScreenModel {
    var pages: [ExplorePageItem] = []
    var selectedPageID: String?
    var isLoading = false
    var didInitialLoad = false
    var status = "Ready"

    var comics: [ComicSummary] = []
    var parts: [ExplorePartData] = []
    var mixedBlocks: [ExploreMixedBlock] = []
    var page = 1
    var maxPage: Int?
    var nextToken: String?
    var hasMore = false

    func reset() {
        pages = []
        selectedPageID = nil
        comics = []
        parts = []
        mixedBlocks = []
        page = 1
        maxPage = nil
        nextToken = nil
        hasMore = false
    }

    func reloadExplorePages(using vm: ReaderViewModel) async {
        reset()
        guard let source = vm.sourceManager.selectedSource else { return }
        do {
            let loaded = try await vm.loadExplorePages(sourceKey: source.key)
            pages = loaded
            selectedPageID = loaded.first?.id
            if loaded.isEmpty {
                status = "This source does not provide explore pages"
                return
            }
            await loadSelectedPage(using: vm, reset: true)
        } catch {
            status = "Explore init failed: \(error.localizedDescription)"
        }
    }

    func loadSelectedPage(using vm: ReaderViewModel, reset shouldReset: Bool) async {
        guard !isLoading else { return }
        guard let source = vm.sourceManager.selectedSource else { return }
        guard let selected = pages.first(where: { $0.id == selectedPageID }),
              let pageIndex = Int(selected.id) else { return }
        if shouldReset {
            comics = []
            parts = []
            mixedBlocks = []
            page = 1
            maxPage = nil
            nextToken = nil
            hasMore = false
        }

        isLoading = true
        defer { isLoading = false }
        do {
            switch selected.kind {
            case .multiPageComicList:
                let loaded = try await vm.loadExploreComicsPage(
                    sourceKey: source.key,
                    pageIndex: pageIndex,
                    page: page,
                    nextToken: page > 1 ? nextToken : nil
                )
                comics.append(contentsOf: loaded.comics)
                maxPage = loaded.maxPage
                nextToken = loaded.nextToken
                if let maxPage {
                    hasMore = page < maxPage
                } else {
                    hasMore = loaded.nextToken != nil
                }
            case .singlePageWithMultiPart:
                parts = try await vm.loadExploreMultiPart(sourceKey: source.key, pageIndex: pageIndex)
                hasMore = false
            case .mixed:
                let loaded = try await vm.loadExploreMixed(sourceKey: source.key, pageIndex: pageIndex, page: page)
                mixedBlocks.append(contentsOf: loaded.blocks)
                maxPage = loaded.maxPage
                hasMore = loaded.maxPage.map { page < $0 } ?? false
            }
            status = "Explore loaded: \(selected.title)"
        } catch {
            status = "Explore load failed: \(error.localizedDescription)"
        }
    }

    func loadMore(using vm: ReaderViewModel) async {
        guard !isLoading else { return }
        page += 1
        await loadSelectedPage(using: vm, reset: false)
    }
}
