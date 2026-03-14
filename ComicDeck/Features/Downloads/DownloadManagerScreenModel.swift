import Foundation
import Observation

enum DownloadWorkspace: String, CaseIterable, Identifiable {
    case queue
    case offline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue: return "Queue"
        case .offline: return "Offline"
        }
    }
}

struct DownloadComicGroup: Identifiable, Hashable {
    let sourceKey: String
    let comicID: String
    let comicTitle: String
    let coverURL: String?
    let comicDescription: String?
    let chapters: [DownloadChapterItem]

    var id: String { "\(sourceKey)::\(comicID)" }

    var updatedAt: Int64 {
        chapters.map(\.updatedAt).max() ?? 0
    }

    var pendingCount: Int {
        chapters.lazy.filter { $0.status == .pending }.count
    }

    var downloadingCount: Int {
        chapters.lazy.filter { $0.status == .downloading }.count
    }

    var failedCount: Int {
        chapters.lazy.filter { $0.status == .failed }.count
    }

    var statusSummary: String {
        var segments: [String] = []
        if downloadingCount > 0 { segments.append("\(downloadingCount) downloading") }
        if pendingCount > 0 { segments.append("\(pendingCount) queued") }
        if failedCount > 0 { segments.append("\(failedCount) failed") }
        return segments.isEmpty ? "No active chapters" : segments.joined(separator: " · ")
    }
}

struct OfflineComicGroup: Identifiable, Hashable {
    let sourceKey: String
    let comicID: String
    let comicTitle: String
    let coverURL: String?
    let comicDescription: String?
    let chapters: [OfflineChapterAsset]

    var id: String { "\(sourceKey)::\(comicID)" }

    var updatedAt: Int64 {
        chapters.map(\.updatedAt).max() ?? 0
    }

    var completeCount: Int {
        chapters.lazy.filter { $0.integrityStatus == .complete }.count
    }

    var incompleteCount: Int {
        chapters.lazy.filter { $0.integrityStatus == .incomplete }.count
    }

    var statusSummary: String {
        var segments = ["\(chapters.count) chapters"]
        if completeCount > 0 {
            segments.append("\(completeCount) complete")
        }
        if incompleteCount > 0 {
            segments.append("\(incompleteCount) incomplete")
        }
        return segments.joined(separator: " · ")
    }
}

@MainActor
@Observable
final class DownloadManagerScreenModel {
    var workspace: DownloadWorkspace = .offline

    var queueItems: [DownloadChapterItem] = []
    var queueGroups: [DownloadComicGroup] = []
    var expandedQueueGroupIDs: Set<String> = []

    var offlineItems: [OfflineChapterAsset] = []
    var offlineGroups: [OfflineComicGroup] = []
    var expandedOfflineGroupIDs: Set<String> = []

    var selectedQueueIDs: Set<Int64> = []
    var selectedOfflineIDs: Set<Int64> = []
    var isSelecting = false
    var isRefreshing = false
    var isDeletingSelection = false
    var isExportingSelection = false
    var showClearConfirm = false
    var showDeleteSelectionConfirm = false

    func applyQueueUpdate(_ item: DownloadChapterItem?) {
        guard let item else { return }

        queueItems.removeAll {
            $0.sourceKey == item.sourceKey &&
            $0.comicID == item.comicID &&
            $0.chapterID == item.chapterID
        }

        if item.status != .completed {
            queueItems.insert(item, at: 0)
        }

        queueItems.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id > rhs.id
        }

