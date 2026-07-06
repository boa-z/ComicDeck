import Foundation
import Observation
import SwiftUI

enum DownloadWorkspace: String, CaseIterable, Identifiable {
    case queue
    case offline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .queue:
            return AppLocalization.text("downloads.workspace.queue", "Queue")
        case .offline:
            return AppLocalization.text("downloads.workspace.offline", "Offline")
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
    let chapterIDs: Set<Int64>
    let updatedAt: Int64
    let pendingCount: Int
    let downloadingCount: Int
    let failedCount: Int

    var id: String { "\(sourceKey)::\(comicID)" }

    var statusSummary: String {
        var segments: [String] = []
        if downloadingCount > 0 {
            segments.append(AppLocalization.format("downloads.metric.downloading_count", "%lld downloading", Int64(downloadingCount)))
        }
        if pendingCount > 0 {
            segments.append(AppLocalization.format("downloads.metric.queued_count", "%lld queued", Int64(pendingCount)))
        }
        if failedCount > 0 {
            segments.append(AppLocalization.format("downloads.metric.failed_count", "%lld failed", Int64(failedCount)))
        }
        return segments.isEmpty ? AppLocalization.text("downloads.queue.no_active_chapters", "No active chapters") : segments.joined(separator: " · ")
    }
}

struct OfflineComicGroup: Identifiable, Hashable {
    let sourceKey: String
    let comicID: String
    let comicTitle: String
    let coverURL: String?
    let localCoverFileURL: URL?
    let comicDescription: String?
    let chapters: [OfflineChapterAsset]
    let readableChapters: [OfflineChapterAsset]
    let incompleteChapters: [OfflineChapterAsset]
    let readerChapterSequence: [ComicChapter]
    let chapterIDs: Set<Int64>
    let updatedAt: Int64
    let completeCount: Int
    let incompleteCount: Int
    let isImportedGroup: Bool

    var id: String { "\(sourceKey)::\(comicID)" }

