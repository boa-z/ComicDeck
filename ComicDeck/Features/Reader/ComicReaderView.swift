#if os(iOS)
import SwiftUI
import UIKit
import Photos

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
    @State private var controller: ReaderController
    @State private var verticalCoordinator = ReaderVerticalCoordinator()
    @State private var showSettings = false
    @FocusState private var isReaderFocused: Bool
    @State private var platformMonitor = ReaderPlatformMonitor()
    @State private var isLongPressZoomed = false
    @State private var sharedPageExport: ShareFile?
    @State private var pageExportInProgress = false
    @State private var pageExportError: String?
    @State private var pageExportSuccessMessage: String?

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
            return readerMode == .vertical ? .black : PlatformColors.systemBackground
        case .system:
            return PlatformColors.systemBackground
        }
    }

    private var displayedPageIndex: Int {
        controller.session.displayedPageIndex(readerMode: readerMode)
    }

    private var isOfflineReading: Bool {
        controller.session.isOfflineReading
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
            .navigationBarBackButtonHidden(!controller.session.loading)
            .platformHideTabBar()
            .platformStatusBarHidden(!controller.session.showControls)
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
                .platformPresentationDetentsMedium()
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
                let _ = controller.handleReaderModeChange(old: oldMode, new: mode)
                if mode == .vertical {
                    verticalCoordinator.prepareForContent(currentPage: controller.session.currentPage)
                }
            }
            .onChange(of: controller.session.currentPage) { _, _ in
                controller.handleCurrentPageChange()
            }
            .onChange(of: reduceMotion) { _, newValue in
                controller.reduceMotion = newValue
            }
            .onChange(of: animatePageTransitions) { _, newValue in
                controller.animatePageTransitions = newValue
            }
            .onChange(of: preloadDistance) { _, newValue in
                controller.preloadDistance = newValue
            }
            .onChange(of: keepScreenOn) { _, enabled in
                platformMonitor.setKeepScreenOn(enabled)
            }
            .task {
                controller.readerMode = readerMode
                controller.animatePageTransitions = animatePageTransitions
                controller.reduceMotion = reduceMotion
                controller.preloadDistance = preloadDistance
                await controller.start()
                verticalCoordinator.prepareForContent(currentPage: controller.session.currentPage)
            }
            .onAppear {
                controller.updateTranslationPreferences(currentTranslationPreferences)
                isReaderFocused = true
                platformMonitor.setKeepScreenOn(keepScreenOn)
                platformMonitor.install(
                    onLeft: { controller.previousPage() },
                    onRight: { controller.nextPage() },
                    onUp: { controller.openAdjacentChapter(step: -1) },
                    onDown: { controller.openAdjacentChapter(step: 1) },
                    onMemoryPressure: {
                        verticalCoordinator.clearTrackedFrames()
                        ReaderDecodedImageStore.shared.trim()
                        Task { await ReaderImagePipeline.shared.clearAllCache() }
                        readerDebugLog("memory pressure: trimmed all caches", level: .warn)
                    }
                )
            }
            .onDisappear {
                controller.stop()
                platformMonitor.disableKeepScreenOn()
                platformMonitor.uninstall()
                let app = UIApplication.shared
                var bgTaskID: UIBackgroundTaskIdentifier = .invalid
                bgTaskID = app.beginBackgroundTask(withName: "ReaderCleanup") {
                    app.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
                Task { @MainActor in
                    await controller.cleanupAfterStop()
                    app.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
    }

    private func translationPreferenceObservingView<Content: View>(_ content: Content) -> some View {
        content
            .onChange(of: currentTranslationPreferences) { _, newValue in
                controller.updateTranslationPreferences(newValue)
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
        if controller.session.loading && !controller.session.canRenderReader {
            loadingView
        } else if !controller.session.errorText.isEmpty {
            readerErrorView
        } else if controller.session.totalPages == 0 {
            emptyReaderView
        } else {
            activeReaderView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView(value: controller.session.loadingProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(.white)
                .padding(.horizontal, 28)
            Text(controller.session.loadingMessage)
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
            Text(controller.session.errorText).foregroundStyle(.red)
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

                Button(AppLocalization.text("common.retry", "Retry")) { controller.retryLoad() }
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

                if controller.session.loading && controller.session.canRenderReader {
                    loadingOverlay
                }

                if controller.session.showControls {
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
                    controlsVisible: controller.session.showControls,
                    onSingleTap: { location, size in
                        handleTap(at: location, in: geo.size)
                    }
                )
            )
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.18), value: controller.session.showControls)
        }
    }

    private var readerCanvas: some View {
        ReaderCanvasView(
            imageRequests: controller.session.imageRequests,
            readerMode: readerMode,
            reloadNonce: controller.session.reloadNonce,
            animatePageTransitions: animatePageTransitions && !reduceMotion,
            translationEnabled: translationEnabled,
            translationShowOriginal: controller.session.translationShowOriginal,
            translationBlocks: controller.session.translationPageBlocks,
            translationRenderedAssets: controller.session.translationRenderedAssets,
            resolvedPageCount: controller.session.resolvedPageCount,
            totalPages: controller.session.totalPages,
            isLoadingMore: controller.session.isLoadingMore,
            reloadPageAction: { index in
                controller.session.jumpToPage(index, readerMode: readerMode)
                controller.reloadCurrentPage()
            },
            translatePageAction: translationEnabled ? { _ in
                controller.session.translateCurrentPage(using: vm)
            } : nil,
            toggleTranslationAction: translationEnabled ? {
                controller.session.toggleTranslationShowOriginal()
            } : nil,
            onLongPressZoomStart: { _ in
                isLongPressZoomed = true
            },
            onLongPressZoomEnd: {
                isLongPressZoomed = false
            },
            currentPage: $controller.session.currentPage,
            verticalCoordinator: verticalCoordinator
        )
        .ignoresSafeArea()
    }

    private var loadingOverlay: some View {
        VStack(spacing: 6) {
            ProgressView(value: controller.session.loadingProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(.white)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            Text(controller.session.loadingMessage)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
            if controller.session.totalPages > 0, controller.session.resolvedPageCount < controller.session.totalPages || controller.session.isLoadingMore {
                Text(AppLocalization.format(
                    "reader.loading.pages_ready",
                    "%lld/%lld pages ready",
                    Int64(controller.session.resolvedPageCount),
                    Int64(controller.session.totalPages)
                ))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.52))
            }
            Spacer()
        }
    }

    private var readerOverlay: some View {
        ReaderOverlayView(
            chapterTitle: controller.session.chapterTitle,
            chapterID: controller.session.chapterID,
            comicTitle: item.title,
            offlineStatusText: controller.session.offlineStatusText,
            displayedPageIndex: displayedPageIndex,
            totalPages: controller.session.totalPages,
            resolvedPageCount: controller.session.resolvedPageCount,
            isLoadingMore: controller.session.isLoadingMore,
            translationEnabled: translationEnabled,
            translationShowOriginal: controller.session.translationShowOriginal,
            translationStatusText: translationStatusText,
            isTranslatingCurrentPage: controller.session.translationStatus(for: controller.session.currentPage) == .processing,
            onTranslateCurrentPage: translationEnabled ? { controller.session.translateCurrentPage(using: vm) } : nil,
            onToggleTranslationShowOriginal: translationEnabled ? { controller.session.toggleTranslationShowOriginal() } : nil,
            translationBackendKind: translationBackendKind,
            readerMode: readerMode,
            animatePageTransitions: animatePageTransitions && !reduceMotion,
            currentPage: $controller.session.currentPage,
            previousChapterTitle: controller.session.previousChapter?.title.isEmpty == false ? controller.session.previousChapter?.title : controller.session.previousChapter?.id,
            nextChapterTitle: controller.session.nextChapter?.title.isEmpty == false ? controller.session.nextChapter?.title : controller.session.nextChapter?.id,
            onDismiss: dismiss.callAsFunction,
            onOpenModeMenu: { readerMode = $0 },
            onOpenSettings: { showSettings = true },
            onReload: { controller.reloadCurrentPage() },
            onShareCurrentPage: shareCurrentPage,
            onSaveCurrentPage: saveCurrentPageToPhotos,
            isExportingCurrentPage: pageExportInProgress,
            onOpenPreviousChapter: { controller.openAdjacentChapter(step: -1) },
            onOpenNextChapter: { controller.openAdjacentChapter(step: 1) },
            onJumpToVerticalPage: { target in
                controller.session.jumpToPage(target, readerMode: readerMode)
                _ = verticalCoordinator.scrollToPage(target, totalPages: controller.session.totalPages)
            }
        )
        .transition(.opacity)
    }

    private var translationStatusText: String? {
        guard translationEnabled else { return nil }
        if !controller.session.translationUnsupportedReason.isEmpty {
            return controller.session.translationUnsupportedReason
        }
        let currentPage = controller.session.currentPage
        let status = controller.session.translationStatus(for: currentPage)
        if status == .ready, controller.session.translationBlocks(for: currentPage).isEmpty {
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
            return controller.session.translationError(for: controller.session.currentPage) ?? AppLocalization.text("reader.translation.status.failed", "Translation failed")
        case .unsupported:
            return controller.session.translationError(for: controller.session.currentPage) ?? AppLocalization.text("reader.translation.status.unsupported", "Translation unavailable")
        }
    }

    private func onLeftTap() {
        if invertTapZones { controller.nextPage() } else { controller.previousPage() }
    }

    private func onRightTap() {
        if invertTapZones { controller.previousPage() } else { controller.nextPage() }
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

    private func makeCurrentPageExportImage() async throws -> PlatformImage {
        let pageIndex = controller.session.currentPage
        guard controller.session.imageRequests.indices.contains(pageIndex), let request = controller.session.imageRequests[pageIndex] else {
            throw ReaderPageExportError.currentPageUnavailable
        }

        if translationEnabled, !controller.session.translationShowOriginal,
           let renderedAsset = controller.session.translationRenderedAssets[pageIndex],
           !renderedAsset.localFilePath.isEmpty,
           FileManager.default.fileExists(atPath: renderedAsset.localFilePath),
           let image = PlatformImage(contentsOfFile: renderedAsset.localFilePath) {
            return image
        }

        guard let urlRequest = buildURLRequest(from: request) else {
            throw ReaderPageExportError.invalidImageRequest
        }

        let data = try await ReaderImagePipeline.shared.loadData(for: urlRequest, priority: .visible)
        let exportScale = UITraitCollection.current.displayScale
        guard let baseImage = await ReaderDecodedImageStore.shared.imageAsync(
            for: urlRequest,
            data: data,
            targetSize: CGSize.zero,
            scale: exportScale,
            allowOriginalSize: true
        ) else {
            throw ReaderPageExportError.imageDecodeFailed
        }

        guard translationEnabled, !controller.session.translationShowOriginal else {
            return baseImage
        }
        let overlays = controller.session.translationBlocks(for: pageIndex)
        guard !overlays.isEmpty else { return baseImage }
        return await ReaderTranslatedImageRenderer.renderAsync(baseImage, overlays: overlays)
    }

    private func writeTemporaryPageExport(_ image: PlatformImage) throws -> URL {
        guard let data = image.platformPNGData else {
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

    private func handleTap(at location: CGPoint, in size: CGSize) {
        if controller.session.showControls {
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
                if invertTapZones { controller.nextPage() } else { controller.previousPage() }
            case .next:
                if invertTapZones { controller.previousPage() } else { controller.nextPage() }
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
            controller.session.showControls.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                controller.session.showControls.toggle()
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
#endif
