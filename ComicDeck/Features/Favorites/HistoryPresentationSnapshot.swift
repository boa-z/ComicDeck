import Foundation

struct HistoryPresentationSnapshot: Hashable {
    let items: [ReadingHistoryItem]
    let itemIDs: [ReadingHistoryItem.ID]
    private let itemByID: [ReadingHistoryItem.ID: ReadingHistoryItem]

    init(items: [ReadingHistoryItem]) {
        self.items = items
        self.itemIDs = items.map(\.id)
        var itemByID: [ReadingHistoryItem.ID: ReadingHistoryItem] = [:]
        itemByID.reserveCapacity(items.count)
        for item in items {
            itemByID[item.id] = item
        }
        self.itemByID = itemByID
    }

    func item(matching id: ReadingHistoryItem.ID?) -> ReadingHistoryItem? {
        guard let id else { return nil }
        return itemByID[id]
    }
}
