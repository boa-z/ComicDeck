import SwiftUI
import UIKit
import CryptoKit

enum ReaderLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
func readerDebugLog(_ message: String, level: ReaderLogLevel = .debug) {
    guard RuntimeDebugConsole.isEnabled else { return }
    let line = "[SourceRuntime][\(level.rawValue)][Reader] \(message)"
    NSLog("%@", line)
    RuntimeDebugConsole.shared.append(line)
}

enum ReaderMode: String, CaseIterable, Identifiable {
    case ltr
    case rtl
    case vertical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ltr: return AppLocalization.text("reader.mode.ltr", "LTR")
        case .rtl: return AppLocalization.text("reader.mode.rtl", "RTL")
        case .vertical: return AppLocalization.text("reader.mode.vertical", "Vertical")
        }
    }

    var icon: String {
        switch self {
        case .ltr: return "textformat.size"
        case .rtl: return "textformat.size.larger"
        case .vertical: return "rectangle.split.1x2"
        }
    }
}

enum ReaderBackgroundMode: String, CaseIterable, Identifiable {
    case system
    case auto
    case white
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return AppLocalization.text("reader.background.system", "System")
        case .auto: return AppLocalization.text("reader.background.auto", "Auto")
        case .white: return AppLocalization.text("reader.background.white", "White")
        case .black: return AppLocalization.text("reader.background.black", "Black")
        }
    }
}

enum TapZonePreset: String, CaseIterable, Identifiable {
    case auto
    case leftRight = "left-right"
    case lShaped = "l-shaped"
    case kindle
    case edge
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return AppLocalization.text("reader.tap.auto", "Automatic")
        case .leftRight: return AppLocalization.text("reader.tap.left_right", "Left/Right")
        case .lShaped: return AppLocalization.text("reader.tap.l_shaped", "L-shaped")
        case .kindle: return AppLocalization.text("reader.tap.kindle", "Kindle")
        case .edge: return AppLocalization.text("reader.tap.edge", "Edge")
        case .disabled: return AppLocalization.text("reader.tap.disabled", "Disabled")
        }
    }
}

private enum TapAction {
    case previous
    case next
    case toggleControls
}

private struct TapZoneRegion {
    let rect: CGRect
    let action: TapAction
}

@MainActor
struct ComicReaderView: View {
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
    @AppStorage("reader_invert_tap_zones") private var invertTapZones = false
    @AppStorage("reader_preload_distance") private var preloadDistance = 2
    @AppStorage("Reader.tapZones") private var tapZonePresetRaw = TapZonePreset.auto.rawValue
    @AppStorage("Reader.animatePageTransitions") private var animatePageTransitions = true
    @AppStorage("Reader.backgroundColor") private var readerBackgroundRaw = ReaderBackgroundMode.system.rawValue
    @AppStorage("Reader.keepScreenOn") private var keepScreenOn = true

    @State private var debugConsole = RuntimeDebugConsole.shared
    @State private var session: ReaderSession
    @State private var showSettings = false
    @State private var historySaveTask: Task<Void, Never>? = nil
    @FocusState private var isReaderFocused: Bool

    private let prefetcher = ReaderImagePrefetcher.shared

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

    private var tapZonePreset: TapZonePreset {
        get { TapZonePreset(rawValue: tapZonePresetRaw) ?? .auto }
        nonmutating set { tapZonePresetRaw = newValue.rawValue }
    }

    private var readerBackgroundMode: ReaderBackgroundMode {
        get { ReaderBackgroundMode(rawValue: readerBackgroundRaw) ?? .system }
        nonmutating set { readerBackgroundRaw = newValue.rawValue }
    }

    private var resolvedReaderBackground: Color {
        switch readerBackgroundMode {
        case .white:
            return .white
        case .black:
            return .black
        case .auto:
            return readerMode == .vertical ? .black : Color(uiColor: .systemBackground)
        case .system:
            return Color(uiColor: .systemBackground)
        }
    }

    private var displayedPageIndex: Int {
        session.displayedPageIndex(readerMode: readerMode)
    }

    private var isOfflineReading: Bool {
        session.isOfflineReading
    }

