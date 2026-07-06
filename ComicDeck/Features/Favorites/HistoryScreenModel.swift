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

    @ObservationIgnored private var visibleItemIDs: Set<Int64> = []

    var selectedCount: Int { selectedItemIDs.count }

    func sync(from library: LibraryViewModel) {
        refreshGeneration += 1
        applyVisibleItems(library.history)
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
        selectedItemIDs = visibleItemIDs
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
        let targets = selectedVisibleItems()
        guard !targets.isEmpty else { return }

        batchWorking = true
        batchProgressText = AppLocalization.text("source.action.preparing", "Preparing...")
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

    private func reconcileSelectionWithVisibleItems() {
        guard !selectedItemIDs.isEmpty else { return }
        selectedItemIDs.formIntersection(visibleItemIDs)
    }

    private func applyVisibleItems(_ nextItems: [ReadingHistoryItem]) {
        items = nextItems
        visibleItemIDs = Self.itemIDSet(from: nextItems)
        reconcileSelectionWithVisibleItems()
    }

    private func selectedVisibleItems() -> [ReadingHistoryItem] {
        guard !selectedItemIDs.isEmpty else { return [] }
        var output: [ReadingHistoryItem] = []
        output.reserveCapacity(selectedItemIDs.count)
        for item in items where selectedItemIDs.contains(item.id) {
            output.append(item)
        }
        return output
    }

    private static func itemIDSet(from items: [ReadingHistoryItem]) -> Set<Int64> {
        var ids = Set<Int64>()
        ids.reserveCapacity(items.count)
        for item in items {
            ids.insert(item.id)
        }
        return ids
    }
}
