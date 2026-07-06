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
        visibleRows = rows.filter { row in
            row.entry.title.lowercased().contains(keyword)
                || (row.entry.subtitle?.lowercased().contains(keyword) ?? false)
                || row.localGroups.contains { $0.title.lowercased().contains(keyword) }
        }
    }
}
#endif
