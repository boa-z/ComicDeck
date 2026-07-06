import Foundation
import Observation
import SwiftUI

/// Shared reader UI controller for both iOS (`ComicReaderView`) and macOS
/// (`MacReaderWindowView`).
///
/// Owns the `ReaderSession`, the reader load / chapter-navigation / history-save
/// task lifecycle, and the prefetch generation bookkeeping. Both platform views
/// delegate page turns, chapter navigation, reload, and lifecycle wiring here so
/// the controller logic lives in exactly one place rather than being duplicated
/// across the two platform-specific views.
///
/// Platform-only concerns stay in the views:
/// - iOS `ReaderPlatformMonitor` (hardware keyboard / memory pressure / idle timer)
/// - iOS `UIApplication` background-task wrapping on disappear
/// - SwiftUI `@AppStorage` / `@Environment` sources of truth (mirrored here via
///   `update*` setters)
/// - `ReaderVerticalCoordinator` (read directly by `ReaderCanvasView` for layout)
@MainActor
@Observable
final class ReaderController {
    let vm: ReaderViewModel
    let item: ComicSummary
    let initialChapterID: String
    let initialChapterTitle: String
    let localChapterDirectory: String?
    let initialPage: Int?
    let initialChapterSequence: [ComicChapter]?

    /// Owned by the controller; views read `controller.session` and pass it to
    /// `ReaderCanvasView` / overlay. Exposed as `var` so SwiftUI bindings like
    /// `$controller.session.currentPage` observe correctly.
    var session: ReaderSession

    // MARK: Mirrored preferences (sources of truth live in the view's
    // @AppStorage / @Environment; pushed here via the update* setters so the
    // controller methods can read them synchronously).

    var readerMode: ReaderMode
    var animatePageTransitions: Bool
    var reduceMotion: Bool
    var preloadDistance: Int
    var translationPreferences: ReaderTranslationPreferences?

    // MARK: Internal task lifecycle

    private var readerLoadTask: Task<Void, Never>?
    private var chapterSequenceTask: Task<Void, Never>?
    private var chapterNavigationTask: Task<Void, Never>?
    private var historySaveTask: Task<Void, Never>?
    private var prefetchGeneration = 0
    private var lastPrefetchedPage = 0
    private let prefetcher = ReaderImagePrefetcher.shared

    init(
        vm: ReaderViewModel,
        item: ComicSummary,
        chapterID: String,
        chapterTitle: String,
        localChapterDirectory: String? = nil,
        initialPage: Int? = nil,
        chapterSequence: [ComicChapter]? = nil,
        readerMode: ReaderMode = .ltr,
        animatePageTransitions: Bool = true,
        reduceMotion: Bool = false,
        preloadDistance: Int = 2
    ) {
        self.vm = vm
        self.item = item
        self.initialChapterID = chapterID
        self.initialChapterTitle = chapterTitle
        self.localChapterDirectory = localChapterDirectory
        self.initialPage = initialPage
        self.initialChapterSequence = chapterSequence
        self.readerMode = readerMode
        self.animatePageTransitions = animatePageTransitions
        self.reduceMotion = reduceMotion
        self.preloadDistance = max(1, min(preloadDistance, 4))
        self.translationPreferences = nil
        self.session = ReaderSession(
            item: item,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            localChapterDirectory: localChapterDirectory,
            initialPage: initialPage,
            chapterSequence: chapterSequence
        )
    }

    // MARK: Preference mirrors

    func updateReaderMode(_ mode: ReaderMode) { readerMode = mode }
    func updateAnimatePageTransitions(_ value: Bool) { animatePageTransitions = value }
    func updateReduceMotion(_ value: Bool) { reduceMotion = value }
    func updatePreloadDistance(_ value: Int) { preloadDistance = max(1, min(value, 4)) }

