import SwiftUI
import UIKit
import Photos
import GameController

private enum TapAction {
    case previous
    case next
    case toggleControls
}

private struct TapZoneRegion {
    let rect: CGRect
    let action: TapAction
}

private enum ReaderPageExportError: LocalizedError {
    case currentPageUnavailable
    case invalidImageRequest
    case imageDecodeFailed
    case photoPermissionDenied
    case imageWriteFailed

    var errorDescription: String? {
        switch self {
        case .currentPageUnavailable:
            return AppLocalization.text("reader.export.current_page_unavailable", "Current page is still preparing. Try again in a moment.")
        case .invalidImageRequest:
            return AppLocalization.text("reader.error.invalid_image_request", "Invalid image request")
        case .imageDecodeFailed:
            return AppLocalization.text("reader.error.image_load_failed", "Failed to load image")
        case .photoPermissionDenied:
            return AppLocalization.text("reader.export.photo_permission_denied", "Photo library access was denied.")
        case .imageWriteFailed:
            return AppLocalization.text("reader.export.image_write_failed", "Could not write the page image.")
        }
    }
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
    @AppStorage("Reader.tapTurnMargin") private var tapTurnMargin = 0.30
    @AppStorage("Reader.animatePageTransitions") private var animatePageTransitions = true
    @AppStorage("Reader.backgroundColor") private var readerBackgroundRaw = ReaderBackgroundMode.system.rawValue
    @AppStorage("Reader.keepScreenOn") private var keepScreenOn = true
    @AppStorage("Translation.enabled") private var translationEnabled = false
    @AppStorage("Translation.backend") private var translationBackendRaw = ReaderTranslationBackendKind.builtIn.rawValue
    @AppStorage("Translation.koharuBaseURL") private var translationKoharuBaseURL = ""
    @AppStorage("Translation.requestTimeoutSeconds") private var translationRequestTimeoutSeconds = 60
    @AppStorage("Translation.koharuLLMMode") private var translationKoharuLLMModeRaw = ReaderKoharuLLMMode.serverDefault.rawValue
    @AppStorage("Translation.koharuLLMProviderID") private var translationKoharuLLMProviderID = ""
    @AppStorage("Translation.koharuLLMModelID") private var translationKoharuLLMModelID = ""
    @AppStorage("Translation.koharuLLMTemperature") private var translationKoharuLLMTemperatureRaw = ""
    @AppStorage("Translation.koharuLLMMaxTokens") private var translationKoharuLLMMaxTokensRaw = ""
    @AppStorage("Translation.koharuLLMSystemPrompt") private var translationKoharuLLMSystemPrompt = ""
    @AppStorage("Translation.sourceLanguage") private var translationSourceLanguageRaw = ""
    @AppStorage("Translation.targetLanguage") private var translationTargetLanguageRaw = ReaderTranslationLanguage.chineseSimplified.rawValue

    @State private var debugConsole = RuntimeDebugConsole.shared
    @State private var session: ReaderSession
    @State private var verticalCoordinator = ReaderVerticalCoordinator()
    @State private var showSettings = false
    @State private var historySaveTask: Task<Void, Never>? = nil
    @FocusState private var isReaderFocused: Bool
    @State private var keyboardDidConnectObserver: NSObjectProtocol?
    @State private var keyboardDidDisconnectObserver: NSObjectProtocol?
    @State private var memoryPressureObserver: NSObjectProtocol?
    @State private var isLongPressZoomed = false
    @State private var sharedPageExport: ShareFile?
    @State private var pageExportInProgress = false
    @State private var pageExportError: String?
    @State private var pageExportSuccessMessage: String?

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

    private var clampedTapTurnMargin: Double {
        min(max(tapTurnMargin, 0.20), 0.45)
    }

    private var translationBackendKind: ReaderTranslationBackendKind {
        currentTranslationPreferences.backendConfiguration.kind
    }

    private var translationTargetLanguage: ReaderTranslationLanguage {
        currentTranslationPreferences.targetLanguage
    }

