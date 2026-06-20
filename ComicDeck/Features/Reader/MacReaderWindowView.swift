#if os(macOS)
import SwiftUI

@MainActor
struct MacReaderWindowView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    let item: ComicSummary
    let chapterID: String
    let chapterTitle: String
    let localChapterDirectory: String?
    let initialPage: Int?
    let chapterSequence: [ComicChapter]?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reader_mode") private var readerModeRaw = ReaderMode.ltr.rawValue
    @AppStorage("Reader.animatePageTransitions") private var animatePageTransitions = true
    @AppStorage("Reader.backgroundColor") private var readerBackgroundRaw = ReaderBackgroundMode.system.rawValue

    @State private var session: ReaderSession
    @State private var verticalCoordinator = ReaderVerticalCoordinator()
    @State private var readerLoadTask: Task<Void, Never>?
    @State private var sequenceTask: Task<Void, Never>?
    @State private var navigationTask: Task<Void, Never>?
    @State private var historySaveTask: Task<Void, Never>?
    @State private var prefetchGeneration = 0
    @State private var lastPrefetchedPage = 0
    @State private var prefetcher = ReaderImagePrefetcher.shared

    init(
        vm: ReaderViewModel,
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        localChapterDirectory: String? = nil,
        initialPage: Int? = nil,
        chapterSequence: [ComicChapter]? = nil
    ) {
        self.vm = vm
        self.item = item
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.localChapterDirectory = localChapterDirectory
        self.initialPage = initialPage
        self.chapterSequence = chapterSequence
        _session = State(initialValue: ReaderSession(
            item: item,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            localChapterDirectory: localChapterDirectory,
            initialPage: initialPage,
            chapterSequence: chapterSequence
        ))
    }

    private var readerMode: ReaderMode {
        get { ReaderMode(rawValue: readerModeRaw) ?? .ltr }
        nonmutating set { readerModeRaw = newValue.rawValue }
    }

    private var readerBackgroundMode: ReaderBackgroundMode {
        get { ReaderBackgroundMode(rawValue: readerBackgroundRaw) ?? .system }
        nonmutating set { readerBackgroundRaw = newValue.rawValue }
    }

    private var resolvedBackground: Color {
        switch readerBackgroundMode {
        case .white:
            return .white
        case .black:
            return .black
        case .auto:
            return readerMode == .vertical ? .black : PlatformColors.systemBackground
        case .system:
            return PlatformColors.systemBackground
        }
    }

    private var displayedPageIndex: Int {
        session.displayedPageIndex(readerMode: readerMode)
    }

    private var normalizedDisplayedPageIndex: Int {
        guard session.totalPages > 0 else { return 0 }
        return min(max(displayedPageIndex, 1), session.totalPages)
    }

    private var progressSummaryText: String {
        AppLocalization.format(
            "reader.pages",
            "%lld/%lld pages",
            Int64(normalizedDisplayedPageIndex),
            Int64(max(session.totalPages, 0))
        )
    }

    private var progressSliderValue: Binding<Double> {
        Binding(
            get: {
                ReaderProgressSliderMapper.displayValue(
                    currentPage: session.currentPage,
                    totalPages: session.totalPages,
                    readerMode: readerMode
                )
            },
            set: { newValue in
                let targetPage = ReaderProgressSliderMapper.currentPage(
                    for: newValue,
                    totalPages: session.totalPages,
                    readerMode: readerMode
                )
                session.jumpToPage(targetPage, readerMode: readerMode)
            }
        )
    }

    var body: some View {
        ZStack {
            resolvedBackground.ignoresSafeArea()
            content
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(AppLocalization.text("common.close", "Close"), systemImage: "xmark") {
                    dismiss()
                }
            }
            ToolbarItemGroup(placement: .principal) {
                VStack(spacing: 1) {
                    Text(session.chapterTitle.isEmpty ? session.chapterID : session.chapterTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(AppLocalization.text("reader.action.previous_page", "Previous page"), systemImage: "chevron.left") {
                    previousPage()
                }
                .disabled(session.currentPage <= 0 || session.totalPages <= 0)

                Button(AppLocalization.text("reader.action.next_page", "Next page"), systemImage: "chevron.right") {
                    nextPage()
                }
                .disabled(session.totalPages <= 0 || session.currentPage >= session.totalPages - 1)

                Menu {
                    Section(AppLocalization.text("reader.chrome.mode", "Mode")) {
                        ForEach(ReaderMode.allCases) { mode in
                            Button {
                                readerMode = mode
                                verticalCoordinator.prepareForContent(currentPage: session.currentPage)
                            } label: {
                                Label(mode.title, systemImage: mode.icon)
                            }
                        }
                    }

                    Section(AppLocalization.text("reader.background.mode", "Background")) {
                        ForEach(ReaderBackgroundMode.allCases) { mode in
                            Button(mode.title) {
                                readerBackgroundMode = mode
                            }
                        }
                    }

                    Button(AppLocalization.text("reader.action.previous_chapter", "Previous chapter"), systemImage: "backward.end.fill") {
                        openAdjacentChapter(step: -1)
                    }
                    .disabled(session.previousChapter == nil)

                    Button(AppLocalization.text("reader.action.next_chapter", "Next chapter"), systemImage: "forward.end.fill") {
                        openAdjacentChapter(step: 1)
                    }
                    .disabled(session.nextChapter == nil)

                    Button(AppLocalization.text("reader.action.reload_page", "Reload current page"), systemImage: "arrow.clockwise") {
                        reloadCurrentPage()
                    }
                } label: {
                    Label(AppLocalization.text("tracking.sync.more", "More"), systemImage: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .onKeyPress(.leftArrow) { previousPage(); return .handled }
        .onKeyPress(.rightArrow) { nextPage(); return .handled }
        .onKeyPress(.upArrow) { openAdjacentChapter(step: -1); return .handled }
        .onKeyPress(.downArrow) { openAdjacentChapter(step: 1); return .handled }
        .onChange(of: session.currentPage) { _, _ in
            session.resolvePagesAroundCurrentPage(using: vm, readerMode: readerMode)
            preloadAroundCurrentPage()
            scheduleHistorySave()
        }
        .onChange(of: readerMode) { oldMode, mode in
            guard session.totalPages > 0 else { return }
            let displayed = session.displayedPageIndex(readerMode: oldMode)
            let oneBased = max(1, min(session.totalPages, displayed))
            let ltrIndex = min(session.totalPages - 1, oneBased - 1)
            session.currentPage = mode == .rtl ? max(0, session.totalPages - 1 - ltrIndex) : ltrIndex
            if mode == .vertical {
                verticalCoordinator.prepareForContent(currentPage: session.currentPage)
            }
        }
        .task {
            await start()
        }
        .onDisappear {
            stop()
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.loading && !session.canRenderReader {
            VStack(spacing: 12) {
                ProgressView(value: session.loadingProgress, total: 1)
                    .frame(width: 280)
                Text(session.loadingMessage)
                    .foregroundStyle(.secondary)
            }
        } else if !session.errorText.isEmpty {
            ContentUnavailableView {
                Label(AppLocalization.text("reader.error.title", "Reader unavailable"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(session.errorText)
            } actions: {
                Button(AppLocalization.text("common.retry", "Retry")) {
                    readerLoadTask?.cancel()
                    readerLoadTask = Task { await load() }
                }
            }
        } else if session.totalPages == 0 {
            ContentUnavailableView(AppLocalization.text("reader.error.no_images", "No images"), systemImage: "photo")
        } else {
            ReaderCanvasView(
                imageRequests: session.imageRequests,
                readerMode: readerMode,
                reloadNonce: session.reloadNonce,
                animatePageTransitions: animatePageTransitions && !reduceMotion,
                translationEnabled: false,
                translationShowOriginal: true,
                translationBlocks: [:],
                translationRenderedAssets: [:],
                resolvedPageCount: session.resolvedPageCount,
                totalPages: session.totalPages,
                isLoadingMore: session.isLoadingMore,
                reloadPageAction: { index in
                    session.jumpToPage(index, readerMode: readerMode)
                    reloadCurrentPage()
                },
                translatePageAction: nil,
                toggleTranslationAction: nil,
                onLongPressZoomStart: nil,
                onLongPressZoomEnd: nil,
                currentPage: $session.currentPage,
                verticalCoordinator: verticalCoordinator
            )
            .background(Color.black)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text(progressSummaryText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 96, alignment: .leading)

            if session.totalPages > 1 {
                Slider(
                    value: progressSliderValue,
                    in: 0...Double(session.totalPages - 1),
                    step: 1
                )
                .accessibilityLabel(AppLocalization.text("reader.progress.label", "Reading progress"))
                .accessibilityValue(progressSummaryText)
            } else {
                Capsule()
                    .fill(.secondary.opacity(0.25))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .accessibilityHidden(true)
            }

            if session.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            }

            if !session.offlineStatusText.isEmpty {
                Text(session.offlineStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func start() async {
        session.markVisible()
        verticalCoordinator.prepareForContent(currentPage: session.currentPage)
        prefetchGeneration = await ReaderImagePipeline.shared.beginPrefetchSession()
        lastPrefetchedPage = session.currentPage

        readerLoadTask?.cancel()
        readerLoadTask = Task { await load() }

        sequenceTask?.cancel()
        sequenceTask = Task {
            await session.loadChapterSequenceIfNeeded(using: vm)
        }
    }

    private func stop() {
        readerLoadTask?.cancel()
        readerLoadTask = nil
        sequenceTask?.cancel()
        sequenceTask = nil
        navigationTask?.cancel()
        navigationTask = nil
        historySaveTask?.cancel()
        historySaveTask = nil
        prefetcher.cancel()
        Task { @MainActor in
            await ReaderImagePipeline.shared.cancelPrefetchSession()
            await session.close(using: vm)
            await persistHistoryNow()
            session.finishReadingSession(using: library)
        }
    }

    private func load() async {
        await session.load(using: vm, readerMode: readerMode)
        preloadAroundCurrentPage()
        await persistHistoryNow()
    }

    private func nextPage() {
        session.nextPage(
            readerMode: readerMode,
            animatePageTransitions: animatePageTransitions,
            reduceMotion: reduceMotion
        )
    }

    private func previousPage() {
        session.previousPage(
            readerMode: readerMode,
            animatePageTransitions: animatePageTransitions,
            reduceMotion: reduceMotion
        )
    }

    private func reloadCurrentPage() {
        session.reloadCurrentPage()
        session.resolvePagesAroundCurrentPage(using: vm, readerMode: readerMode)
        preloadAroundCurrentPage()
    }

    private func openAdjacentChapter(step: Int) {
        navigationTask?.cancel()
        navigationTask = Task {
            await session.loadAdjacentChapter(step: step, using: vm, library: library, readerMode: readerMode)
            guard !Task.isCancelled else { return }
            preloadAroundCurrentPage()
            await persistHistoryNow()
        }
    }

    private func preloadAroundCurrentPage() {
        guard session.totalPages > 0 else { return }
        let direction = session.currentPage == lastPrefetchedPage ? 0 : (session.currentPage > lastPrefetchedPage ? 1 : -1)
        lastPrefetchedPage = session.currentPage
        let requests = ReaderPrefetchPlanner.preferredPrefetchIndexes(
            current: session.currentPage,
            total: session.totalPages,
            distance: 2,
            direction: direction
        )
            .compactMap { idx in session.imageRequests[idx] }
            .compactMap(buildURLRequest(from:))
        prefetcher.preload(requests: requests, generation: prefetchGeneration)
    }

    private func scheduleHistorySave() {
        historySaveTask?.cancel()
        historySaveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await persistHistoryNow()
        }
    }

    private func persistHistoryNow() async {
        await session.persistHistory(using: library, readerMode: readerMode)
        if session.completedChapterProgress(readerMode: readerMode) != nil {
            await vm.tracker.recordChapterCompletion(
                item: item,
                chapterSequence: session.chapterSequence,
                chapterID: session.chapterID
            )
        }
    }
}
#endif
