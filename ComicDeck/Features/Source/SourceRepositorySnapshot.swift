import Foundation

struct SourceRepositoryRowSnapshot: Identifiable {
    let id: String
    let item: SourceConfigIndexItem
    let key: String
    let installedSource: InstalledSource?
    let hasUpdate: Bool
    let isOperating: Bool
}

struct SourceRepositorySnapshot {
    static let displayLimit = 120

    let rows: [SourceRepositoryRowSnapshot]
    let visibleRows: [SourceRepositoryRowSnapshot]
    let hiddenRowCount: Int

    var totalRowCount: Int { rows.count }
    var hasHiddenRows: Bool { hiddenRowCount > 0 }

    init(
        remoteSources: [SourceConfigIndexItem],
        installedSources: [InstalledSource],
        availableUpdates: [String: String],
        normalizedQuery: String,
        showInstalledOnly: Bool,
        resolvedKey: (SourceConfigIndexItem) -> String,
        isOperating: (String) -> Bool
    ) {
        let installedByKey = installedSources.reduce(into: [String: InstalledSource]()) { partialResult, source in
            partialResult[source.key] = source
        }

        var rows: [SourceRepositoryRowSnapshot] = []
        rows.reserveCapacity(remoteSources.count)
        for item in remoteSources {
            let key = resolvedKey(item)
            let installedSource = installedByKey[key]
            guard !showInstalledOnly || installedSource != nil else { continue }
            guard Self.matches(item.name, normalizedQuery: normalizedQuery)
                || Self.matches(key, normalizedQuery: normalizedQuery)
                || Self.matches(item.description ?? "", normalizedQuery: normalizedQuery)
            else {
                continue
            }

            rows.append(SourceRepositoryRowSnapshot(
                id: "\(key)|\(item.id)",
                item: item,
                key: key,
                installedSource: installedSource,
                hasUpdate: availableUpdates[key] != nil,
                isOperating: isOperating(key)
            ))
        }

        self.rows = rows
        self.visibleRows = Array(rows.prefix(Self.displayLimit))
        self.hiddenRowCount = max(0, rows.count - Self.displayLimit)
    }

    private static func matches(_ candidate: String, normalizedQuery keyword: String) -> Bool {
        guard !keyword.isEmpty else { return true }
        return candidate.lowercased().contains(keyword)
    }
}