    var body: some View {
        ZStack {
            resolvedReaderBackground.ignoresSafeArea()

            if session.loading {
                VStack(spacing: 10) {
                    ProgressView(value: session.loadingProgress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .padding(.horizontal, 28)
                    Text(session.loadingMessage)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                    if RuntimeDebugConsole.isEnabled {
                        DebugLogPanel(lines: Array(debugConsole.lines.suffix(20)))
                            .padding(.horizontal, 14)
                    }
                }
            } else if !session.errorText.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: isOfflineReading ? "externaldrive.badge.exclamationmark" : "wifi.exclamationmark")
                        .font(.system(size: 28))
                        .foregroundStyle(isOfflineReading ? .orange : .red)
                    Text(session.errorText).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                    if isOfflineReading {
                        Text(AppLocalization.text("reader.error.offline_mode", "Offline mode only. Network fallback is disabled for downloaded chapters."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 12) {
                        Button(AppLocalization.text("common.back", "Back")) {
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint(AppLocalization.text("common.accessibility.back", "Return to the previous screen"))

                        Button(AppLocalization.text("common.retry", "Retry")) { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            } else if session.imageRequests.isEmpty {
                Text(AppLocalization.text("reader.error.no_images", "No images"))
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                GeometryReader { geo in
                    ZStack {
                        ReaderCanvasView(
                            imageRequests: session.imageRequests,
                            readerMode: readerMode,
                            reloadNonce: session.reloadNonce,
                            animatePageTransitions: animatePageTransitions && !reduceMotion,
                            currentPage: $session.currentPage,
                            verticalPageFrames: $session.verticalPageFrames,
                            verticalViewportHeight: $session.verticalViewportHeight,
                            verticalScrollTarget: $session.verticalScrollTarget,
                            verticalTrackingSuspendedUntil: $session.verticalTrackingSuspendedUntil,
                            onUpdateCurrentPageFromVerticalLayout: {
                                session.updateCurrentPageFromVerticalLayout(readerMode: readerMode)
                            }
                        )
                        .ignoresSafeArea()

                        if session.showControls {
                            ReaderOverlayView(
                                chapterTitle: session.chapterTitle,
                            chapterID: session.chapterID,
                            comicTitle: item.title,
                            offlineStatusText: session.offlineStatusText,
                            displayedPageIndex: displayedPageIndex,
                            totalPages: session.imageRequests.count,
                            readerMode: readerMode,
                                animatePageTransitions: animatePageTransitions && !reduceMotion,
                                currentPage: $session.currentPage,
                                previousChapterTitle: session.previousChapter?.title.isEmpty == false ? session.previousChapter?.title : session.previousChapter?.id,
                                nextChapterTitle: session.nextChapter?.title.isEmpty == false ? session.nextChapter?.title : session.nextChapter?.id,
                                onDismiss: dismiss.callAsFunction,
                                onOpenModeMenu: { readerMode = $0 },
                                onOpenSettings: { showSettings = true },
                                onReload: reloadCurrentPage,
                                onOpenPreviousChapter: openPreviousChapter,
                                onOpenNextChapter: openNextChapter,
                                onJumpToVerticalPage: { target in
                                    session.jumpToVerticalPage(target, readerMode: readerMode)
                                }
                            )
                            .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        SpatialTapGesture().onEnded { value in
                            handleTap(at: value.location, in: geo.size)
                        }
                    )
                    .animation(reduceMotion ? .none : .easeInOut(duration: 0.18), value: session.showControls)
                }
            }
        }
        .navigationBarBackButtonHidden(!session.loading)
        .toolbar(.hidden, for: .tabBar)
        .statusBarHidden(!session.showControls)
        .focusable(true)
        .focused($isReaderFocused)
        #if targetEnvironment(macCatalyst)
        .onKeyPress(.leftArrow) {
            previousPage()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            nextPage()
            return .handled
        }
        .onKeyPress(.upArrow) {
            if readerMode == .vertical {
                previousPage()
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.downArrow) {
            if readerMode == .vertical {
                nextPage()
                return .handled
            }
            return .ignored
        }
        #endif
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(
                mode: Binding(
                    get: { readerMode },
                    set: { readerMode = $0 }
                ),
                invertTapZones: $invertTapZones,
                preloadDistance: $preloadDistance,
                tapZonePreset: Binding(
                    get: { tapZonePreset },
                    set: { tapZonePreset = $0 }
                ),
                animatePageTransitions: $animatePageTransitions,
                readerBackgroundMode: Binding(
                    get: { readerBackgroundMode },
                    set: { readerBackgroundMode = $0 }
                ),
                keepScreenOn: $keepScreenOn
            )
            .presentationDetents([.medium])
        }
        .onChange(of: showSettings) { _, isPresented in
            if !isPresented {
                isReaderFocused = true
            }
        }
        .onChange(of: session.currentPage) { _, _ in
            preloadAroundCurrentPage()
            scheduleHistorySave()
        }
        .task {
            await load()
            await session.loadChapterSequenceIfNeeded(using: vm)
        }
        .onAppear {
            session.markVisible()
            isReaderFocused = true
            UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        }
        .onChange(of: keepScreenOn) { _, enabled in
            UIApplication.shared.isIdleTimerDisabled = enabled
        }
        .onDisappear {
            historySaveTask?.cancel()
            historySaveTask = nil
            Task {
                await persistHistoryNow()
                session.finishReadingSession(using: library)
            }
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func onLeftTap() {
        if invertTapZones { nextPage() } else { previousPage() }
    }

    private func onRightTap() {
        if invertTapZones { previousPage() } else { nextPage() }
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
        preloadAroundCurrentPage()
    }

    private func load() async {
        await session.load(using: vm, readerMode: readerMode)
        preloadAroundCurrentPage()
        await persistHistoryNow()
    }

    private func openPreviousChapter() {
        Task {
            await session.loadAdjacentChapter(step: -1, using: vm, library: library, readerMode: readerMode)
            preloadAroundCurrentPage()
            await persistHistoryNow()
        }
    }

    private func openNextChapter() {
        Task {
            await session.loadAdjacentChapter(step: 1, using: vm, library: library, readerMode: readerMode)
            preloadAroundCurrentPage()
            await persistHistoryNow()
        }
    }

    private func preloadAroundCurrentPage() {
        guard !session.imageRequests.isEmpty else { return }
        let distance = max(1, min(preloadDistance, 2))
        let start = max(0, session.currentPage - distance)
        let end = min(session.imageRequests.count - 1, session.currentPage + distance)
        let requests = (start...end).filter { $0 != session.currentPage }.compactMap { idx in
            buildURLRequest(from: session.imageRequests[idx])
        }
        prefetcher.preload(requests: requests)
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
        if let completion = session.completedChapterProgress(readerMode: readerMode) {
            try? await vm.tracker.syncNow(
                item,
                progress: completion.progress,
                status: completion.status,
                provider: .aniList
            )
        }
    }

    private func handleTap(at location: CGPoint, in size: CGSize) {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let x = location.x / width
        let y = location.y / height
        let point = CGPoint(x: x, y: y)

        let resolved = resolveTapZoneRegions()
        guard !resolved.isEmpty else {
            toggleControls()
            return
        }

        if let region = resolved.first(where: { $0.rect.contains(point) }) {
            switch region.action {
            case .previous:
                if invertTapZones { nextPage() } else { previousPage() }
            case .next:
                if invertTapZones { previousPage() } else { nextPage() }
            case .toggleControls:
                toggleControls()
            }
        } else {
            toggleControls()
        }
    }

    private func toggleControls() {
        if reduceMotion {
            session.showControls.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                session.showControls.toggle()
            }
        }
    }

    private func resolveTapZoneRegions() -> [TapZoneRegion] {
        let preset: TapZonePreset
        if tapZonePreset == .auto {
            preset = readerMode == .vertical ? .lShaped : .leftRight
        } else {
            preset = tapZonePreset
        }

        switch preset {
        case .disabled:
            return []
        case .leftRight:
            return [
                TapZoneRegion(rect: CGRect(x: 0, y: 0, width: 1.0/3.0, height: 1), action: .previous),
                TapZoneRegion(rect: CGRect(x: 2.0/3.0, y: 0, width: 1.0/3.0, height: 1), action: .next)
            ]
        case .lShaped:
            return [
                TapZoneRegion(rect: CGRect(x: 0, y: 1.0/3.0, width: 1.0/3.0, height: 1.0/3.0), action: .previous),
                TapZoneRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1.0/3.0), action: .previous),
                TapZoneRegion(rect: CGRect(x: 2.0/3.0, y: 1.0/3.0, width: 1.0/3.0, height: 2.0/3.0), action: .next),
                TapZoneRegion(rect: CGRect(x: 0, y: 2.0/3.0, width: 2.0/3.0, height: 1.0/3.0), action: .next)
            ]
        case .kindle:
            return [
                TapZoneRegion(rect: CGRect(x: 0, y: 1.0/3.0, width: 1.0/3.0, height: 2.0/3.0), action: .previous),
                TapZoneRegion(rect: CGRect(x: 1.0/3.0, y: 1.0/3.0, width: 2.0/3.0, height: 2.0/3.0), action: .next)
            ]
        case .edge:
            return [
                TapZoneRegion(rect: CGRect(x: 0, y: 0, width: 1.0/3.0, height: 1), action: .next),
                TapZoneRegion(rect: CGRect(x: 1.0/3.0, y: 2.0/3.0, width: 1.0/3.0, height: 1.0/3.0), action: .previous),
                TapZoneRegion(rect: CGRect(x: 2.0/3.0, y: 0, width: 1.0/3.0, height: 1), action: .next)
            ]
        case .auto:
            return []
        }
    }
}

private final class ReaderImagePrefetcher {
    static let shared = ReaderImagePrefetcher()

    private init() {}

    func preload(requests: [URLRequest]) {
        guard !requests.isEmpty else { return }
        Task(priority: .utility) {
            await ReaderImagePipeline.shared.prefetch(requests: requests)
        }
    }
}