    /// Applies whatever translation preferences are currently stored
    /// (a no-op when `translationPreferences` is `nil`, i.e. on macOS).
    func applyTranslationPreferences() {
        guard let translationPreferences else { return }
        session.applyTranslationPreferences(translationPreferences)
    }

    /// Called by the view when translation preferences change.
    func updateTranslationPreferences(_ preferences: ReaderTranslationPreferences) {
        translationPreferences = preferences
        session.applyTranslationPreferences(preferences)
    }

    // MARK: Lifecycle

    /// Called from the view's `.task`. Performs the shared startup that both
    /// iOS and macOS need: marks the session visible, ensures the runtime is
    /// prepared (idempotent), starts a prefetch session, and kicks off chapter
    /// load + sequence load.
    ///
    /// The caller is responsible for `verticalCoordinator.prepareForContent(...)`
    /// after this returns (the coordinator stays in the view).
    func start() async {
        session.markVisible()
        await vm.prepareIfNeeded()
        prefetchGeneration = await ReaderImagePipeline.shared.beginPrefetchSession()
        lastPrefetchedPage = session.currentPage

        readerLoadTask?.cancel()
        readerLoadTask = Task { [weak self] in
            await self?.load()
        }

        chapterSequenceTask?.cancel()
        chapterSequenceTask = Task { [weak self] in
            guard let self else { return }
            await self.session.loadChapterSequenceIfNeeded(using: self.vm)
        }
    }

    /// Synchronously cancels all in-flight tasks. The asynchronous cleanup
    /// (pipeline cancel, session close, history persist, finish reading) is
    /// returned via `cleanupAfterStop()` so callers that need to await it
    /// (e.g. iOS `UIApplication` background task) can do so.
    func stop() {
        readerLoadTask?.cancel()
        readerLoadTask = nil
        chapterSequenceTask?.cancel()
        chapterSequenceTask = nil
        chapterNavigationTask?.cancel()
        chapterNavigationTask = nil
        historySaveTask?.cancel()
        historySaveTask = nil
        prefetcher.cancel()
    }

    /// Async cleanup to run after `stop()`. Safe to call from a background-task
    /// wrapper (iOS) or a fire-and-forget `Task` (macOS).
    func cleanupAfterStop() async {
        await ReaderImagePipeline.shared.cancelPrefetchSession()
        await session.close(using: vm)
        await persistHistoryNow()
        session.finishReadingSession(using: vm.library)
    }

    // MARK: Load / reload

    func load() async {
        await session.load(using: vm, readerMode: readerMode)
        if let translationPreferences {
            session.applyTranslationPreferences(translationPreferences)
        }
        preloadAroundCurrentPage()
        await persistHistoryNow()
    }

    /// Retry from an error state: cancels any in-flight load and restarts it.
    func retryLoad() {
        readerLoadTask?.cancel()
        readerLoadTask = Task { [weak self] in
            await self?.load()
        }
    }

    func reloadCurrentPage() {
        session.reloadCurrentPage()
        session.resolvePagesAroundCurrentPage(using: vm, readerMode: readerMode)
        preloadAroundCurrentPage()
    }

    var canGoToPreviousPage: Bool {
        session.totalPages > 0 && session.currentPage > 0
    }

    var canGoToNextPage: Bool {
        session.totalPages > 0 && session.currentPage < session.totalPages - 1
    }

    var canGoToFirstPage: Bool {
        session.totalPages > 0 && session.currentPage > 0
    }

    var canGoToLastPage: Bool {
        session.totalPages > 0 && session.currentPage < session.totalPages - 1
    }

    var canGoToPreviousChapter: Bool {
        session.previousChapter != nil
    }

    var canGoToNextChapter: Bool {
        session.nextChapter != nil
    }

    var canReloadCurrentPage: Bool {
        session.totalPages > 0
    }

    // MARK: Navigation

    func nextPage() {
        session.nextPage(
            readerMode: readerMode,
            animatePageTransitions: animatePageTransitions,
            reduceMotion: reduceMotion
        )
    }

