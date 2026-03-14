import Foundation
import Observation

@MainActor
@Observable
final class HistoryScreenModel {
    var items: [ReadingHistoryItem] = []
    var showClearConfirm = false
    var isRefreshing = false
    var refreshGeneration = 0
    var isSelecting = false
    var selectedItemIDs: Set<Int64> = []
    var batchWorking = false
    var batchProgressText = ""
    var showBatchDeleteConfirm = false

    var selectedCount: Int { selectedItemIDs.count }

    func sync(from library: LibraryViewModel) {
        refreshGeneration += 1
        items = library.history
    }

    func isSelected(_ item: ReadingHistoryItem) -> Bool {
        selectedItemIDs.contains(item.id)
    }

    func toggleSelection(_ item: ReadingHistoryItem) {
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func select(_ item: ReadingHistoryItem) {
        selectedItemIDs.insert(item.id)
    }

    func setSelecting(_ selecting: Bool) {
        isSelecting = selecting
        if !selecting {
            selectedItemIDs.removeAll()
        }
    }

    func toggleSelecting() {
        setSelecting(!isSelecting)
    }

    func selectAllVisible() {
        selectedItemIDs = Set(items.map(\.id))
    }

    func clearSelection() {
        selectedItemIDs.removeAll()
    }

    func delete(_ item: ReadingHistoryItem, using library: LibraryViewModel) async {
        await library.deleteHistory(item)
        sync(from: library)
    }

    func clear(using library: LibraryViewModel) async {
        await library.clearHistory()
        sync(from: library)
        showClearConfirm = false
    }

    func deleteSelected(using library: LibraryViewModel) async {
        guard !batchWorking else { return }
        let targets = items.filter(isSelected)
        guard !targets.isEmpty else { return }

        batchWorking = true
        batchProgressText = "Preparing..."
        defer {
            batchWorking = false
            batchProgressText = ""
        }

        let total = targets.count
        for (index, item) in targets.enumerated() {
            batchProgressText = "\(index + 1) / \(total)"
            await library.deleteHistory(item)
        }
        sync(from: library)
        clearSelection()
        setSelecting(false)
    }
}