    var statusSummary: String {
        var segments = [AppLocalization.format("downloads.metric.chapters_count", "%lld chapters", Int64(chapters.count))]
        if completeCount > 0 {
            segments.append(AppLocalization.format("downloads.metric.complete_count", "%lld complete", Int64(completeCount)))
        }
        if incompleteCount > 0 {
            segments.append(AppLocalization.format("downloads.metric.incomplete_count", "%lld incomplete", Int64(incompleteCount)))
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
    var queuePendingCount = 0
    var queueDownloadingCount = 0
    var queueFailedCount = 0

    var offlineItems: [OfflineChapterAsset] = []
    var offlineGroups: [OfflineComicGroup] = []
    var expandedOfflineGroupIDs: Set<String> = []
    var offlineCompleteCount = 0
    var offlineIncompleteCount = 0

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

        refreshQueueCounts()
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
        refreshQueueCounts()
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
            refreshQueueCounts()
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
            refreshOfflineCounts()
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
        if group.chapterIDs.isSubset(of: selectedQueueIDs) {
            selectedQueueIDs.subtract(group.chapterIDs)
        } else {
            selectedQueueIDs.formUnion(group.chapterIDs)
        }
    }

    func toggleGroupSelection(_ group: OfflineComicGroup) {
        if group.chapterIDs.isSubset(of: selectedOfflineIDs) {
            selectedOfflineIDs.subtract(group.chapterIDs)
        } else {
            selectedOfflineIDs.formUnion(group.chapterIDs)
        }
    }

    func isSelected(_ item: DownloadChapterItem) -> Bool {
        selectedQueueIDs.contains(item.id)
    }

    func isSelected(_ item: OfflineChapterAsset) -> Bool {
        selectedOfflineIDs.contains(item.id)
    }

    func isGroupFullySelected(_ group: DownloadComicGroup) -> Bool {
        !group.chapterIDs.isEmpty && group.chapterIDs.isSubset(of: selectedQueueIDs)
    }

    func isGroupFullySelected(_ group: OfflineComicGroup) -> Bool {
        !group.chapterIDs.isEmpty && group.chapterIDs.isSubset(of: selectedOfflineIDs)
    }

    func isGroupPartiallySelected(_ group: DownloadComicGroup) -> Bool {
        let selected = group.chapterIDs.intersection(selectedQueueIDs)
        return !selected.isEmpty && selected.count < group.chapterIDs.count
    }

    func isGroupPartiallySelected(_ group: OfflineComicGroup) -> Bool {
        let selected = group.chapterIDs.intersection(selectedOfflineIDs)
        return !selected.isEmpty && selected.count < group.chapterIDs.count
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

    private func refreshQueueCounts() {
        var pending = 0
        var downloading = 0
        var failed = 0
        for item in queueItems {
            switch item.status {
            case .pending:
                pending += 1
            case .downloading:
                downloading += 1
            case .failed:
                failed += 1
            case .completed:
                break
            }
        }
        queuePendingCount = pending
        queueDownloadingCount = downloading
        queueFailedCount = failed
    }

    private func refreshOfflineCounts() {
        var complete = 0
        var incomplete = 0
        for item in offlineItems {
            switch item.integrityStatus {
            case .complete:
                complete += 1
            case .incomplete:
                incomplete += 1
            }
        }
        offlineCompleteCount = complete
        offlineIncompleteCount = incomplete
    }

    private static func makeQueueGroups(from items: [DownloadChapterItem]) -> [DownloadComicGroup] {
        let grouped = Dictionary(grouping: items) { item in
            "\(item.sourceKey)::\(item.comicID)"
        }

        return grouped.values.compactMap { bucket in
            guard let first = bucket.first else { return nil }
            let snapshot = queueGroupSnapshot(for: bucket)
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
                chapters: chapters,
                chapterIDs: snapshot.chapterIDs,
                updatedAt: snapshot.updatedAt,
                pendingCount: snapshot.pendingCount,
                downloadingCount: snapshot.downloadingCount,
                failedCount: snapshot.failedCount
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
            let snapshot = offlineGroupSnapshot(for: bucket)
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
                localCoverFileURL: offlineComicCoverURL(from: bucket),
                comicDescription: bucket.lazy.compactMap(\.comicDescription).first,
                chapters: chapters,
                readableChapters: snapshot.readableChapters,
                incompleteChapters: snapshot.incompleteChapters,
                readerChapterSequence: snapshot.readerChapterSequence,
                chapterIDs: snapshot.chapterIDs,
                updatedAt: snapshot.updatedAt,
                completeCount: snapshot.completeCount,
                incompleteCount: snapshot.incompleteCount,
                isImportedGroup: snapshot.isImportedGroup
            )
        }
        .sorted { lhs, rhs in
            if lhs.incompleteCount != rhs.incompleteCount { return lhs.incompleteCount > rhs.incompleteCount }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.comicTitle.localizedCaseInsensitiveCompare(rhs.comicTitle) == .orderedAscending
        }
    }

    private static func queueGroupSnapshot(
        for bucket: [DownloadChapterItem]
    ) -> (chapterIDs: Set<Int64>, updatedAt: Int64, pendingCount: Int, downloadingCount: Int, failedCount: Int) {
        var chapterIDs = Set<Int64>()
        chapterIDs.reserveCapacity(bucket.count)
        var updatedAt: Int64 = 0
        var pendingCount = 0
        var downloadingCount = 0
        var failedCount = 0

        for item in bucket {
            chapterIDs.insert(item.id)
            updatedAt = max(updatedAt, item.updatedAt)
            switch item.status {
            case .pending:
                pendingCount += 1
            case .downloading:
                downloadingCount += 1
            case .failed:
                failedCount += 1
            case .completed:
                break
            }
        }

        return (chapterIDs, updatedAt, pendingCount, downloadingCount, failedCount)
    }

    private static func offlineGroupSnapshot(
        for bucket: [OfflineChapterAsset]
    ) -> (
        chapterIDs: Set<Int64>,
        updatedAt: Int64,
        completeCount: Int,
        incompleteCount: Int,
        readableChapters: [OfflineChapterAsset],
        incompleteChapters: [OfflineChapterAsset],
        readerChapterSequence: [ComicChapter],
        isImportedGroup: Bool
    ) {
        var chapterIDs = Set<Int64>()
        chapterIDs.reserveCapacity(bucket.count)
        var updatedAt: Int64 = 0
        var completeCount = 0
        var incompleteCount = 0
        var readableChapters: [OfflineChapterAsset] = []
        var incompleteChapters: [OfflineChapterAsset] = []
        var isImportedGroup = !bucket.isEmpty

        for item in bucket {
            chapterIDs.insert(item.id)
            updatedAt = max(updatedAt, item.updatedAt)
            isImportedGroup = isImportedGroup && item.sourceKey == OfflineImportService.importedSourceKey
            switch item.integrityStatus {
            case .complete:
                completeCount += 1
                readableChapters.append(item)
            case .incomplete:
                incompleteCount += 1
                incompleteChapters.append(item)
            }
        }

        readableChapters.sort { lhs, rhs in
            if lhs.downloadedAt != rhs.downloadedAt { return lhs.downloadedAt < rhs.downloadedAt }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
        }
        incompleteChapters.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
        }
        let readerChapterSequence = readableChapters.map {
            ComicChapter(
                id: $0.chapterID,
                title: $0.chapterTitle.isEmpty ? $0.chapterID : $0.chapterTitle
            )
        }

        return (
            chapterIDs: chapterIDs,
            updatedAt: updatedAt,
            completeCount: completeCount,
            incompleteCount: incompleteCount,
            readableChapters: readableChapters,
            incompleteChapters: incompleteChapters,
            readerChapterSequence: readerChapterSequence,
            isImportedGroup: isImportedGroup
        )
    }
}

private extension DownloadChapterItem {
    var queueIdentity: String {
        "\(sourceKey)::\(comicID)::\(chapterID)"
    }
}

func offlineComicCoverURL(from chapters: [OfflineChapterAsset]) -> URL? {
    guard let anyChapter = chapters.first else { return nil }
    let comicDirectory = URL(fileURLWithPath: anyChapter.directoryPath).deletingLastPathComponent()
    let supported = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif"]
    return supported
        .map { comicDirectory.appendingPathComponent("cover.\($0)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

extension DownloadChapterItem {
    var statusTint: Color {
        switch status {
        case .completed: return .green
        case .downloading: return .blue
        case .failed: return .red
        case .pending: return .secondary
        }
    }

    var statusIcon: String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .pending: return "clock.fill"
        }
    }

    var statusLabel: String {
        status.rawValue.capitalized
    }

    var progressFraction: Double {
        guard totalPages > 0 else { return 0 }
        return min(max(Double(downloadedPages) / Double(totalPages), 0), 1)
    }

    var progressPercentageText: String {
        "\(Int((progressFraction * 100).rounded()))%"
    }
}
