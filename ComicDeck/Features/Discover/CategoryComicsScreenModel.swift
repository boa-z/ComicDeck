import Foundation
import Observation

@MainActor
@Observable
final class CategoryComicsScreenModel {
    let sourceKey: String
    let item: CategoryItemData

    var isLoading = false
    var didInitialLoad = false
    var optionGroups: [CategoryComicsOptionGroup] = []
    var optionValues: [String] = []
    var results: [ComicSummary] = []
    var page = 1
    var hasMore = false
    var nextToken: String?
    var status = "Ready"

    init(sourceKey: String, item: CategoryItemData) {
        self.sourceKey = sourceKey
        self.item = item
    }

    var categoryName: String { item.target.category ?? item.label }

    func prepareAndLoadInitial(using vm: ReaderViewModel) async {
        do {
            let rawGroups = try await vm.loadCategoryComicsOptionGroups(
                sourceKey: sourceKey,
                category: categoryName,
                param: item.target.param
            )
            let groups = rawGroups.filter { group in
                if group.notShowWhen.contains(categoryName) { return false }
                if let showWhen = group.showWhen { return showWhen.contains(categoryName) }
                return true
            }
            optionGroups = groups
            optionValues = groups.map { $0.options.first?.value ?? "" }
        } catch {
            optionGroups = []
            optionValues = []
        }
        await loadCategory(using: vm, page: 1, append: false)
    }

    func loadCategory(using vm: ReaderViewModel, page: Int, append: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await vm.loadCategoryComics(
                sourceKey: sourceKey,
                category: categoryName,
                param: item.target.param,
                options: optionValues,
                page: max(1, page),
                nextToken: append ? nextToken : nil
            )
            if append {
                results.append(contentsOf: loaded.comics)
            } else {
                results = loaded.comics
            }
            self.page = max(1, page)
            nextToken = loaded.nextToken
            if let maxPage = loaded.maxPage {
                hasMore = self.page < maxPage
            } else {
                hasMore = loaded.nextToken != nil || !loaded.comics.isEmpty
            }
            if !append, self.page == 1, loaded.comics.isEmpty {
                let didRetry = await retryIfNeededForCopyMangaEmptyResult(using: vm)
                if didRetry { return }
            }
            status = "Loaded \(loaded.comics.count) items (page \(self.page))"
        } catch {
            status = "Category load failed: \(error.localizedDescription)"
        }
    }

    private func retryIfNeededForCopyMangaEmptyResult(using vm: ReaderViewModel) async -> Bool {
        guard sourceKey == "copy_manga" else { return false }
        guard let firstEmptyIndex = optionValues.firstIndex(of: "") else { return false }
        guard optionGroups.indices.contains(firstEmptyIndex) else { return false }
        let fallback = optionGroups[firstEmptyIndex].options.first(where: { !$0.value.isEmpty })?.value
        guard let fallback, !fallback.isEmpty else { return false }
        optionValues[firstEmptyIndex] = fallback

        do {
            let loaded = try await vm.loadCategoryComics(
                sourceKey: sourceKey,
                category: categoryName,
                param: item.target.param,
                options: optionValues,
                page: 1,
                nextToken: nil
            )
            results = loaded.comics
            page = 1
            nextToken = loaded.nextToken
            if let maxPage = loaded.maxPage {
                hasMore = page < maxPage
            } else {
                hasMore = loaded.nextToken != nil || !loaded.comics.isEmpty
            }
            status = "Loaded \(loaded.comics.count) items (page 1)"
            return true
        } catch {
            status = "Category load failed: \(error.localizedDescription)"
            return false
        }
    }
}
