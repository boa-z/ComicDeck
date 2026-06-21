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

    @State private var controller: ReaderController
    @State private var verticalCoordinator = ReaderVerticalCoordinator()

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
        _controller = State(initialValue: ReaderController(
            vm: vm, item: item, chapterID: chapterID, chapterTitle: chapterTitle,
            localChapterDirectory: localChapterDirectory, initialPage: initialPage,
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
        controller.session.displayedPageIndex(readerMode: readerMode)
    }

    private var normalizedDisplayedPageIndex: Int {
        guard controller.session.totalPages > 0 else { return 0 }
        return min(max(displayedPageIndex, 1), controller.session.totalPages)
    }

    private var progressSummaryText: String {
        AppLocalization.format(
            "reader.pages",
            "%lld/%lld pages",
            Int64(normalizedDisplayedPageIndex),
            Int64(max(controller.session.totalPages, 0))
        )
    }

    private var progressSliderValue: Binding<Double> {
        Binding(
            get: {
                ReaderProgressSliderMapper.displayValue(
                    currentPage: controller.session.currentPage,
                    totalPages: controller.session.totalPages,
                    readerMode: readerMode
                )
            },
            set: { newValue in
                let targetPage = ReaderProgressSliderMapper.currentPage(
                    for: newValue,
                    totalPages: controller.session.totalPages,
                    readerMode: readerMode
                )
                controller.session.jumpToPage(targetPage, readerMode: readerMode)
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
                    Text(controller.session.chapterTitle.isEmpty ? controller.session.chapterID : controller.session.chapterTitle)
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
                    controller.previousPage()
                }
                .disabled(controller.session.currentPage <= 0 || controller.session.totalPages <= 0)
                .help(AppLocalization.text("reader.action.previous_page", "Previous page"))

                Button(AppLocalization.text("reader.action.next_page", "Next page"), systemImage: "chevron.right") {
                    controller.nextPage()
                }
                .disabled(controller.session.totalPages <= 0 || controller.session.currentPage >= controller.session.totalPages - 1)
                .help(AppLocalization.text("reader.action.next_page", "Next page"))

                Divider()

                Button(AppLocalization.text("reader.action.previous_chapter", "Previous chapter"), systemImage: "backward.end.fill") {
                    controller.openAdjacentChapter(step: -1)
                }
                .disabled(controller.session.previousChapter == nil)
                .help(AppLocalization.text("reader.action.previous_chapter", "Previous chapter"))

                Button(AppLocalization.text("reader.action.next_chapter", "Next chapter"), systemImage: "forward.end.fill") {
                    controller.openAdjacentChapter(step: 1)
                }
                .disabled(controller.session.nextChapter == nil)
                .help(AppLocalization.text("reader.action.next_chapter", "Next chapter"))

                Divider()

                Button(AppLocalization.text("reader.action.reload_page", "Reload current page"), systemImage: "arrow.clockwise") {
                    controller.reloadCurrentPage()
                }
                .help(AppLocalization.text("reader.action.reload_page", "Reload current page"))

                Menu {
                    Section(AppLocalization.text("reader.chrome.mode", "Mode")) {
                        ForEach(ReaderMode.allCases) { mode in
                            Button {
                                readerMode = mode
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
                } label: {
                    Label(AppLocalization.text("tracking.sync.more", "More"), systemImage: "ellipsis.circle")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .onKeyPress(.leftArrow) { controller.previousPage(); return .handled }
        .onKeyPress(.rightArrow) { controller.nextPage(); return .handled }
        .onKeyPress(.upArrow) { controller.openAdjacentChapter(step: -1); return .handled }
        .onKeyPress(.downArrow) { controller.openAdjacentChapter(step: 1); return .handled }
        .onChange(of: controller.session.currentPage) { _, _ in
            controller.handleCurrentPageChange()
        }
        .onChange(of: readerMode) { oldMode, mode in
            let _ = controller.handleReaderModeChange(old: oldMode, new: mode)
            if mode == .vertical {
                verticalCoordinator.prepareForContent(currentPage: controller.session.currentPage)
            }
        }
        .task {
            controller.readerMode = readerMode
            controller.animatePageTransitions = animatePageTransitions
            controller.reduceMotion = reduceMotion
            controller.preloadDistance = 2
            await controller.start()
            verticalCoordinator.prepareForContent(currentPage: controller.session.currentPage)
        }
        .onDisappear {
            controller.stop()
            Task { await controller.cleanupAfterStop() }
        }
        .focusedSceneValue(\.readerController, controller)
    }

    @ViewBuilder
    private var content: some View {
        if controller.session.loading && !controller.session.canRenderReader {
            VStack(spacing: 12) {
                ProgressView(value: controller.session.loadingProgress, total: 1)
                    .frame(width: 280)
                Text(controller.session.loadingMessage)
                    .foregroundStyle(.secondary)
            }
        } else if !controller.session.errorText.isEmpty {
            ContentUnavailableView {
                Label(AppLocalization.text("reader.error.title", "Reader unavailable"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(controller.session.errorText)
            } actions: {
                Button(AppLocalization.text("common.retry", "Retry")) {
                    controller.retryLoad()
                }
            }
        } else if controller.session.totalPages == 0 {
            ContentUnavailableView(AppLocalization.text("reader.error.no_images", "No images"), systemImage: "photo")
        } else {
            ReaderCanvasView(
                imageRequests: controller.session.imageRequests,
                readerMode: readerMode,
                reloadNonce: controller.session.reloadNonce,
                animatePageTransitions: animatePageTransitions && !reduceMotion,
                translationEnabled: false,
                translationShowOriginal: true,
                translationBlocks: [:],
                translationRenderedAssets: [:],
                resolvedPageCount: controller.session.resolvedPageCount,
                totalPages: controller.session.totalPages,
                isLoadingMore: controller.session.isLoadingMore,
                reloadPageAction: { index in
                    controller.session.jumpToPage(index, readerMode: readerMode)
                    controller.reloadCurrentPage()
                },
                translatePageAction: nil,
                toggleTranslationAction: nil,
                onLongPressZoomStart: nil,
                onLongPressZoomEnd: nil,
                currentPage: $controller.session.currentPage,
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

            if controller.session.totalPages > 1 {
                Slider(
                    value: progressSliderValue,
                    in: 0...Double(controller.session.totalPages - 1),
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

            if controller.session.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
            }

            if !controller.session.offlineStatusText.isEmpty {
                Text(controller.session.offlineStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}
#endif