    func previousPage() {
        session.previousPage(
            readerMode: readerMode,
            animatePageTransitions: animatePageTransitions,
            reduceMotion: reduceMotion
        )
    }

    func firstPage() {
        guard session.totalPages > 0 else { return }
        session.jumpToPage(0, readerMode: readerMode)
    }

    func lastPage() {
        guard session.totalPages > 0 else { return }
        session.jumpToPage(session.totalPages - 1, readerMode: readerMode)
    }

    func openAdjacentChapter(step: Int) {
        guard step != 0 else { return }
        chapterNavigationTask?.cancel()
        chapterNavigationTask = Task { [weak self] in
            guard let self else { return }
            await self.session.loadAdjacentChapter(
                step: step,
                using: self.vm,
                library: self.vm.library,
                readerMode: self.readerMode
            )
            guard !Task.isCancelled else { return }
            self.preloadAroundCurrentPage()
            await self.persistHistoryNow()
        }
    }

    // MARK: Change handlers (called from view `.onChange`)

    /// Aggregates the work triggered by `.onChange(of: session.currentPage)`.
    func handleCurrentPageChange() {
        session.resolvePagesAroundCurrentPage(using: vm, readerMode: readerMode)
        preloadAroundCurrentPage()
        scheduleHistorySave()
    }

    /// Re-maps the current page index when switching between LTR / RTL / vertical.
    /// Returns the new current page so the caller can feed it to
    /// `verticalCoordinator.prepareForContent(...)` when entering vertical mode.
    @discardableResult
    func handleReaderModeChange(old: ReaderMode, new: ReaderMode) -> Int {
        guard session.totalPages > 0 else { return session.currentPage }
        readerMode = new
        let displayed = session.displayedPageIndex(readerMode: old)
        let oneBased = max(1, min(session.totalPages, displayed))
        let ltrIndex = min(session.totalPages - 1, oneBased - 1)
        session.currentPage = new == .rtl ? max(0, session.totalPages - 1 - ltrIndex) : ltrIndex
        return session.currentPage
    }

    // MARK: Private

    private func preloadAroundCurrentPage() {
        guard session.totalPages > 0 else { return }
        let distance = max(1, min(preloadDistance, 4))
        let direction = session.currentPage == lastPrefetchedPage
            ? 0
            : (session.currentPage > lastPrefetchedPage ? 1 : -1)
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
        historySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await self?.persistHistoryNow()
        }
    }

    private func persistHistoryNow() async {
        await session.persistHistory(using: vm.library, readerMode: readerMode)
        if session.completedChapterProgress(readerMode: readerMode) != nil {
            await vm.tracker.recordChapterCompletion(
                item: item,
                chapterSequence: session.chapterSequence,
                chapterID: session.chapterID
            )
        }
    }
}

// MARK: - Focused value for macOS menu bar commands

#if os(macOS)
struct ReaderControllerFocusedValueKey: FocusedValueKey {
    typealias Value = ReaderController
}

struct MacReaderCommandState {
    var readerMode: ReaderMode
    var backgroundMode: ReaderBackgroundMode
    var setReaderMode: (ReaderMode) -> Void
    var setBackgroundMode: (ReaderBackgroundMode) -> Void
    var closeWindow: () -> Void
}

struct MacReaderCommandStateFocusedValueKey: FocusedValueKey {
    typealias Value = MacReaderCommandState
}

extension FocusedValues {
    var readerController: ReaderController? {
        get { self[ReaderControllerFocusedValueKey.self] }
        set { self[ReaderControllerFocusedValueKey.self] = newValue }
    }

    var macReaderCommandState: MacReaderCommandState? {
        get { self[MacReaderCommandStateFocusedValueKey.self] }
        set { self[MacReaderCommandStateFocusedValueKey.self] = newValue }
    }
}
#endif
