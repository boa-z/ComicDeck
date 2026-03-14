import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor
struct DownloadManagerView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    @State private var model = DownloadManagerScreenModel()
    @State private var sharedExportURL: ShareFile?
    @State private var exportError: String?
    @State private var showingImportPicker = false
    @State private var importMessage: String?
    @State private var importError: String?

    private var archiveImportTypes: [UTType] {
        var types: [UTType] = [.zip]
        if let cbz = UTType(filenameExtension: "cbz") {
            types.append(cbz)
        }
        return types
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.section) {
                controlsCard
                summaryHeader

                if model.currentGroupsCount == 0 {
                    emptyState
                } else {
                    groupsSection
                }
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .background(AppSurface.grouped.ignoresSafeArea())
        .navigationTitle("Downloads")
        .sheet(item: $sharedExportURL) { shareFile in
            ActivityShareSheet(items: [shareFile.url])
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: archiveImportTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                importArchives(urls)
            case let .failure(error):
                importError = error.localizedDescription
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelecting {
                selectionBar
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unable to export offline chapters.")
        }
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "Unable to import offline archive.")
        }
        .alert("Import Complete", isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
        .alert(model.workspace == .queue ? "Clear download queue?" : "Clear offline library?", isPresented: $model.showClearConfirm) {
            Button(model.workspace == .queue ? "Clear Queue" : "Clear Offline", role: .destructive) {
                Task { await model.clearCurrentWorkspace(using: library) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.workspace == .queue ? "Queued, downloading, and failed download tasks will be removed." : "All offline chapter files and their indexed records will be removed.")
        }
        .alert(model.workspace == .queue ? "Delete selected queue items?" : "Delete selected offline chapters?", isPresented: $model.showDeleteSelectionConfirm) {
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelected(using: library) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.workspace == .queue ? "Delete \(model.selectedCount) selected queue items." : "Delete \(model.selectedCount) selected offline chapters and remove their local files.")
        }
        .task {
            model.sync(from: library)
            let runtimeItems = await vm.currentRuntimeDownloadQueueItems()
            model.replaceRuntimeQueueItems(runtimeItems, persistedFallback: library.downloadChapters)
            if model.currentGroupsCount == 0 {
                await model.refresh(using: library)
                let refreshedRuntimeItems = await vm.currentRuntimeDownloadQueueItems()
                model.replaceRuntimeQueueItems(refreshedRuntimeItems, persistedFallback: library.downloadChapters)
            }
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .comicDownloadDidUpdate) {
                let item = notification.userInfo?[ComicDownloadNotificationKey.item] as? DownloadChapterItem
                let runtimeItems = await vm.currentRuntimeDownloadQueueItems()
                model.replaceRuntimeQueueItems(runtimeItems, persistedFallback: library.downloadChapters)

                if item?.status == .completed || item?.status == .failed || item == nil {
                    await library.refreshDownloadList()
                    model.sync(from: library)
                    let refreshedRuntimeItems = await vm.currentRuntimeDownloadQueueItems()
                    model.replaceRuntimeQueueItems(refreshedRuntimeItems, persistedFallback: library.downloadChapters)
                }
            }
        }
        .onChange(of: library.downloadChapters) { _, _ in
            model.sync(from: library)
        }
        .onChange(of: library.offlineChapters) { _, _ in
            model.sync(from: library)
        }
    }

    private var workspacePicker: some View {
        Picker("Workspace", selection: $model.workspace) {
            ForEach(DownloadWorkspace.allCases) { workspace in
                Text(workspace.title).tag(workspace)
            }
        }
        .pickerStyle(.segmented)
    }

    private var controlsCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            workspacePicker
            actionRow
        }
        .appCardStyle()
    }

    private var actionRow: some View {
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    Button {
                        Task { await model.refresh(using: library) }
                    } label: {
                        if model.isRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.isRefreshing)

                    if model.workspace == .offline {
                        Button("Import", systemImage: "square.and.arrow.down") {
                            showingImportPicker = true
                        }
                        .disabled(model.isRefreshing || model.isSelecting)

                        Button("Reindex", systemImage: "externaldrive.badge.checkmark") {
                            Task { await model.reindex(using: library) }
                        }
                        .disabled(model.isRefreshing)
                    }

                    if model.currentGroupsCount > 0 {
                        Button(model.isSelecting ? "Done" : "Select") {
                            model.toggleSelectionMode()
                        }

                        Button(model.workspace == .queue ? "Clear Queue" : "Clear Offline", role: .destructive) {
                            model.showClearConfirm = true
                        }
                        .disabled(model.isSelecting)
                    }
                }
            }

            if model.workspace == .queue {
                statusPill(title: "Live", value: "\(model.queueDownloadingCount + model.queuePendingCount)")
            } else if model.offlineIncompleteCount > 0 {
                statusPill(title: "Needs Review", value: "\(model.offlineIncompleteCount)")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var summaryHeader: some View {
        HStack(spacing: AppSpacing.md) {
            switch model.workspace {
            case .queue:
                metric(title: "Queued", value: "\(model.queuePendingCount)", tint: AppTint.warning)
                metric(title: "Downloading", value: "\(model.queueDownloadingCount)", tint: AppTint.accent)
                metric(title: "Failed", value: "\(model.queueFailedCount)", tint: .red)
            case .offline:
                metric(title: "Comics", value: "\(model.offlineGroups.count)", tint: AppTint.accent)
                metric(title: "Complete", value: "\(model.offlineCompleteCount)", tint: AppTint.success)
                metric(title: "Incomplete", value: "\(model.offlineIncompleteCount)", tint: model.offlineIncompleteCount == 0 ? .secondary : AppTint.warning)
            }
        }
    }

    @ViewBuilder
    private var groupsSection: some View {
        LazyVStack(spacing: AppSpacing.md) {
            switch model.workspace {
            case .queue:
                ForEach(model.queueGroups) { group in
                    DownloadQueueGroupCard(vm: vm, model: model, group: group)
                }
            case .offline:
                ForEach(model.offlineGroups) { group in
                    OfflineComicGroupCard(vm: vm, model: model, group: group)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(model.workspace == .queue ? "No queued downloads" : "No offline chapters")
                .font(.headline)
            Text(model.workspace == .queue ? "Queued, downloading, and failed tasks appear here until they are completed or removed." : "Completed local chapters are indexed here for offline reading and management.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCardStyle()
    }

    private var selectionBar: some View {
        HStack(spacing: AppSpacing.md) {
            Text("\(model.selectedCount) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if model.workspace == .offline {
                Button("Export ZIP") {
                    exportSelectedOfflineZIP()
                }
                .disabled(model.selectedCount == 0 || model.isExportingSelection)
            }

            Button(model.selectedCount == model.currentItemCount ? "Clear" : "Select All") {
                if model.selectedCount == model.currentItemCount {
                    model.clearSelection()
                } else {
                    model.selectAll()
                }
            }

            Button("Delete", role: .destructive) {
                model.showDeleteSelectionConfirm = true
            }
            .disabled(model.selectedCount == 0 || model.isDeletingSelection || model.isExportingSelection)
        }
        .font(.subheadline)
        .padding(.horizontal, AppSpacing.screen)
        .padding(.vertical, AppSpacing.md)
        .background(.thinMaterial)
    }

    private func metric(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }

    private func statusPill(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppSurface.subtle, in: Capsule(style: .continuous))
    }

    private func exportSelectedOfflineZIP() {
        let targets = model.selectedOfflineItems()
        guard !targets.isEmpty else { return }

        model.isExportingSelection = true
        Task {
            defer { model.isExportingSelection = false }
            do {
                let url = try OfflineExportService().exportOfflineSelectionZIP(
                    items: targets,
                    title: targets.count == 1 ? targets[0].comicTitle : "Offline Export"
                )
                sharedExportURL = ShareFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func importArchives(_ urls: [URL]) {
        guard !urls.isEmpty else { return }

        let securedURLs = urls.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }

        Task {
            defer {
                for (url, granted) in securedURLs where granted {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let summary = await library.importOfflineArchives(from: securedURLs.map(\.0))
            model.sync(from: library)

            if summary.importedCount > 0 {
                if summary.failures.isEmpty {
                    importMessage = "Imported \(summary.importedCount) archive\(summary.importedCount == 1 ? "" : "s")."
                } else {
                    let details = summary.failures.prefix(3).joined(separator: "\n")
                    importMessage = "Imported \(summary.importedCount) archive\(summary.importedCount == 1 ? "" : "s"), but some files were skipped.\n\(details)"
                }
            } else if let firstFailure = summary.failures.first {
                importError = firstFailure
            } else {
                importError = "No archives were imported."
            }
        }
    }
}

@MainActor
private struct DownloadQueueGroupCard: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var model: DownloadManagerScreenModel
    let group: DownloadComicGroup

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Button {
                if model.isSelecting {
                    model.toggleGroupSelection(group)
                } else {
                    model.toggleExpanded(group)
                }
            } label: {
                GroupHeader(
                    title: group.comicTitle,
                    coverURL: group.coverURL,
                    description: group.comicDescription,
                    summary: group.statusSummary,
                    badgeTexts: queueBadges,
                    isSelecting: model.isSelecting,
                    selectedState: selectedState,
                    isExpanded: model.isExpanded(group)
                )
            }
            .buttonStyle(.plain)

            if model.isExpanded(group) {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(group.chapters) { item in
                        QueueChapterRow(vm: vm, model: model, item: item)
                    }
                }
            }
        }
        .appCardStyle()
    }

    private var queueBadges: [(String, Color)] {
        var badges: [(String, Color)] = [("\(group.chapters.count) chapters", AppTint.accent)]
        if group.downloadingCount > 0 { badges.append(("\(group.downloadingCount) downloading", AppTint.accent)) }
        if group.pendingCount > 0 { badges.append(("\(group.pendingCount) queued", AppTint.warning)) }
        if group.failedCount > 0 { badges.append(("\(group.failedCount) failed", .red)) }
        return badges
    }

    private var selectedState: GroupSelectionState {
        if model.isGroupFullySelected(group) { return .full }
        if model.isGroupPartiallySelected(group) { return .partial }
        return .none
    }
}

@MainActor
private struct OfflineComicGroupCard: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var model: DownloadManagerScreenModel
    let group: OfflineComicGroup

    var body: some View {
        Group {
            if model.isSelecting {
                Button {
                    model.toggleGroupSelection(group)
                } label: {
                    GroupHeader(
                        title: group.comicTitle,
                        coverURL: group.coverURL,
                        localCoverFileURL: offlineComicCoverURL(from: group.chapters),
                        description: group.comicDescription,
                        summary: group.statusSummary,
                        badgeTexts: offlineBadges,
                        isSelecting: model.isSelecting,
                        selectedState: selectedState,
                        isExpanded: false
                    )
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    OfflineComicView(vm: vm, group: group)
                } label: {
                    GroupHeader(
                        title: group.comicTitle,
                        coverURL: group.coverURL,
                        localCoverFileURL: offlineComicCoverURL(from: group.chapters),
                        description: group.comicDescription,
                        summary: group.statusSummary,
                        badgeTexts: offlineBadges,
                        isSelecting: model.isSelecting,
                        selectedState: selectedState,
                        isExpanded: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .appCardStyle()
    }

    private var selectedState: GroupSelectionState {
        if model.isGroupFullySelected(group) { return .full }
        if model.isGroupPartiallySelected(group) { return .partial }
        return .none
    }

    private var offlineBadges: [(String, Color)] {
        var badges: [(String, Color)] = [("\(group.chapters.count) chapters", AppTint.accent)]
        if group.completeCount > 0 { badges.append(("\(group.completeCount) complete", AppTint.success)) }
        if group.chapters.allSatisfy({ $0.sourceKey == OfflineImportService.importedSourceKey }) {
            badges.append(("imported", AppTint.warning))
        }
        if group.incompleteCount > 0 { badges.append(("\(group.incompleteCount) incomplete", AppTint.warning)) }
        return badges
    }
}

private enum GroupSelectionState {
    case none
    case partial
    case full
}

private struct GroupHeader: View {
    let title: String
    let coverURL: String?
    let localCoverFileURL: URL?
    let description: String?
    let summary: String
    let badgeTexts: [(String, Color)]
    let isSelecting: Bool
    let selectedState: GroupSelectionState
    let isExpanded: Bool

    init(
        title: String,
        coverURL: String?,
        localCoverFileURL: URL? = nil,
        description: String?,
        summary: String,
        badgeTexts: [(String, Color)],
        isSelecting: Bool,
        selectedState: GroupSelectionState,
        isExpanded: Bool
    ) {
        self.title = title
        self.coverURL = coverURL
        self.localCoverFileURL = localCoverFileURL
        self.description = description
        self.summary = summary
        self.badgeTexts = badgeTexts
        self.isSelecting = isSelecting
        self.selectedState = selectedState
        self.isExpanded = isExpanded
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.md) {
            if isSelecting {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(selectedState == .none ? .secondary : AppTint.accent)
                    .padding(.top, 2)
            }

            CoverArtworkView(urlString: coverURL, fileURL: localCoverFileURL, width: 72, height: 102)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text(summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }

                if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    ForEach(Array(badgeTexts.enumerated()), id: \.offset) { _, badge in
                        Text(badge.0)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(badge.1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(badge.1.opacity(0.12), in: Capsule())
                    }
                }
            }

            if !isSelecting {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var iconName: String {
        switch selectedState {
        case .none: return "circle"
        case .partial: return "minus.circle.fill"
        case .full: return "checkmark.circle.fill"
        }
    }
}

private func offlineComicCoverURL(from chapters: [OfflineChapterAsset]) -> URL? {
    guard let anyChapter = chapters.first else { return nil }
    let comicDirectory = URL(fileURLWithPath: anyChapter.directoryPath).deletingLastPathComponent()
    let supported = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif"]
    return supported
        .map { comicDirectory.appendingPathComponent("cover.\($0)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
}

@MainActor
private struct QueueChapterRow: View {
    @Bindable var vm: ReaderViewModel
    @Bindable var model: DownloadManagerScreenModel
    let item: DownloadChapterItem
    @Environment(LibraryViewModel.self) private var library

    var body: some View {
        Group {
            if model.isSelecting {
                Button {
                    model.toggleSelection(for: item)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    DownloadedChapterFilesView(vm: vm, queueItem: item)
                } label: {
                    rowContent
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", role: .destructive) {
                        Task { await model.delete(item, using: library) }
                    }
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: AppSpacing.md) {
            if model.isSelecting {
                Image(systemName: model.isSelected(item) ? "checkmark.circle.fill" : "circle")
                    .font(.headline)
                    .foregroundStyle(model.isSelected(item) ? AppTint.accent : .secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.chapterTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(item.statusLabel, systemImage: item.statusIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.statusTint)
                    Text(item.progressText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if item.totalPages > 0, item.status == .downloading || item.status == .pending {
                        Text(item.progressPercentageText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }

                if item.totalPages > 0, item.status == .downloading || item.status == .pending {
                    ProgressView(value: item.progressFraction)
                        .tint(item.statusTint)
                }

                if let message = item.errorMessage, !message.isEmpty, item.status == .failed {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if !model.isSelecting {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 12)
        .background(AppSurface.subtle, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}

private struct DownloadedChapterDescriptor: Identifiable, Hashable {
    let id: String
    let sourceKey: String
    let comicID: String
    let comicTitle: String
    let coverURL: String?
    let comicDescription: String?
    let chapterID: String
    let chapterTitle: String
    let directoryPath: String
    let statusLabel: String
    let progressText: String
    let canReadOffline: Bool
    let chapterSequence: [ComicChapter]?
}

@MainActor
@Observable
private final class DownloadedChapterFilesScreenModel {
    var files: [DownloadedFileItem] = []
    var isLoading = false

    func load(directoryPath: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let loaded = await Task.detached(priority: .userInitiated) {
            Self.readFiles(at: directoryPath)
        }.value

        guard loaded != files else { return }
        files = loaded
    }

    nonisolated private static func readFiles(at directoryPath: String) -> [DownloadedFileItem] {
        let url = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files.compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true else {
                return nil
            }

            return DownloadedFileItem(
                name: fileURL.lastPathComponent,
                path: fileURL.path,
                sizeBytes: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

@MainActor
struct DownloadedChapterFilesView: View {
    @Bindable var vm: ReaderViewModel
    private let item: DownloadedChapterDescriptor
    @State private var model = DownloadedChapterFilesScreenModel()
    @State private var sharedExportURL: ShareFile?
    @State private var exportError: String?
    @State private var isExporting = false

    init(vm: ReaderViewModel, queueItem: DownloadChapterItem) {
        self._vm = Bindable(vm)
        self.item = DownloadedChapterDescriptor(
            id: "queue::\(queueItem.id)",
            sourceKey: queueItem.sourceKey,
            comicID: queueItem.comicID,
            comicTitle: queueItem.comicTitle,
            coverURL: queueItem.coverURL,
            comicDescription: queueItem.comicDescription,
            chapterID: queueItem.chapterID,
            chapterTitle: queueItem.chapterTitle,
            directoryPath: queueItem.directoryPath,
            statusLabel: queueItem.statusLabel,
            progressText: queueItem.progressText,
            canReadOffline: queueItem.status == .completed,
            chapterSequence: nil
        )
    }

    init(vm: ReaderViewModel, offlineItem: OfflineChapterAsset, chapterSequence: [ComicChapter]? = nil) {
        self._vm = Bindable(vm)
        self.item = DownloadedChapterDescriptor(
            id: "offline::\(offlineItem.id)",
            sourceKey: offlineItem.sourceKey,
            comicID: offlineItem.comicID,
            comicTitle: offlineItem.comicTitle,
            coverURL: offlineItem.coverURL,
            comicDescription: offlineItem.comicDescription,
            chapterID: offlineItem.chapterID,
            chapterTitle: offlineItem.chapterTitle,
            directoryPath: offlineItem.directoryPath,
            statusLabel: offlineItem.integrityStatus.title,
            progressText: "\(offlineItem.verifiedPageCount)/\(offlineItem.pageCount) pages",
            canReadOffline: offlineItem.integrityStatus == .complete,
            chapterSequence: chapterSequence
        )
    }

    var body: some View {
        List {
            Section("Comic") {
                LabeledContent("Comic", value: item.comicTitle)
                LabeledContent("Chapter", value: item.chapterTitle)
                if let description = item.comicDescription, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }
                LabeledContent("Status", value: item.statusLabel)
                LabeledContent("Pages", value: item.progressText)

                if item.canReadOffline {
                    NavigationLink("Read Offline") {
                        ComicReaderView(
                            vm: vm,
                            item: ComicSummary(
                                id: item.comicID,
                                sourceKey: item.sourceKey,
                                title: item.comicTitle,
                                coverURL: item.coverURL
                            ),
                            chapterID: item.chapterID,
                            chapterTitle: item.chapterTitle,
                            localChapterDirectory: item.directoryPath,
                            chapterSequence: item.chapterSequence
                        )
                    }
                }

                Menu("Export") {
                    Button("Export ZIP", systemImage: "doc.zipper") {
                        exportCurrentChapter(.zip)
                    }
                    if item.canReadOffline {
                        Button("Export CBZ", systemImage: "book.closed") {
                            exportCurrentChapter(.cbz)
                        }
                        Button("Export PDF", systemImage: "doc.richtext") {
                            exportCurrentChapter(.pdf)
                        }
                        Button("Export EPUB", systemImage: "books.vertical") {
                            exportCurrentChapter(.epub)
                        }
                    }
                }
                .disabled(isExporting)
            }

            Section("Files") {
                if model.isLoading && model.files.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading files…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.files.isEmpty {
                    Text("No files in this chapter")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.files) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name)
                                .font(.body.monospaced())
                            Text(ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Chapter Files")
        .sheet(item: $sharedExportURL) { shareFile in
            ActivityShareSheet(items: [shareFile.url])
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unable to export this chapter.")
        }
        .task(id: item.id) {
            await model.load(directoryPath: item.directoryPath)
        }
    }

    private func exportCurrentChapter(_ format: OfflineExportFormat) {
        guard !isExporting else { return }
        isExporting = true
        let pageCount = max(model.files.count, 1)
        let asset = OfflineChapterAsset(
            id: 0,
            sourceKey: item.sourceKey,
            comicID: item.comicID,
            comicTitle: item.comicTitle,
            coverURL: item.coverURL,
            comicDescription: item.comicDescription,
            chapterID: item.chapterID,
            chapterTitle: item.chapterTitle,
            pageCount: pageCount,
            verifiedPageCount: pageCount,
            integrityStatus: item.canReadOffline ? .complete : .incomplete,
            directoryPath: item.directoryPath,
            downloadedAt: 0,
            lastVerifiedAt: 0,
            updatedAt: 0
        )
        Task {
            defer { isExporting = false }
            do {
                let url = try OfflineExportService().exportChapter(asset, format: format)
                sharedExportURL = ShareFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

private extension DownloadChapterItem {
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
