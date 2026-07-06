#if os(macOS)
import Foundation

struct MacTrackerSubscriptionListSnapshot {
    let visibleRows: [TrackerSubscriptionRow]
    let isFiltering: Bool

    init(rows: [TrackerSubscriptionRow], query: String) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        isFiltering = !keyword.isEmpty
        guard isFiltering else {
            visibleRows = rows
            return
        }
        var filteredRows: [TrackerSubscriptionRow] = []
        filteredRows.reserveCapacity(rows.count)
        for row in rows {
            if row.entry.title.lowercased().contains(keyword)
                || (row.entry.subtitle?.lowercased().contains(keyword) ?? false)
                || row.localGroups.contains(where: { $0.title.lowercased().contains(keyword) }) {
                filteredRows.append(row)
            }
        }
        visibleRows = filteredRows
    }
}
#endif
