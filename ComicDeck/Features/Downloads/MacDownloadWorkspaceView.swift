import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
@MainActor
struct MacDownloadWorkspaceView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library

    @State private var model = DownloadManagerScreenModel()
    @State private var selectedQueueGroupID: DownloadComicGroup.ID?
    @State private var selectedOfflineGroupID: OfflineComicGroup.ID?
    @State private var selectedQueueChapterID: DownloadChapterItem.ID?
    @State private var selectedOfflineChapterID: OfflineChapterAsset.ID?
    @State private var selectedQueueItem: DownloadChapterItem?
    @State private var selectedOfflineItem: OfflineChapterAsset?
    @State private var selectionCommandController = MacSelectionCommandController()
    @State private var showingImportPicker = false
    @State private var sharedExportURL: ShareFile?
    @State private var exportError: String?
    @State private var importMessage: String?
    @State private var importError: String?

    private var archiveImportTypes: [UTType] {
        var types: [UTType] = [.zip]
        if let cbz = UTType(filenameExtension: "cbz") {
            types.append(cbz)
        }
        return types
    }

    private var selectedQueueGroup: DownloadComicGroup? {
        model.queueGroups.first { $0.id == selectedQueueGroupID } ?? model.queueGroups.first
    }

    private var selectedOfflineGroup: OfflineComicGroup? {
        model.offlineGroups.first { $0.id == selectedOfflineGroupID } ?? model.offlineGroups.first
    }

    private var selectedQueueChapter: DownloadChapterItem? {
        guard let selectedQueueChapterID else { return nil }
        return selectedQueueGroup?.chapters.first { $0.id == selectedQueueChapterID }
    }

    private var selectedOfflineChapter: OfflineChapterAsset? {
        guard let selectedOfflineChapterID else { return nil }
        return selectedOfflineGroup?.chapters.first { $0.id == selectedOfflineChapterID }
    }

    private var selectedGroupTitle: String {
        switch model.workspace {
        case .queue:
            selectedQueueGroup?.comicTitle ?? AppLocalization.text("downloads.empty.no_queue", "No queued downloads")
        case .offline:
            selectedOfflineGroup?.comicTitle ?? AppLocalization.text("downloads.empty.no_offline", "No offline chapters")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 320)

            Divider()

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(AppLocalization.text("downloads.navigation.title", "Downloads"))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await refreshDownloads() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(AppLocalization.text("downloads.action.refresh", "Refresh"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)

                if model.workspace == .offline {
                    Button(AppLocalization.text("downloads.action.import", "Import"), systemImage: "square.and.arrow.down") {
                        showingImportPicker = true
                    }
                    Button(AppLocalization.text("downloads.action.reindex", "Reindex"), systemImage: "externaldrive.badge.checkmark") {
                        Task { await model.reindex(using: library) }
                    }
                    .disabled(model.isRefreshing)
                }

                Menu(AppLocalization.text("tracking.sync.more", "More"), systemImage: "ellipsis.circle") {
                    Button(model.workspace == .queue ? AppLocalization.text("downloads.action.clear_queue", "Clear Queue") : AppLocalization.text("downloads.action.clear_offline", "Clear Offline"), role: .destructive) {
                        model.showClearConfirm = true
                    }
                    .disabled(model.currentItemCount == 0)
                }
            }
        }
        .task {
            await bootstrap()
            configureSelectionCommands()
        }
        .task {
            for await notification in NotificationCenter.default.notifications(named: .comicDownloadDidUpdate) {
                let item = notification.userInfo?[ComicDownloadNotificationKey.item] as? DownloadChapterItem
                let runtimeItems = await vm.currentRuntimeDownloadQueueItems()
                model.replaceRuntimeQueueItems(runtimeItems, persistedFallback: library.downloadChapters)
                if item?.status == .completed || item?.status == .failed || item == nil {
                    await library.refreshDownloadList()
                    model.sync(from: library)
                    selectDefaultGroupIfNeeded()
                    configureSelectionCommands()
                }
            }
        }
        .onChange(of: library.downloadChapters) { _, _ in
            model.sync(from: library)
            selectDefaultGroupIfNeeded()
            configureSelectionCommands()
        }
        .onChange(of: library.offlineChapters) { _, _ in
            model.sync(from: library)
            selectDefaultGroupIfNeeded()
            configureSelectionCommands()
        }
        .onChange(of: model.workspace) { _, _ in
            selectDefaultGroupIfNeeded(force: true)
            configureSelectionCommands()
        }
        .onChange(of: selectedQueueGroupID) { _, _ in
            selectedQueueChapterID = nil
            configureSelectionCommands()
        }
        .onChange(of: selectedOfflineGroupID) { _, _ in
            selectedOfflineChapterID = nil
            configureSelectionCommands()
        }
        .onChange(of: selectedQueueChapterID) { _, _ in
            configureSelectionCommands()
        }
        .onChange(of: selectedOfflineChapterID) { _, _ in
            configureSelectionCommands()
        }
        .focusedSceneValue(\.macSelectionCommandController, selectionCommandController)
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
        .sheet(item: $sharedExportURL) { shareFile in
            ActivityShareSheet(items: [shareFile.url])
        }
        .sheet(item: $selectedQueueItem) { item in
            NavigationStack {
                DownloadedChapterFilesView(vm: vm, queueItem: item)
                    .environment(library)
                    .frame(minWidth: 560, minHeight: 460)
            }
        }
        .sheet(item: $selectedOfflineItem) { item in
            NavigationStack {
                DownloadedChapterFilesView(
                    vm: vm,
                    offlineItem: item,
                    chapterSequence: OfflineChapterSequenceBuilder.sequence(for: item, in: model.offlineItems)
                )
                .environment(library)
                .frame(minWidth: 560, minHeight: 460)
            }
        }
        .alert(AppLocalization.text("downloads.alert.clear_queue.title", "Clear download queue?"), isPresented: $model.showClearConfirm) {
            Button(model.workspace == .queue ? AppLocalization.text("downloads.action.clear_queue", "Clear Queue") : AppLocalization.text("downloads.action.clear_offline", "Clear Offline"), role: .destructive) {
                Task { await model.clearCurrentWorkspace(using: library) }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(model.workspace == .queue ? AppLocalization.text("downloads.empty.no_queue_hint", "Queued, downloading, and failed download tasks will be removed.") : AppLocalization.text("downloads.alert.clear_offline.message", "All offline chapter files and their indexed records will be removed."))
        }
        .alert(AppLocalization.text("downloads.alert.export_failed", "Export Failed"), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(exportError ?? AppLocalization.text("downloads.alert.export_failed", "Unable to export offline chapters."))
        }
        .alert(AppLocalization.text("downloads.alert.import_failed", "Import Failed"), isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(importError ?? AppLocalization.text("downloads.alert.import_failed", "Unable to import offline archive."))
        }
        .alert(AppLocalization.text("downloads.alert.import_complete", "Import Complete"), isPresented: Binding(
            get: { importMessage != nil },
            set: { if !$0 { importMessage = nil } }
        )) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker(AppLocalization.text("downloads.workspace", "Workspace"), selection: $model.workspace) {
                ForEach(DownloadWorkspace.allCases) { workspace in
                    Text(workspace.title).tag(workspace)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            metricStrip
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Divider()

            List(selection: model.workspace == .queue ? $selectedQueueGroupID : $selectedOfflineGroupID) {
                switch model.workspace {
                case .queue:
                    ForEach(model.queueGroups) { group in
                        MacDownloadGroupSidebarRow(
                            title: group.comicTitle,
                            subtitle: group.statusSummary,
                            coverURL: group.coverURL,
                            refererURLString: group.comicID,
                            localCoverFileURL: nil,
                            warningCount: group.failedCount,
                            count: group.chapters.count
                        )
                        .tag(group.id)
                        .contextMenu {
                            Button(AppLocalization.text("common.copy", "Copy"), systemImage: "doc.on.doc") {
                                PlatformPasteboard.copy(group.comicTitle)
                            }
                            Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
                                PlatformPasteboard.copy(group.comicID)
                            }
                            Button(AppLocalization.text("downloads.action.delete", "Delete"), systemImage: "trash", role: .destructive) {
                                Task { await deleteQueueGroup(group) }
                            }
                        }
                    }
                case .offline:
                    ForEach(model.offlineGroups) { group in
                        MacDownloadGroupSidebarRow(
                            title: group.comicTitle,
                            subtitle: group.statusSummary,
                            coverURL: group.coverURL,
                            refererURLString: group.comicID,
                            localCoverFileURL: group.localCoverFileURL,
                            warningCount: group.incompleteCount,
                            count: group.chapters.count
                        )
                        .tag(group.id)
                        .onDrag {
                            selectedOfflineGroupID = group.id
                            return exportedOfflineGroupItemProvider(group)
                        }
                        .contextMenu {
                            Button(AppLocalization.text("common.copy", "Copy"), systemImage: "doc.on.doc") {
                                PlatformPasteboard.copy(group.comicTitle)
                            }
                            Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
                                PlatformPasteboard.copy(group.comicID)
                            }
                            Button(AppLocalization.text("downloads.action.reveal_in_finder", "Reveal in Finder"), systemImage: "folder") {
                                revealOfflineGroup(group)
                            }
                            Button(AppLocalization.text("downloads.action.export_zip", "Export ZIP"), systemImage: "doc.zipper") {
                                exportOfflineGroupZIP(group)
                            }
                            Button(AppLocalization.text("downloads.action.delete", "Delete"), systemImage: "trash", role: .destructive) {
                                Task { await deleteOfflineGroup(group) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .background(AppSurface.grouped)
    }

    private var metricStrip: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            switch model.workspace {
            case .queue:
                GridRow {
                    metric(AppLocalization.text("downloads.metric.queued", "Queued"), "\(model.queuePendingCount)", AppTint.warning)
                    metric(AppLocalization.text("downloads.metric.downloading", "Downloading"), "\(model.queueDownloadingCount)", AppTint.accent)
                    metric(AppLocalization.text("downloads.metric.failed", "Failed"), "\(model.queueFailedCount)", AppTint.danger)
                }
            case .offline:
                GridRow {
                    metric(AppLocalization.text("downloads.metric.comics", "Comics"), "\(model.offlineGroups.count)", AppTint.accent)
                    metric(AppLocalization.text("downloads.metric.complete", "Complete"), "\(model.offlineCompleteCount)", AppTint.success)
                    metric(AppLocalization.text("downloads.metric.incomplete", "Incomplete"), "\(model.offlineIncompleteCount)", model.offlineIncompleteCount == 0 ? .secondary : AppTint.warning)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(AppSurface.subtle, in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
    }

    @ViewBuilder
    private var detailPane: some View {
        switch model.workspace {
        case .queue:
            if let group = selectedQueueGroup {
                queueDetail(group)
            } else {
                emptyDetail(
                    title: AppLocalization.text("downloads.empty.no_queue", "No queued downloads"),
                    description: AppLocalization.text("downloads.empty.no_queue_hint", "Queued, downloading, and failed download tasks will be removed."),
                    systemImage: "arrow.down.circle"
                )
            }
        case .offline:
            if let group = selectedOfflineGroup {
                offlineDetail(group)
            } else {
                emptyDetail(
                    title: AppLocalization.text("downloads.empty.no_offline", "No offline chapters"),
                    description: AppLocalization.text("downloads.empty.no_offline_hint", "Completed local chapters are indexed here for offline reading and management."),
                    systemImage: "externaldrive"
                )
            }
        }
    }

    private func queueDetail(_ group: DownloadComicGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(
                title: group.comicTitle,
                subtitle: group.statusSummary,
                coverURL: group.coverURL,
                refererURLString: group.comicID,
                localCoverFileURL: nil,
                badges: [
                    ("\(group.chapters.count)", AppLocalization.text("downloads.metric.chapters", "Chapters"), AppTint.accent),
                    ("\(group.downloadingCount)", AppLocalization.text("downloads.metric.downloading", "Downloading"), AppTint.accent),
                    ("\(group.failedCount)", AppLocalization.text("downloads.metric.failed", "Failed"), AppTint.danger)
                ],
                actions: {
                    Button(AppLocalization.text("downloads.action.delete", "Delete"), systemImage: "trash", role: .destructive) {
                        Task { await deleteQueueGroup(group) }
                    }
                }
            )

            List(selection: $selectedQueueChapterID) {
                ForEach(group.chapters) { item in
                    MacQueueChapterRow(item: item)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedQueueChapterID = item.id
                            selectedQueueItem = item
                        }
                        .contextMenu {
                            queueChapterContextMenu(for: item)
                        }
                }
            }
            .listStyle(.inset)
        }
        .background(AppSurface.grouped)
    }

    private func offlineDetail(_ group: OfflineComicGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(
                title: group.comicTitle,
                subtitle: group.statusSummary,
                coverURL: group.coverURL,
                refererURLString: group.comicID,
                localCoverFileURL: group.localCoverFileURL,
                badges: [
                    ("\(group.chapters.count)", AppLocalization.text("downloads.metric.chapters", "Chapters"), AppTint.accent),
                    ("\(group.completeCount)", AppLocalization.text("downloads.metric.complete", "Complete"), AppTint.success),
                    ("\(group.incompleteCount)", AppLocalization.text("downloads.metric.incomplete", "Incomplete"), group.incompleteCount == 0 ? .secondary : AppTint.warning)
                ],
                actions: {
                    Button(AppLocalization.text("downloads.action.reveal_in_finder", "Reveal in Finder"), systemImage: "folder") {
                        revealOfflineGroup(group)
                    }
                    Button(AppLocalization.text("downloads.action.export_zip", "Export ZIP"), systemImage: "doc.zipper") {
                        exportOfflineGroupZIP(group)
                    }
                    Button(AppLocalization.text("downloads.action.delete", "Delete"), systemImage: "trash", role: .destructive) {
                        Task { await deleteOfflineGroup(group) }
                    }
                }
            )

            List(selection: $selectedOfflineChapterID) {
                ForEach(group.chapters) { item in
                    MacOfflineChapterRow(item: item)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedOfflineChapterID = item.id
                            selectedOfflineItem = item
                        }
                        .onDrag {
                            selectedOfflineChapterID = item.id
                            return fileURLItemProvider(URL(fileURLWithPath: item.directoryPath, isDirectory: true))
                        }
                        .contextMenu {
                            offlineChapterContextMenu(for: item)
                        }
                }
            }
            .listStyle(.inset)
        }
        .background(AppSurface.grouped)
    }

    private func detailHeader<Actions: View>(
        title: String,
        subtitle: String,
        coverURL: String?,
        refererURLString: String?,
        localCoverFileURL: URL?,
        badges: [(String, String, Color)],
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CoverArtworkView(
                    urlString: coverURL,
                    refererURLString: refererURLString,
                    fileURL: localCoverFileURL,
                    width: 72,
                    height: 102
                )
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(badges.indices, id: \.self) { index in
                            let badge = badges[index]
                            VStack(alignment: .leading, spacing: 2) {
                                Text(badge.0)
                                    .font(.headline.monospacedDigit())
                                Text(badge.1)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(badge.2.opacity(0.12), in: RoundedRectangle(cornerRadius: AppRadius.sm, style: .continuous))
                        }
                    }
                }
                Spacer(minLength: 0)
                Menu(AppLocalization.text("tracking.sync.more", "More"), systemImage: "ellipsis.circle") {
                    actions()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSurface.card)
    }

    private func emptyDetail(title: String, description: String, systemImage: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button(AppLocalization.text("downloads.action.refresh", "Refresh")) {
                Task { await refreshDownloads() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppSurface.grouped)
    }

    private func bootstrap() async {
        model.sync(from: library)
        let runtimeItems = await vm.currentRuntimeDownloadQueueItems()
        model.replaceRuntimeQueueItems(runtimeItems, persistedFallback: library.downloadChapters)
        if model.currentGroupsCount == 0 {
            await model.refresh(using: library)
            let refreshedRuntimeItems = await vm.currentRuntimeDownloadQueueItems()
            model.replaceRuntimeQueueItems(refreshedRuntimeItems, persistedFallback: library.downloadChapters)
        }
        selectDefaultGroupIfNeeded()
    }

    private func refreshDownloads() async {
        await model.refresh(using: library)
        let runtimeItems = await vm.currentRuntimeDownloadQueueItems()
        model.replaceRuntimeQueueItems(runtimeItems, persistedFallback: library.downloadChapters)
        selectDefaultGroupIfNeeded(force: true)
    }

    private func selectDefaultGroupIfNeeded(force: Bool = false) {
        switch model.workspace {
        case .queue:
            if force || selectedQueueGroupID == nil || !model.queueGroups.contains(where: { $0.id == selectedQueueGroupID }) {
                selectedQueueGroupID = model.queueGroups.first?.id
            }
            if selectedQueueChapterID != nil && selectedQueueChapter == nil {
                selectedQueueChapterID = nil
            }
        case .offline:
            if force || selectedOfflineGroupID == nil || !model.offlineGroups.contains(where: { $0.id == selectedOfflineGroupID }) {
                selectedOfflineGroupID = model.offlineGroups.first?.id
            }
            if selectedOfflineChapterID != nil && selectedOfflineChapter == nil {
                selectedOfflineChapterID = nil
            }
        }
    }

    @ViewBuilder
    private func queueChapterContextMenu(for item: DownloadChapterItem) -> some View {
        Button(AppLocalization.text("common.open", "Open"), systemImage: "folder") {
            openQueueChapter(item)
        }
        Button(AppLocalization.text("downloads.action.reveal_in_finder", "Reveal in Finder"), systemImage: "folder") {
            revealQueueChapter(item)
        }
        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            PlatformPasteboard.copy(item.chapterTitle)
        }
        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            PlatformPasteboard.copy(item.chapterID)
        }
        Button(AppLocalization.text("downloads.action.delete", "Delete"), systemImage: "trash", role: .destructive) {
            Task { await deleteQueueChapter(item) }
        }
    }

    @ViewBuilder
    private func offlineChapterContextMenu(for item: OfflineChapterAsset) -> some View {
        if item.integrityStatus == .complete {
            Button(AppLocalization.text("reader.action.read", "Read"), systemImage: "play.fill") {
                openOfflineChapter(item)
            }
        }
        Button(AppLocalization.text("common.open", "Open"), systemImage: "folder") {
            openOfflineChapter(item)
        }
        Button(AppLocalization.text("downloads.action.reveal_in_finder", "Reveal in Finder"), systemImage: "folder") {
            revealOfflineChapter(item)
        }
        Button(AppLocalization.text("detail.action.copy_title", "Copy Title"), systemImage: "doc.on.doc") {
            PlatformPasteboard.copy(item.chapterTitle)
        }
        Button(AppLocalization.text("detail.action.copy_id", "Copy ID"), systemImage: "number") {
            PlatformPasteboard.copy(item.chapterID)
        }
        Button(AppLocalization.text("downloads.action.delete", "Delete"), systemImage: "trash", role: .destructive) {
            Task { await deleteOfflineChapter(item) }
        }
    }

    private func configureSelectionCommands() {
        selectionCommandController.reset()

        switch model.workspace {
        case .queue:
            if let item = selectedQueueChapter {
                selectionCommandController.open = { openQueueChapter(item) }
                selectionCommandController.delete = { Task { await deleteQueueChapter(item) } }
                selectionCommandController.copyTitle = { PlatformPasteboard.copy(item.chapterTitle) }
                selectionCommandController.copyID = { PlatformPasteboard.copy(item.chapterID) }
                selectionCommandController.reveal = { revealQueueChapter(item) }
                selectionCommandController.canOpen = true
                selectionCommandController.canDelete = true
                selectionCommandController.canCopyTitle = true
                selectionCommandController.canCopyID = true
                selectionCommandController.canReveal = true
            } else if let group = selectedQueueGroup {
                selectionCommandController.open = { openQueueGroup(group) }
                selectionCommandController.delete = { Task { await deleteQueueGroup(group) } }
                selectionCommandController.copyTitle = { PlatformPasteboard.copy(group.comicTitle) }
                selectionCommandController.copyID = { PlatformPasteboard.copy(group.comicID) }
                selectionCommandController.canOpen = !group.chapters.isEmpty
                selectionCommandController.canDelete = !group.chapters.isEmpty
                selectionCommandController.canCopyTitle = true
                selectionCommandController.canCopyID = true
            }
        case .offline:
            if let item = selectedOfflineChapter {
                selectionCommandController.open = { openOfflineChapter(item) }
                selectionCommandController.delete = { Task { await deleteOfflineChapter(item) } }
                selectionCommandController.copyTitle = { PlatformPasteboard.copy(item.chapterTitle) }
                selectionCommandController.copyID = { PlatformPasteboard.copy(item.chapterID) }
                selectionCommandController.reveal = { revealOfflineChapter(item) }
                selectionCommandController.canOpen = true
                selectionCommandController.canDelete = true
                selectionCommandController.canCopyTitle = true
                selectionCommandController.canCopyID = true
                selectionCommandController.canReveal = true
            } else if let group = selectedOfflineGroup {
                selectionCommandController.open = { openOfflineGroup(group) }
                selectionCommandController.delete = { Task { await deleteOfflineGroup(group) } }
                selectionCommandController.copyTitle = { PlatformPasteboard.copy(group.comicTitle) }
                selectionCommandController.copyID = { PlatformPasteboard.copy(group.comicID) }
                selectionCommandController.reveal = { revealOfflineGroup(group) }
                selectionCommandController.export = { exportOfflineGroupZIP(group) }
                selectionCommandController.canOpen = !group.chapters.isEmpty
                selectionCommandController.canDelete = !group.chapters.isEmpty
                selectionCommandController.canCopyTitle = true
                selectionCommandController.canCopyID = true
                selectionCommandController.canReveal = !group.chapters.isEmpty
                selectionCommandController.canExport = !group.chapters.isEmpty
            }
        }
    }

    private func openQueueGroup(_ group: DownloadComicGroup) {
        guard let item = group.chapters.first else { return }
        openQueueChapter(item)
    }

    private func openOfflineGroup(_ group: OfflineComicGroup) {
        guard let item = group.chapters.first(where: { $0.integrityStatus == .complete }) ?? group.chapters.first else { return }
        openOfflineChapter(item)
    }

    private func openQueueChapter(_ item: DownloadChapterItem) {
        selectedQueueChapterID = item.id
        selectedQueueItem = item
    }

    private func openOfflineChapter(_ item: OfflineChapterAsset) {
        selectedOfflineChapterID = item.id
        selectedOfflineItem = item
    }

    private func revealQueueChapter(_ item: DownloadChapterItem) {
        PlatformFileActions.revealDirectory(path: item.directoryPath)
    }

    private func revealOfflineChapter(_ item: OfflineChapterAsset) {
        PlatformFileActions.revealDirectory(path: item.directoryPath)
    }

    private func deleteQueueChapter(_ item: DownloadChapterItem) async {
        await model.delete(item, using: library)
        selectedQueueChapterID = nil
        selectDefaultGroupIfNeeded(force: true)
        configureSelectionCommands()
    }

    private func deleteOfflineChapter(_ item: OfflineChapterAsset) async {
        await model.delete(item, using: library)
        selectedOfflineChapterID = nil
        selectDefaultGroupIfNeeded(force: true)
        configureSelectionCommands()
    }

    private func deleteQueueGroup(_ group: DownloadComicGroup) async {
        await library.deleteDownloads(group.chapters)
        model.sync(from: library)
        selectDefaultGroupIfNeeded(force: true)
        configureSelectionCommands()
    }

    private func deleteOfflineGroup(_ group: OfflineComicGroup) async {
        await library.deleteOfflineChapters(group.chapters)
        model.sync(from: library)
        selectDefaultGroupIfNeeded(force: true)
        configureSelectionCommands()
    }

    private func revealOfflineGroup(_ group: OfflineComicGroup) {
        guard let first = group.chapters.first else { return }
        let comicDirectory = URL(fileURLWithPath: first.directoryPath).deletingLastPathComponent()
        PlatformFileActions.revealDirectory(path: comicDirectory.path)
    }

    private func exportOfflineGroupZIP(_ group: OfflineComicGroup) {
        do {
            let url = try OfflineExportService().exportComic(group: group, format: .zip)
            sharedExportURL = ShareFile(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func exportedOfflineGroupItemProvider(_ group: OfflineComicGroup) -> NSItemProvider {
        do {
            let url = try OfflineExportService().exportComic(group: group, format: .zip)
            return fileURLItemProvider(url)
        } catch {
            exportError = error.localizedDescription
            return NSItemProvider(object: group.comicTitle as NSString)
        }
    }

    private func fileURLItemProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }
        provider.suggestedName = url.lastPathComponent
        return provider
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
            selectDefaultGroupIfNeeded(force: true)

            if summary.importedCount > 0 {
                if summary.failures.isEmpty {
                    importMessage = AppLocalization.format("downloads.import.complete_count", "Imported %lld archives.", Int64(summary.importedCount))
                } else {
                    let details = summary.failures.prefix(3).joined(separator: "\n")
                    importMessage = AppLocalization.format("downloads.import.partial_count", "Imported %lld archives, but some files were skipped.\n%@", Int64(summary.importedCount), details)
                }
            } else if let firstFailure = summary.failures.first {
                importError = firstFailure
            } else {
                importError = AppLocalization.text("downloads.import.none", "No archives were imported.")
            }
        }
    }
}

private struct MacDownloadGroupSidebarRow: View {
    let title: String
    let subtitle: String
    let coverURL: String?
    let refererURLString: String?
    let localCoverFileURL: URL?
    let warningCount: Int
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            CoverArtworkView(
                urlString: coverURL,
                refererURLString: refererURLString,
                fileURL: localCoverFileURL,
                width: 34,
                height: 48
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                if warningCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(AppTint.warning)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MacQueueChapterRow: View {
    let item: DownloadChapterItem

    var body: some View {
        HStack(spacing: 12) {
            Label(item.statusLabel, systemImage: item.statusIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.statusTint)
                .frame(width: 124, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.chapterTitle)
                    .font(.body)
                    .lineLimit(1)
                Text(item.chapterID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(item.progressText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)

            if item.totalPages > 0, item.status == .downloading || item.status == .pending {
                ProgressView(value: item.progressFraction)
                    .frame(width: 120)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct MacOfflineChapterRow: View {
    let item: OfflineChapterAsset

    var body: some View {
        HStack(spacing: 12) {
            Label(item.integrityStatus.title, systemImage: item.integrityStatus == .complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.integrityStatus == .complete ? AppTint.success : AppTint.warning)
                .frame(width: 124, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.chapterTitle.isEmpty ? item.chapterID : item.chapterTitle)
                    .font(.body)
                    .lineLimit(1)
                Text(item.chapterID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text("\(item.verifiedPageCount)/\(item.pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}
#endif