        queueGroups = Self.makeQueueGroups(from: queueItems)
        let validQueueGroupIDs = Set(queueGroups.map(\.id))
        expandedQueueGroupIDs = expandedQueueGroupIDs.intersection(validQueueGroupIDs)
        if expandedQueueGroupIDs.isEmpty {
            expandedQueueGroupIDs = validQueueGroupIDs
        }
        selectedQueueIDs = selectedQueueIDs.intersection(Set(queueItems.map(\.id)))
        if selectedCount == 0 {
            isSelecting = false
        }
    }

    func replaceRuntimeQueueItems(_ runtimeItems: [DownloadChapterItem], persistedFallback: [DownloadChapterItem]) {
        let fallbackItems = persistedFallback.filter { item in
            item.status == .failed || item.status == .pending
        }

        var mergedByKey: [String: DownloadChapterItem] = [:]
        for item in fallbackItems {
            mergedByKey[item.queueIdentity] = item
        }
        for item in runtimeItems {
            mergedByKey[item.queueIdentity] = item
        }

        let nextQueueItems = mergedByKey.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id > rhs.id
        }

        guard nextQueueItems != queueItems else { return }
        queueItems = nextQueueItems
        let nextQueueGroups = Self.makeQueueGroups(from: nextQueueItems)
        queueGroups = nextQueueGroups
        let validQueueGroupIDs = Set(nextQueueGroups.map(\.id))
        expandedQueueGroupIDs = expandedQueueGroupIDs.intersection(validQueueGroupIDs)
        if expandedQueueGroupIDs.isEmpty {
            expandedQueueGroupIDs = validQueueGroupIDs
        }
        selectedQueueIDs = selectedQueueIDs.intersection(Set(nextQueueItems.map(\.id)))
        if selectedCount == 0 {
            isSelecting = false
        }
    }

    func sync(from library: LibraryViewModel) {
        let nextQueueItems = library.downloadChapters.filter { $0.status != .completed }
        if nextQueueItems != queueItems {
            queueItems = nextQueueItems
            let nextQueueGroups = Self.makeQueueGroups(from: nextQueueItems)
            queueGroups = nextQueueGroups
            let validQueueGroupIDs = Set(nextQueueGroups.map(\.id))
            expandedQueueGroupIDs = expandedQueueGroupIDs.intersection(validQueueGroupIDs)
            if expandedQueueGroupIDs.isEmpty {
                expandedQueueGroupIDs = validQueueGroupIDs
            }
            selectedQueueIDs = selectedQueueIDs.intersection(Set(nextQueueItems.map(\.id)))
        }

        let nextOfflineItems = library.offlineChapters
        if nextOfflineItems != offlineItems {
            offlineItems = nextOfflineItems
            let nextOfflineGroups = Self.makeOfflineGroups(from: nextOfflineItems)
            offlineGroups = nextOfflineGroups
            let validOfflineGroupIDs = Set(nextOfflineGroups.map(\.id))
            expandedOfflineGroupIDs = expandedOfflineGroupIDs.intersection(validOfflineGroupIDs)
            if expandedOfflineGroupIDs.isEmpty {
                expandedOfflineGroupIDs = validOfflineGroupIDs
            }
            selectedOfflineIDs = selectedOfflineIDs.intersection(Set(nextOfflineItems.map(\.id)))
        }

        if selectedCount == 0 {
            isSelecting = false
        }
    }

    func refresh(using library: LibraryViewModel) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await library.refreshDownloadList()
        sync(from: library)
    }

    func reindex(using library: LibraryViewModel) async {
        isRefreshing = true
        defer { isRefreshing = false }
        await library.reindexOfflineLibrary()
        sync(from: library)
    }

    func clearCurrentWorkspace(using library: LibraryViewModel) async {
        switch workspace {
        case .queue:
            await library.clearAllDownloads()
        case .offline:
            await library.clearOfflineLibrary()
        }
        sync(from: library)
        showClearConfirm = false
    }

    func deleteSelected(using library: LibraryViewModel) async {
        guard selectedCount > 0 else { return }
        isDeletingSelection = true
        defer {
            isDeletingSelection = false
            showDeleteSelectionConfirm = false
            clearSelection()
        }

        switch workspace {
        case .queue:
            let targets = queueItems.filter { selectedQueueIDs.contains($0.id) }
            await library.deleteDownloads(targets)
        case .offline:
            let targets = offlineItems.filter { selectedOfflineIDs.contains($0.id) }
            await library.deleteOfflineChapters(targets)
        }

        sync(from: library)
    }

    func delete(_ item: DownloadChapterItem, using library: LibraryViewModel) async {
        await library.deleteDownload(item)
        sync(from: library)
    }

    func delete(_ item: OfflineChapterAsset, using library: LibraryViewModel) async {
        await library.deleteOfflineChapters([item])
        sync(from: library)
    }

    func selectedOfflineItems() -> [OfflineChapterAsset] {
        offlineItems.filter { selectedOfflineIDs.contains($0.id) }
    }

    func toggleSelectionMode() {
        if isSelecting {
            clearSelection()
        } else {
            isSelecting = true
        }
    }

    func clearSelection() {
        selectedQueueIDs.removeAll()
        selectedOfflineIDs.removeAll()
        isSelecting = false
    }

    func selectAll() {
        isSelecting = true
        switch workspace {
        case .queue:
            selectedQueueIDs = Set(queueItems.map(\.id))
        case .offline:
            selectedOfflineIDs = Set(offlineItems.map(\.id))
        }
    }

    func toggleExpanded(_ group: DownloadComicGroup) {
        if expandedQueueGroupIDs.contains(group.id) {
            expandedQueueGroupIDs.remove(group.id)
        } else {
            expandedQueueGroupIDs.insert(group.id)
        }
    }

    func isExpanded(_ group: DownloadComicGroup) -> Bool {
        expandedQueueGroupIDs.contains(group.id)
    }

    func toggleExpanded(_ group: OfflineComicGroup) {
        if expandedOfflineGroupIDs.contains(group.id) {
            expandedOfflineGroupIDs.remove(group.id)
        } else {
            expandedOfflineGroupIDs.insert(group.id)
        }
    }

    func isExpanded(_ group: OfflineComicGroup) -> Bool {
        expandedOfflineGroupIDs.contains(group.id)
    }

    func toggleSelection(for item: DownloadChapterItem) {
        if selectedQueueIDs.contains(item.id) {
            selectedQueueIDs.remove(item.id)
        } else {
            selectedQueueIDs.insert(item.id)
        }
    }

    func toggleSelection(for item: OfflineChapterAsset) {
        if selectedOfflineIDs.contains(item.id) {
            selectedOfflineIDs.remove(item.id)
        } else {
            selectedOfflineIDs.insert(item.id)
        }
    }

    func toggleGroupSelection(_ group: DownloadComicGroup) {
        let ids = Set(group.chapters.map(\.id))
        if ids.isSubset(of: selectedQueueIDs) {
            selectedQueueIDs.subtract(ids)
        } else {
            selectedQueueIDs.formUnion(ids)
        }
    }

    func toggleGroupSelection(_ group: OfflineComicGroup) {
        let ids = Set(group.chapters.map(\.id))
        if ids.isSubset(of: selectedOfflineIDs) {
            selectedOfflineIDs.subtract(ids)
        } else {
            selectedOfflineIDs.formUnion(ids)
        }
    }

    func isSelected(_ item: DownloadChapterItem) -> Bool {
        selectedQueueIDs.contains(item.id)
    }

    func isSelected(_ item: OfflineChapterAsset) -> Bool {
        selectedOfflineIDs.contains(item.id)
    }

    func isGroupFullySelected(_ group: DownloadComicGroup) -> Bool {
        let ids = Set(group.chapters.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: selectedQueueIDs)
    }

    func isGroupFullySelected(_ group: OfflineComicGroup) -> Bool {
        let ids = Set(group.chapters.map(\.id))
        return !ids.isEmpty && ids.isSubset(of: selectedOfflineIDs)
    }

    func isGroupPartiallySelected(_ group: DownloadComicGroup) -> Bool {
        let ids = Set(group.chapters.map(\.id))
        let selected = ids.intersection(selectedQueueIDs)
        return !selected.isEmpty && selected.count < ids.count
    }

    func isGroupPartiallySelected(_ group: OfflineComicGroup) -> Bool {
        let ids = Set(group.chapters.map(\.id))
        let selected = ids.intersection(selectedOfflineIDs)
        return !selected.isEmpty && selected.count < ids.count
    }

    var selectedCount: Int {
        switch workspace {
        case .queue: selectedQueueIDs.count
        case .offline: selectedOfflineIDs.count
        }
    }

    var currentItemCount: Int {
        switch workspace {
        case .queue: queueItems.count
        case .offline: offlineItems.count
        }
    }

    var currentGroupsCount: Int {
        switch workspace {
        case .queue: queueGroups.count
        case .offline: offlineGroups.count
        }
    }

    var queuePendingCount: Int {
        queueItems.lazy.filter { $0.status == .pending }.count
    }

    var queueDownloadingCount: Int {
        queueItems.lazy.filter { $0.status == .downloading }.count
    }

    var queueFailedCount: Int {
        queueItems.lazy.filter { $0.status == .failed }.count
    }

    var offlineCompleteCount: Int {
        offlineItems.lazy.filter { $0.integrityStatus == .complete }.count
    }

    var offlineIncompleteCount: Int {
        offlineItems.lazy.filter { $0.integrityStatus == .incomplete }.count
    }

    var offlineReadyCount: Int {
        offlineItems.count
    }

    private static func makeQueueGroups(from items: [DownloadChapterItem]) -> [DownloadComicGroup] {
        let grouped = Dictionary(grouping: items) { item in
            "\(item.sourceKey)::\(item.comicID)"
        }

        return grouped.values.compactMap { bucket in
            guard let first = bucket.first else { return nil }
            let chapters = bucket.sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.chapterTitle.localizedCaseInsensitiveCompare(rhs.chapterTitle) == .orderedAscending
            }
            return DownloadComicGroup(
                sourceKey: first.sourceKey,
                comicID: first.comicID,
                comicTitle: first.comicTitle,
                coverURL: first.coverURL,
                comicDescription: bucket.lazy.compactMap(\.comicDescription).first,
                chapters: chapters
            )
        }
        .sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.comicTitle.localizedCaseInsensitiveCompare(rhs.comicTitle) == .orderedAscending
        }
    }

    private static func makeOfflineGroups(from items: [OfflineChapterAsset]) -> [OfflineComicGroup] {
        let grouped = Dictionary(grouping: items) { item in
            "\(item.sourceKey)::\(item.comicID)"
        }

        return grouped.values.compactMap { bucket in
            guard let first = bucket.first else { return nil }
            let chapters = bucket.sorted { lhs, rhs in
                if lhs.integrityStatus != rhs.integrityStatus {
                    return lhs.integrityStatus == .incomplete
                }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                if lhs.downloadedAt != rhs.downloadedAt { return lhs.downloadedAt > rhs.downloadedAt }
                return lhs.chapterTitle.localizedCaseInsensitiveCompare(rhs.chapterTitle) == .orderedAscending
            }
            return OfflineComicGroup(
                sourceKey: first.sourceKey,
                comicID: first.comicID,
                comicTitle: first.comicTitle,
                coverURL: first.coverURL,
                comicDescription: bucket.lazy.compactMap(\.comicDescription).first,
                chapters: chapters
            )
        }
        .sorted { lhs, rhs in
            if lhs.incompleteCount != rhs.incompleteCount { return lhs.incompleteCount > rhs.incompleteCount }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.comicTitle.localizedCaseInsensitiveCompare(rhs.comicTitle) == .orderedAscending
        }
    }
}

private extension DownloadChapterItem {
    var queueIdentity: String {
        "\(sourceKey)::\(comicID)::\(chapterID)"
    }
}
