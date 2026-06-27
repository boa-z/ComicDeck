import SwiftUI

@MainActor
struct OfflineComicView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library

    let group: OfflineComicGroup

    @State private var selectedFilesItem: OfflineChapterAsset?
    @State private var sharedExportURL: ShareFile?
    @State private var exportError: String?
    @State private var exportTarget: String?
    @State private var showingRenamePrompt = false
    @State private var renameTitle = ""

    private var sortedReaderChapters: [OfflineChapterAsset] {
        group.chapters
            .filter { $0.integrityStatus == .complete }
            .sorted { lhs, rhs in
                if lhs.downloadedAt != rhs.downloadedAt { return lhs.downloadedAt < rhs.downloadedAt }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
            }
    }

    private var incompleteChapters: [OfflineChapterAsset] {
        group.chapters
            .filter { $0.integrityStatus != .complete }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
            }
    }

    private var chapterSequence: [ComicChapter] {
        sortedReaderChapters.map {
            ComicChapter(
                id: $0.chapterID,
                title: $0.chapterTitle.isEmpty ? $0.chapterID : $0.chapterTitle
            )
        }
    }

    private var latestReadableChapter: OfflineChapterAsset? {
        sortedReaderChapters.last
    }

    private var localCoverFileURL: URL? {
        offlineComicCoverURL(from: group.chapters)
    }

    private var completeCount: Int {
        group.chapters.lazy.filter { $0.integrityStatus == .complete }.count
    }

    private var incompleteCount: Int {
        group.chapters.lazy.filter { $0.integrityStatus == .incomplete }.count
    }

    private var isImportedGroup: Bool {
        group.chapters.allSatisfy { $0.sourceKey == OfflineImportService.importedSourceKey }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppSpacing.section) {
                heroSection
                readingSummaryCard
                completeChaptersSection
                if !incompleteChapters.isEmpty {
                    incompleteChaptersSection
                }
            }
            .padding(.horizontal, AppSpacing.screen)
            .padding(.top, AppSpacing.md)
            .padding(.bottom, AppSpacing.xl)
        }
        .navigationTitle(group.comicTitle)
        .platformNavigationBarTitleDisplayModeInline()
        .background(AppSurface.grouped.ignoresSafeArea())
        .sheet(item: $sharedExportURL) { shareFile in
            ActivityShareSheet(items: [shareFile.url])
        }
        .alert(AppLocalization.text("rename.imported.comic", "Rename Imported Comic"), isPresented: $showingRenamePrompt) {
            TextField(AppLocalization.text("detail.title.label", "Comic Title"), text: $renameTitle)
            Button(AppLocalization.text("common.save", "Save")) {
                Task {
                    await library.renameImportedOfflineComic(
                        sourceKey: OfflineImportService.importedSourceKey,
                        comicID: group.comicID,
                        to: renameTitle
                    )
                }
            }
            Button(AppLocalization.text("common.cancel", "Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalization.text("downloads.rename.imported.message", "This only renames the imported offline entry in ComicDeck."))
        }
        .alert(AppLocalization.text("downloads.alert.export_failed", "Export Failed"), isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
        } message: {
            Text(exportError ?? AppLocalization.text("downloads.alert.export_offline_failed", "Unable to export offline files."))
        }
        .navigationDestination(item: $selectedFilesItem) { item in
            DownloadedChapterFilesView(vm: vm, offlineItem: item, chapterSequence: chapterSequence)
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .top, spacing: AppSpacing.md) {
                CoverArtworkView(urlString: group.coverURL, fileURL: localCoverFileURL, width: 92, height: 132)

                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(group.comicTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    if let description = group.comicDescription,
                       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                    }

                    flexibleBadges
                }
            }

            if let latestReadableChapter {
                HStack(spacing: AppSpacing.sm) {
                    NavigationLink {
                        ReaderRoutingView(
                            vm: vm,
                            item: ComicSummary(
                                id: latestReadableChapter.comicID,
                                sourceKey: latestReadableChapter.sourceKey,
                                title: latestReadableChapter.comicTitle,
                                coverURL: latestReadableChapter.coverURL
                            ),
                            chapterID: latestReadableChapter.chapterID,
                            chapterTitle: latestReadableChapter.chapterTitle,
                            localChapterDirectory: latestReadableChapter.directoryPath,
                            chapterSequence: chapterSequence
                        )
                        .environment(library)
                    } label: {
                        Label(AppLocalization.text("downloads.action.resume_offline", "Resume Offline"), systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Menu {
                        if isImportedGroup {
                            Button(AppLocalization.text("rename.imported.comic", "Rename Imported Comic"), systemImage: "pencil") {
                                renameTitle = group.comicTitle
                                showingRenamePrompt = true
                            }
                        }
                        Button(AppLocalization.text("downloads.action.export_comic_zip", "Export Comic ZIP"), systemImage: "archivebox") {
                            exportComic(.zip)
                        }
                        Button(AppLocalization.text("downloads.action.export_comic_pdf", "Export Comic PDF"), systemImage: "doc.richtext") {
                            exportComic(.pdf)
                        }
                        Button(AppLocalization.text("downloads.action.export_comic_epub", "Export Comic EPUB"), systemImage: "books.vertical") {
                            exportComic(.epub)
                        }
                        Button(AppLocalization.text("downloads.action.export_latest_chapter_cbz", "Export Latest Chapter CBZ"), systemImage: "book.closed") {
                            exportChapter(latestReadableChapter, format: .cbz)
                        }
                        Button(AppLocalization.text("downloads.action.export_latest_chapter_zip", "Export Latest Chapter ZIP"), systemImage: "doc.zipper") {
                            exportChapter(latestReadableChapter, format: .zip)
                        }
                        Button(AppLocalization.text("downloads.action.export_latest_chapter_pdf", "Export Latest Chapter PDF"), systemImage: "doc.richtext") {
                            exportChapter(latestReadableChapter, format: .pdf)
                        }
                        Button(AppLocalization.text("downloads.action.export_latest_chapter_epub", "Export Latest Chapter EPUB"), systemImage: "books.vertical") {
                            exportChapter(latestReadableChapter, format: .epub)
                        }
                    } label: {
                        if exportTarget == "comic" {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 44, height: 44)
                        } else {
                            Label(AppLocalization.text("downloads.action.export", "Export"), systemImage: "square.and.arrow.up")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(exportTarget != nil)
                }
            }
        }
        .appCardStyle()
    }

    private var readingSummaryCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Text(AppLocalization.text("downloads.offline.reading.title", "Offline Reading"))
                .font(.headline)
            Text(
                incompleteCount == 0
                ? AppLocalization.text("downloads.offline.reading.ready_message", "All downloaded chapters are ready for offline reading.")
                : AppLocalization.text("downloads.offline.reading.incomplete_message", "Incomplete chapters are separated below so readable chapters stay easy to access.")
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .appCardStyle()
    }

    private var completeChaptersSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AppLocalization.text("downloads.offline.ready_to_read", "Ready to Read"))
                .font(.headline)

            VStack(spacing: AppSpacing.sm) {
                ForEach(sortedReaderChapters) { item in
                    NavigationLink {
                        ReaderRoutingView(
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
                            chapterSequence: chapterSequence
                        )
                        .environment(library)
                    } label: {
                        OfflineReadableChapterRow(
                            item: item,
                            isLatest: item.id == latestReadableChapter?.id,
                            onOpenFiles: { selectedFilesItem = item },
                            onExportCBZ: { exportChapter(item, format: .cbz) },
                            onExportZIP: { exportChapter(item, format: .zip) },
                            onExportPDF: { exportChapter(item, format: .pdf) },
                            onExportEPUB: { exportChapter(item, format: .epub) },
                            isExporting: exportTarget == item.chapterID
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var incompleteChaptersSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(AppLocalization.text("downloads.needs_review", "Needs Review"))
                .font(.headline)

            VStack(spacing: AppSpacing.sm) {
                ForEach(incompleteChapters) { item in
                    OfflineRepairChapterRow(item: item) {
                        selectedFilesItem = item
                    }
                }
            }
        }
    }

    private var flexibleBadges: some View {
        HStack(spacing: 8) {
            badge(text: AppLocalization.format("downloads.metric.chapters_count", "%lld chapters", Int64(group.chapters.count)), tint: AppTint.accent)
            badge(text: AppLocalization.format("downloads.metric.ready_count", "%lld ready", Int64(completeCount)), tint: AppTint.success)
            if isImportedGroup {
                badge(text: AppLocalization.text("downloads.badge.imported", "imported"), tint: AppTint.warning)
            }
            if incompleteCount > 0 {
                badge(text: AppLocalization.format("downloads.metric.incomplete_count", "%lld incomplete", Int64(incompleteCount)), tint: AppTint.warning)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AppLocalization.format(
                "downloads.offline.summary_accessibility",
                "%lld chapters, %lld ready offline, %lld incomplete",
                Int64(group.chapters.count),
                Int64(completeCount),
                Int64(incompleteCount)
            )
        )
    }

    private func badge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func exportComic(_ format: OfflineExportFormat) {
        guard exportTarget == nil else { return }
        exportTarget = "comic"
        Task {
            defer { exportTarget = nil }
            do {
                let url = try OfflineExportService().exportComic(group: group, format: format)
                sharedExportURL = ShareFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func exportChapter(_ item: OfflineChapterAsset, format: OfflineExportFormat) {
        guard exportTarget == nil else { return }
        exportTarget = item.chapterID
        Task {
            defer { exportTarget = nil }
            do {
                let url = try OfflineExportService().exportChapter(item, format: format)
                sharedExportURL = ShareFile(url: url)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }
}

@MainActor
private struct OfflineReadableChapterRow: View {
    let item: OfflineChapterAsset
    let isLatest: Bool
    let onOpenFiles: () -> Void
    let onExportCBZ: () -> Void
    let onExportZIP: () -> Void
    let onExportPDF: () -> Void
    let onExportEPUB: () -> Void
    let isExporting: Bool

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.chapterTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isLatest {
                        Text(AppLocalization.text("downloads.badge.latest", "Latest"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTint.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTint.accent.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Label(AppLocalization.text("downloads.badge.offline_ready", "Offline Ready"), systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTint.success)

                    Text(AppLocalization.format("downloads.files.page_count", "%lld/%lld pages", Int64(item.verifiedPageCount), Int64(item.pageCount)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button(AppLocalization.text("downloads.action.view_files", "View Files"), systemImage: "folder") {
                    onOpenFiles()
                }
                Button(AppLocalization.text("downloads.action.export_cbz", "Export CBZ"), systemImage: "book.closed") {
                    onExportCBZ()
                }
                Button(AppLocalization.text("downloads.action.export_zip", "Export ZIP"), systemImage: "doc.zipper") {
                    onExportZIP()
                }
                Button(AppLocalization.text("downloads.action.export_pdf", "Export PDF"), systemImage: "doc.richtext") {
                    onExportPDF()
                }
                Button(AppLocalization.text("downloads.action.export_epub", "Export EPUB"), systemImage: "books.vertical") {
                    onExportEPUB()
                }
            } label: {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Label(AppLocalization.text("common.options", "Options"), systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 12)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous)
                .strokeBorder(AppSurface.border)
        }
    }
}

private struct OfflineRepairChapterRow: View {
    let item: OfflineChapterAsset
    let onOpenFiles: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.chapterTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(item.integrityStatus.title, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTint.warning)

                    Text(AppLocalization.format("downloads.files.page_count", "%lld/%lld pages", Int64(item.verifiedPageCount), Int64(item.pageCount)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button(AppLocalization.text("downloads.action.view_files", "View Files")) {
                onOpenFiles()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, 12)
        .background(AppSurface.elevated, in: RoundedRectangle(cornerRadius: AppRadius.md, style: .continuous))
    }
}
