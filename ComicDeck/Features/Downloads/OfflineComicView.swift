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
        .navigationBarTitleDisplayMode(.inline)
        .background(AppSurface.grouped.ignoresSafeArea())
        .sheet(item: $sharedExportURL) { shareFile in
            ActivityShareSheet(items: [shareFile.url])
        }
        .alert("Rename Imported Comic", isPresented: $showingRenamePrompt) {
            TextField("Comic Title", text: $renameTitle)
            Button("Save") {
                Task {
                    await library.renameImportedOfflineComic(
                        sourceKey: OfflineImportService.importedSourceKey,
                        comicID: group.comicID,
                        to: renameTitle
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only renames the imported offline entry in ComicDeck.")
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unable to export offline files.")
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
                        ComicReaderView(
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
                    } label: {
                        Label("Resume Offline", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Menu {
                        if isImportedGroup {
                            Button("Rename Imported Comic", systemImage: "pencil") {
                                renameTitle = group.comicTitle
                                showingRenamePrompt = true
                            }
                        }
                        Button("Export Comic ZIP", systemImage: "archivebox") {
                            exportComic(.zip)
                        }
                        Button("Export Comic PDF", systemImage: "doc.richtext") {
                            exportComic(.pdf)
                        }
                        Button("Export Comic EPUB", systemImage: "books.vertical") {
                            exportComic(.epub)
                        }
                        Button("Export Latest Chapter CBZ", systemImage: "book.closed") {
                            exportChapter(latestReadableChapter, format: .cbz)
                        }
                        Button("Export Latest Chapter ZIP", systemImage: "doc.zipper") {
                            exportChapter(latestReadableChapter, format: .zip)
                        }
                        Button("Export Latest Chapter PDF", systemImage: "doc.richtext") {
                            exportChapter(latestReadableChapter, format: .pdf)
                        }
                        Button("Export Latest Chapter EPUB", systemImage: "books.vertical") {
                            exportChapter(latestReadableChapter, format: .epub)
                        }
                    } label: {
                        if exportTarget == "comic" {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 44, height: 44)
                        } else {
                            Label("Export", systemImage: "square.and.arrow.up")
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
            Text("Offline Reading")
                .font(.headline)
            Text(
                incompleteCount == 0
                ? "All downloaded chapters are ready for offline reading."
                : "Incomplete chapters are separated below so readable chapters stay easy to access."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .appCardStyle()
    }

    private var completeChaptersSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Ready to Read")
                .font(.headline)

            VStack(spacing: AppSpacing.sm) {
                ForEach(sortedReaderChapters) { item in
                    NavigationLink {
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
                            chapterSequence: chapterSequence
                        )
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
            Text("Needs Attention")
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
            badge(text: "\(group.chapters.count) chapters", tint: AppTint.accent)
            badge(text: "\(completeCount) ready", tint: AppTint.success)
            if isImportedGroup {
                badge(text: "Imported", tint: AppTint.warning)
            }
            if incompleteCount > 0 {
                badge(text: "\(incompleteCount) incomplete", tint: AppTint.warning)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.chapters.count) chapters, \(completeCount) ready offline, \(incompleteCount) incomplete")
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

private func offlineComicCoverURL(from chapters: [OfflineChapterAsset]) -> URL? {
    guard let anyChapter = chapters.first else { return nil }
    let comicDirectory = URL(fileURLWithPath: anyChapter.directoryPath).deletingLastPathComponent()
    let supported = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif"]
    return supported
        .map { comicDirectory.appendingPathComponent("cover.\($0)") }
        .first { FileManager.default.fileExists(atPath: $0.path) }
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
                        Text("Latest")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTint.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTint.accent.opacity(0.12), in: Capsule())
                    }
                }

                HStack(spacing: 8) {
                    Label("Offline Ready", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTint.success)

                    Text("\(item.verifiedPageCount)/\(item.pageCount) pages")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Menu {
                Button("View Files", systemImage: "folder") {
                    onOpenFiles()
                }
                Button("Export CBZ", systemImage: "book.closed") {
                    onExportCBZ()
                }
                Button("Export ZIP", systemImage: "doc.zipper") {
                    onExportZIP()
                }
                Button("Export PDF", systemImage: "doc.richtext") {
                    onExportPDF()
                }
                Button("Export EPUB", systemImage: "books.vertical") {
                    onExportEPUB()
                }
            } label: {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                } else {
                    Label("Options", systemImage: "ellipsis.circle")
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

                    Text("\(item.verifiedPageCount)/\(item.pageCount) pages")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button("View Files") {
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
