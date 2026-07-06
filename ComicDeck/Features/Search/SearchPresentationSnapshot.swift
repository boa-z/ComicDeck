import Foundation

struct SearchQuickFilterGroup: Identifiable, Hashable {
    let index: Int
    let group: SearchOptionGroup

    var id: String { group.id }
}

struct SearchPresentationSnapshot: Hashable {
    let results: [ComicSummary]
    let resultIDs: [ComicSummary.ID]
    let quickFilterGroups: [SearchQuickFilterGroup]
    private let resultByID: [ComicSummary.ID: ComicSummary]

    init(results: [ComicSummary], optionGroups: [SearchOptionGroup]) {
        self.results = results
        self.resultIDs = results.map(\.id)
        var resultByID: [ComicSummary.ID: ComicSummary] = [:]
        resultByID.reserveCapacity(results.count)
        for result in results {
            resultByID[result.id] = result
        }
        self.resultByID = resultByID
        self.quickFilterGroups = optionGroups.indices.compactMap { index in
            let group = optionGroups[index]
            guard group.type != "multi-select", !group.options.isEmpty else {
                return nil
            }
            return SearchQuickFilterGroup(index: index, group: group)
        }
    }

    func result(matching id: ComicSummary.ID?) -> ComicSummary? {
        guard let id else { return nil }
        return resultByID[id]
    }
}
