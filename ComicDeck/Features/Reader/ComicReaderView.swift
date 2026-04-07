import SwiftUI
import UIKit
import GameController

enum ReaderLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
nonisolated func readerDebugLog(_ message: String, level: ReaderLogLevel = .debug) {
    let line = "[SourceRuntime][\(level.rawValue)][Reader] \(message)"
    RuntimeDebugConsole.appendRuntimeLine(line)
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
    @AppStorage("Reader.translationEnabled") private var translationEnabled = false
    @AppStorage("Reader.translationTargetLanguage") private var translationTargetLanguageRaw = ReaderTranslationLanguage.chineseSimplified.rawValue

    @State private var debugConsole = RuntimeDebugConsole.shared
    @State private var session: ReaderSession
    @State private var showSettings = false
    @State private var historySaveTask: Task<Void, Never>? = nil
    @FocusState private var isReaderFocused: Bool
    @State private var keyboardDidConnectObserver: NSObjectProtocol?
    @State private var keyboardDidDisconnectObserver: NSObjectProtocol?

    private let prefetcher = ReaderImagePrefetcher.shared
    @State private var readerLoadTask: Task<Void, Never>? = nil
    @State private var chapterSequenceTask: Task<Void, Never>? = nil
    @State private var chapterNavigationTask: Task<Void, Never>? = nil
    @State private var prefetchGeneration = 0
    @State private var lastPrefetchedPage = 0

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

    private var translationTargetLanguage: ReaderTranslationLanguage {
        get { ReaderTranslationLanguage(rawValue: translationTargetLanguageRaw) ?? .chineseSimplified }
        nonmutating set { translationTargetLanguageRaw = newValue.rawValue }
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
        baseReaderView
    }

    private var baseReaderView: some View {
        readerBody
            .navigationBarBackButtonHidden(!session.loading)
            .toolbar(.hidden, for: .tabBar)
            .statusBarHidden(!session.showControls)
            .focusable(true)
            .focused($isReaderFocused)
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
                    keepScreenOn: $keepScreenOn,
                    translationEnabled: $translationEnabled,
                    translationTargetLanguage: Binding(
                        get: { translationTargetLanguage },
                        set: { translationTargetLanguage = $0 }
                    )
                )
                .presentationDetents([.medium])
            }
            .onChange(of: showSettings) { _, isPresented in
                if !isPresented {
                    isReaderFocused = true
                }
            }
            .onChange(of: readerMode) { oldMode, mode in
                guard session.totalPages > 0 else { return }
                let displayed = session.displayedPageIndex(readerMode: oldMode)
                let oneBased = max(1, min(session.totalPages, displayed))
                let ltrIndex = min(session.totalPages - 1, oneBased - 1)
                session.currentPage = mode == .rtl ? max(0, session.totalPages - 1 - ltrIndex) : ltrIndex
                if mode == .vertical {
                    session.verticalScrollTarget = session.currentPage
                }
            }
            .onChange(of: session.currentPage) { _, _ in
                session.resolvePagesAroundCurrentPage(using: vm, readerMode: readerMode)
                session.translatePagesAroundCurrentPage(using: vm, readerMode: readerMode)
                preloadAroundCurrentPage()
                scheduleHistorySave()
            }
            .task {
                prefetchGeneration = await ReaderImagePipeline.shared.beginPrefetchSession()
                lastPrefetchedPage = session.currentPage
                readerLoadTask?.cancel()
                readerLoadTask = Task {
                    await load()
                }
                chapterSequenceTask?.cancel()
                chapterSequenceTask = Task {
                    await session.loadChapterSequenceIfNeeded(using: vm)
                }
            }
            .onAppear {
                session.markVisible()
                session.applyTranslationPreferences(enabled: translationEnabled, targetLanguage: translationTargetLanguage)
                isReaderFocused = true
                UIApplication.shared.isIdleTimerDisabled = keepScreenOn
                installKeyboardMonitoring()
            }
            .onChange(of: keepScreenOn) { _, enabled in
                UIApplication.shared.isIdleTimerDisabled = enabled
            }
            .onChange(of: translationEnabled) { _, enabled in
                session.applyTranslationPreferences(enabled: enabled, targetLanguage: translationTargetLanguage)
                session.translatePagesAroundCurrentPage(using: vm, readerMode: readerMode)
            }
            .onChange(of: translationTargetLanguage) { _, language in
                session.applyTranslationPreferences(enabled: translationEnabled, targetLanguage: language)
                session.translatePagesAroundCurrentPage(using: vm, readerMode: readerMode)
            }
            .onDisappear {
                historySaveTask?.cancel()
                historySaveTask = nil
                readerLoadTask?.cancel()
                readerLoadTask = nil
                chapterSequenceTask?.cancel()
                chapterSequenceTask = nil
                chapterNavigationTask?.cancel()
                chapterNavigationTask = nil
                prefetcher.cancel()
                UIApplication.shared.isIdleTimerDisabled = false
                uninstallKeyboardMonitoring()

                let app = UIApplication.shared
                var bgTaskID: UIBackgroundTaskIdentifier = .invalid
                bgTaskID = app.beginBackgroundTask(withName: "ReaderCleanup") {
                    app.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
                Task { @MainActor in
                    await ReaderImagePipeline.shared.cancelPrefetchSession()
                    await session.close(using: vm)
                    await persistHistoryNow()
                    session.finishReadingSession(using: library)
                    app.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
    }

    private var readerBody: some View {
        ZStack {
            resolvedReaderBackground.ignoresSafeArea()
            readerContent
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        if session.loading && !session.canRenderReader {
            loadingView
        } else if !session.errorText.isEmpty {
            readerErrorView
        } else if session.totalPages == 0 {
            emptyReaderView
        } else {
            activeReaderView
        }
    }

    private var loadingView: some View {
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
    }

    private var readerErrorView: some View {
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
    }

    private var emptyReaderView: some View {
        Text(AppLocalization.text("reader.error.no_images", "No images"))
            .foregroundStyle(.white.opacity(0.75))
    }

    private var activeReaderView: some View {
        GeometryReader { geo in
            ZStack {
                readerCanvas

                if session.loading && session.canRenderReader {
                    loadingOverlay
                }

                if session.showControls {
                    readerOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SwiftUI.Color(red: 0, green: 0, blue: 0))
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    handleTap(at: value.location, in: geo.size)
                }
            )
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.18), value: session.showControls)
        }
    }

    private var readerCanvas: some View {
        ReaderCanvasView(
            imageRequests: session.imageRequests,
            readerMode: readerMode,
            reloadNonce: session.reloadNonce,
            animatePageTransitions: animatePageTransitions && !reduceMotion,
            translationEnabled: translationEnabled && readerMode == .vertical,
            translationOverlays: session.translationPageOverlays,
            currentPage: $session.currentPage,
            verticalPageFrames: $session.verticalPageFrames,
            verticalViewportHeight: $session.verticalViewportHeight,
            verticalScrollTarget: $session.verticalScrollTarget,
            verticalTrackingSuspendedUntil: $session.verticalTrackingSuspendedUntil,
            onLeftArrow: { previousPage() },
            onRightArrow: { nextPage() },
            onUpArrow: upArrowHandler,
            onDownArrow: downArrowHandler,
            onUpdateCurrentPageFromVerticalLayout: {
                session.updateCurrentPageFromVerticalLayout(readerMode: readerMode)
            }
        )
        .ignoresSafeArea()
    }

    private var upArrowHandler: (() -> Void)? {
        guard readerMode == .vertical else { return nil }
        return { previousPage() }
    }

    private var downArrowHandler: (() -> Void)? {
        guard readerMode == .vertical else { return nil }
        return { nextPage() }
    }

    private func installKeyboardMonitoring() {
        #if targetEnvironment(macCatalyst)
        attachKeyboardHandler()
        if keyboardDidConnectObserver == nil {
            keyboardDidConnectObserver = NotificationCenter.default.addObserver(
                forName: .GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    attachKeyboardHandler()
                }
            }
        }
        if keyboardDidDisconnectObserver == nil {
            keyboardDidDisconnectObserver = NotificationCenter.default.addObserver(
                forName: .GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    clearKeyboardHandler()
                }
            }
        }
        #endif
    }

    private func uninstallKeyboardMonitoring() {
        #if targetEnvironment(macCatalyst)
        clearKeyboardHandler()
        if let observer = keyboardDidConnectObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardDidConnectObserver = nil
        }
        if let observer = keyboardDidDisconnectObserver {
            NotificationCenter.default.removeObserver(observer)
            keyboardDidDisconnectObserver = nil
        }
        #endif
    }

    private func attachKeyboardHandler() {
        #if targetEnvironment(macCatalyst)
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = { _, _, keyCode, pressed in
            guard pressed else { return }
            Task { @MainActor in
                handleKeyboardKey(keyCode)
            }
        }
        #endif
    }

    private func clearKeyboardHandler() {
        #if targetEnvironment(macCatalyst)
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        #endif
    }

    private func handleKeyboardKey(_ keyCode: GCKeyCode) {
        #if targetEnvironment(macCatalyst)
        switch keyCode {
        case GCKeyCode.leftArrow, GCKeyCode.keypad4:
            previousPage()
        case GCKeyCode.rightArrow, GCKeyCode.keypad6:
            nextPage()
        case GCKeyCode.upArrow, GCKeyCode.keypad8:
            openPreviousChapter()
        case GCKeyCode.downArrow, GCKeyCode.keypad2:
            openNextChapter()
        default:
            break
        }
        #endif
    }

    private var loadingOverlay: some View {
        VStack {
            ProgressView(value: session.loadingProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(.white)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            Spacer()
        }
    }

    private var readerOverlay: some View {
        ReaderOverlayView(
            chapterTitle: session.chapterTitle,
            chapterID: session.chapterID,
            comicTitle: item.title,
            offlineStatusText: session.offlineStatusText,
            displayedPageIndex: displayedPageIndex,
            totalPages: session.totalPages,
            resolvedPageCount: session.resolvedPageCount,
            isLoadingMore: session.isLoadingMore,
            translationEnabled: translationEnabled,
            translationStatusText: translationStatusText,
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

    private var translationStatusText: String? {
        guard translationEnabled else { return nil }
        if !session.translationUnsupportedReason.isEmpty {
            return session.translationUnsupportedReason
        }
        switch session.translationStatus(for: session.currentPage) {
        case .idle:
            return AppLocalization.text("reader.translation.status.idle", "Translation idle")
        case .processing:
            return AppLocalization.text("reader.translation.status.processing", "Translating")
        case .ready:
            return AppLocalization.text("reader.translation.status.ready", "Translation ready")
        case .failed:
            return session.translationError(for: session.currentPage) ?? AppLocalization.text("reader.translation.status.failed", "Translation failed")
        case .unsupported:
            return session.translationError(for: session.currentPage) ?? AppLocalization.text("reader.translation.status.unsupported", "Translation unavailable")
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
        session.resolvePagesAroundCurrentPage(using: vm, readerMode: readerMode)
        preloadAroundCurrentPage()
    }

    private func load() async {
        await session.load(using: vm, readerMode: readerMode)
        session.applyTranslationPreferences(enabled: translationEnabled, targetLanguage: translationTargetLanguage)
        session.translatePagesAroundCurrentPage(using: vm, readerMode: readerMode)
        preloadAroundCurrentPage()
        await persistHistoryNow()
    }

    private func openPreviousChapter() {
        chapterNavigationTask?.cancel()
        chapterNavigationTask = Task {
            await session.loadAdjacentChapter(step: -1, using: vm, library: library, readerMode: readerMode)
            guard !Task.isCancelled else { return }
            preloadAroundCurrentPage()
            await persistHistoryNow()
        }
    }

    private func openNextChapter() {
        chapterNavigationTask?.cancel()
        chapterNavigationTask = Task {
            await session.loadAdjacentChapter(step: 1, using: vm, library: library, readerMode: readerMode)
            guard !Task.isCancelled else { return }
            preloadAroundCurrentPage()
            await persistHistoryNow()
        }
    }

    private func preloadAroundCurrentPage() {
        guard session.totalPages > 0 else { return }
        let distance = max(1, min(preloadDistance, 4))
        let direction = session.currentPage == lastPrefetchedPage ? 0 : (session.currentPage > lastPrefetchedPage ? 1 : -1)
        lastPrefetchedPage = session.currentPage
        let requests = preferredPrefetchIndexes(
            current: session.currentPage,
            total: session.totalPages,
            distance: distance,
            direction: direction
        )
            .compactMap { idx in session.imageRequests[idx] }
            .compactMap(buildURLRequest(from:))
        prefetcher.preload(requests: requests, generation: prefetchGeneration)
    }

    private func preferredPrefetchIndexes(current: Int, total: Int, distance: Int, direction: Int) -> [Int] {
        guard total > 0 else { return [] }
        var indexes: [Int] = []
        let forwardFirst = direction >= 0
        for step in 1...distance {
            let forward = current + step
            let backward = current - step
            if forwardFirst {
                if forward < total { indexes.append(forward) }
                if backward >= 0 { indexes.append(backward) }
            } else {
                if backward >= 0 { indexes.append(backward) }
                if forward < total { indexes.append(forward) }
            }
        }
        return indexes
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

@MainActor
private final class ReaderImagePrefetcher {
    static let shared = ReaderImagePrefetcher()

    private var prefetchTask: Task<Void, Never>?

    private init() {}

    func preload(requests: [URLRequest], generation: Int) {
        guard !requests.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task(priority: .utility) {
            await ReaderImagePipeline.shared.prefetch(requests: requests, generation: generation)
        }
    }

    func cancel() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }
}