    private var currentTranslationPreferences: ReaderTranslationPreferences {
        ReaderTranslationPreferences.fromStorage(
            enabled: translationEnabled,
            backendRaw: translationBackendRaw,
            koharuBaseURL: translationKoharuBaseURL,
            requestTimeoutSeconds: translationRequestTimeoutSeconds,
            koharuLLMModeRaw: translationKoharuLLMModeRaw,
            koharuLLMProviderID: translationKoharuLLMProviderID,
            koharuLLMModelID: translationKoharuLLMModelID,
            koharuLLMTemperatureRaw: translationKoharuLLMTemperatureRaw,
            koharuLLMMaxTokensRaw: translationKoharuLLMMaxTokensRaw,
            koharuLLMSystemPrompt: translationKoharuLLMSystemPrompt,
            sourceLanguageRaw: translationSourceLanguageRaw,
            targetLanguageRaw: translationTargetLanguageRaw
        )
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
        translationPreferenceObservingView(
            lifecycleWrappedReaderView(baseReaderContent)
        )
    }

    private var baseReaderContent: some View {
        readerBody
            .navigationBarBackButtonHidden(!session.loading)
            .toolbar(.hidden, for: .tabBar)
            .statusBarHidden(!session.showControls)
            .focusable(true)
            .focused($isReaderFocused)
            .sheet(item: $sharedPageExport) { shareFile in
                ActivityShareSheet(items: [shareFile.url])
            }
            .alert(
                AppLocalization.text("reader.export.failed", "Could not export page"),
                isPresented: Binding(
                    get: { pageExportError != nil },
                    set: { if !$0 { pageExportError = nil } }
                )
            ) {
                Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(pageExportError ?? "")
            }
            .alert(
                AppLocalization.text("reader.export.saved", "Saved current page"),
                isPresented: Binding(
                    get: { pageExportSuccessMessage != nil },
                    set: { if !$0 { pageExportSuccessMessage = nil } }
                )
            ) {
                Button(AppLocalization.text("common.ok", "OK"), role: .cancel) {}
            } message: {
                Text(pageExportSuccessMessage ?? "")
            }
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
                    tapTurnMargin: Binding(
                        get: { clampedTapTurnMargin },
                        set: { tapTurnMargin = min(max($0, 0.20), 0.45) }
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
    }

    private func lifecycleWrappedReaderView<Content: View>(_ content: Content) -> some View {
        content
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
                    verticalCoordinator.prepareForContent(currentPage: session.currentPage)
                }
            }
            .onChange(of: session.currentPage) { _, _ in
                session.resolvePagesAroundCurrentPage(using: vm, readerMode: readerMode)
                preloadAroundCurrentPage()
                scheduleHistorySave()
            }
            .task {
                await handleInitialTask()
            }
            .onAppear {
                session.markVisible()
                applyCurrentTranslationPreferences()
                isReaderFocused = true
                UIApplication.shared.isIdleTimerDisabled = keepScreenOn
                installKeyboardMonitoring()
                installMemoryPressureMonitoring()
            }
            .onChange(of: keepScreenOn) { _, enabled in
                UIApplication.shared.isIdleTimerDisabled = enabled
            }
            .onDisappear {
                handleDisappear()
            }
    }

    private func translationPreferenceObservingView<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: currentTranslationPreferences) { _, _ in
                applyCurrentTranslationPreferences()
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
            .readerGestureInteraction(
                ReaderGestureInteractionConfiguration(
                    readerMode: readerMode,
                    tapZonePreset: tapZonePreset,
                    invertTapZones: invertTapZones,
                    isZoomed: isLongPressZoomed,
                    isInteractingWithControls: false,
                    controlsVisible: session.showControls,
                    onSingleTap: { location, size in
                        handleTap(at: location, in: geo.size)
                    }
                )
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
            translationEnabled: translationEnabled,
            translationShowOriginal: session.translationShowOriginal,
            translationBlocks: session.translationPageBlocks,
            translationRenderedAssets: session.translationRenderedAssets,
            resolvedPageCount: session.resolvedPageCount,
            totalPages: session.totalPages,
            isLoadingMore: session.isLoadingMore,
            reloadPageAction: { index in
                session.jumpToPage(index, readerMode: readerMode)
                reloadCurrentPage()
            },
            translatePageAction: translationEnabled ? { _ in
                session.translateCurrentPage(using: vm)
            } : nil,
            toggleTranslationAction: translationEnabled ? {
                session.toggleTranslationShowOriginal()
            } : nil,
            onLongPressZoomStart: { _ in
                isLongPressZoomed = true
            },
            onLongPressZoomEnd: {
                isLongPressZoomed = false
            },
            currentPage: $session.currentPage,
            verticalCoordinator: verticalCoordinator
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

    private func installMemoryPressureMonitoring() {
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                verticalCoordinator.clearTrackedFrames()
                ReaderDecodedImageStore.shared.trim()
                await ReaderImagePipeline.shared.clearAllCache()
                readerDebugLog("memory pressure: trimmed all caches", level: .warn)
            }
        }
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
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
            memoryPressureObserver = nil
        }
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
        VStack(spacing: 6) {
            ProgressView(value: session.loadingProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(.white)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            Text(session.loadingMessage)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
            if session.totalPages > 0, session.resolvedPageCount < session.totalPages || session.isLoadingMore {
                Text(AppLocalization.format(
                    "reader.loading.pages_ready",
                    "%lld/%lld pages ready",
                    Int64(session.resolvedPageCount),
                    Int64(session.totalPages)
                ))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.52))
            }
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
            translationShowOriginal: session.translationShowOriginal,
            translationStatusText: translationStatusText,
            isTranslatingCurrentPage: session.translationStatus(for: session.currentPage) == .processing,
            onTranslateCurrentPage: translationEnabled ? { session.translateCurrentPage(using: vm) } : nil,
            onToggleTranslationShowOriginal: translationEnabled ? { session.toggleTranslationShowOriginal() } : nil,
            translationBackendKind: translationBackendKind,
            readerMode: readerMode,
            animatePageTransitions: animatePageTransitions && !reduceMotion,
            currentPage: $session.currentPage,
            previousChapterTitle: session.previousChapter?.title.isEmpty == false ? session.previousChapter?.title : session.previousChapter?.id,
            nextChapterTitle: session.nextChapter?.title.isEmpty == false ? session.nextChapter?.title : session.nextChapter?.id,
            onDismiss: dismiss.callAsFunction,
            onOpenModeMenu: { readerMode = $0 },
            onOpenSettings: { showSettings = true },
            onReload: reloadCurrentPage,
            onShareCurrentPage: shareCurrentPage,
            onSaveCurrentPage: saveCurrentPageToPhotos,
            isExportingCurrentPage: pageExportInProgress,
            onOpenPreviousChapter: openPreviousChapter,
            onOpenNextChapter: openNextChapter,
            onJumpToVerticalPage: { target in
                session.jumpToPage(target, readerMode: readerMode)
                _ = verticalCoordinator.scrollToPage(target, totalPages: session.totalPages)
            }
        )
        .transition(.opacity)
    }

    private var translationStatusText: String? {
        guard translationEnabled else { return nil }
        if !session.translationUnsupportedReason.isEmpty {
            return session.translationUnsupportedReason
        }
        let currentPage = session.currentPage
        let status = session.translationStatus(for: currentPage)
        if status == .ready, session.translationBlocks(for: currentPage).isEmpty {
            return AppLocalization.text("reader.translation.status.ready_empty", "Translation ready, but no text regions were found")
        }
        switch status {
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

    private func shareCurrentPage() {
        guard !pageExportInProgress else { return }
        pageExportInProgress = true
        Task { @MainActor in
            defer { pageExportInProgress = false }
            do {
                let image = try await makeCurrentPageExportImage()
                let url = try writeTemporaryPageExport(image)
                sharedPageExport = ShareFile(url: url)
            } catch {
                pageExportError = error.localizedDescription
            }
        }
    }

    private func saveCurrentPageToPhotos() {
        guard !pageExportInProgress else { return }
        pageExportInProgress = true
        Task { @MainActor in
            defer { pageExportInProgress = false }
            do {
                let image = try await makeCurrentPageExportImage()
                let url = try writeTemporaryPageExport(image)
                try await saveImageToPhotos(at: url)
                pageExportSuccessMessage = AppLocalization.text("reader.export.saved", "Saved current page")
            } catch {
                pageExportError = error.localizedDescription
            }
        }
    }

    private func makeCurrentPageExportImage() async throws -> UIImage {
        let pageIndex = session.currentPage
        guard session.imageRequests.indices.contains(pageIndex), let request = session.imageRequests[pageIndex] else {
            throw ReaderPageExportError.currentPageUnavailable
        }

        if translationEnabled, !session.translationShowOriginal,
           let renderedAsset = session.translationRenderedAssets[pageIndex],
           !renderedAsset.localFilePath.isEmpty,
           FileManager.default.fileExists(atPath: renderedAsset.localFilePath),
           let image = UIImage(contentsOfFile: renderedAsset.localFilePath) {
            return image
        }

        guard let urlRequest = buildURLRequest(from: request) else {
            throw ReaderPageExportError.invalidImageRequest
        }

        let data = try await ReaderImagePipeline.shared.loadData(for: urlRequest, priority: .visible)
        guard let baseImage = ReaderDecodedImageStore.shared.image(
            for: urlRequest,
            data: data,
            targetSize: .zero,
            scale: UIScreen.main.scale,
            allowOriginalSize: true
        ) else {
            throw ReaderPageExportError.imageDecodeFailed
        }

        guard translationEnabled, !session.translationShowOriginal else {
            return baseImage
        }
        let overlays = session.translationBlocks(for: pageIndex)
        guard !overlays.isEmpty else { return baseImage }
        return ReaderTranslatedImageRenderer.render(baseImage, overlays: overlays)
    }

    private func writeTemporaryPageExport(_ image: UIImage) throws -> URL {
        guard let data = image.pngData() else {
            throw ReaderPageExportError.imageWriteFailed
        }
        let fileName = "comicdeck-\(safeExportFileName(item.title))-p\(displayedPageIndex).png"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ComicDeckPageExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func safeExportFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines)
        let parts = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        let name = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "page" : String(name.prefix(80))
    }

    private func saveImageToPhotos(at url: URL) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolvedStatus = status == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : status
        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            throw ReaderPageExportError.photoPermissionDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }

    private func applyCurrentTranslationPreferences() {
        session.applyTranslationPreferences(currentTranslationPreferences)
    }

    private func handleInitialTask() async {
        verticalCoordinator.prepareForContent(currentPage: session.currentPage)
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

    private func handleDisappear() {
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

    private func load() async {
        await session.load(using: vm, readerMode: readerMode)
        applyCurrentTranslationPreferences()
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
        let requests = ReaderPrefetchPlanner.preferredPrefetchIndexes(
            current: session.currentPage,
            total: session.totalPages,
            distance: distance,
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
        // When controls are visible, any tap dismisses them first
        if session.showControls {
            toggleControls()
            return
        }

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

    private func handleDoubleTap() {
        // handled inside ZoomableRemoteImage; keep as safe no-op for now
    }

    private func handleLongPressStart() {
        // placeholder for page-level long-press trigger
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
            preset = .edgeBiased
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
        case .edgeBiased:
            let zones = ReaderTapZoneResolver.zones(
                preset: preset,
                readerMode: readerMode,
                tapTurnMargin: CGFloat(clampedTapTurnMargin)
            )
            return zones.map { zone in
                TapZoneRegion(rect: zone.rect, action: tapAction(for: zone.action))
            }
        case .auto:
            return []
        }
    }

    private func tapAction(for gestureAction: ReaderGestureAction) -> TapAction {
        switch gestureAction {
        case .previous: return .previous
        case .next: return .next
        case .toggleControls, .none: return .toggleControls
        }
    }
}

