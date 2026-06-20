import SwiftUI

/// Shared routing shell for the reader entry point.
///
/// Both iOS and macOS call sites instantiate `ReaderRoutingView`, which forwards
/// to the platform-specific reader experience: iOS uses the in-stack
/// `ComicReaderView` (push), while macOS uses the independent-window
/// `MacReaderWindowView` (sheet/window). Keeping this shell separate lets the two
/// platform implementations be physically isolated in their own files (each
/// guarded by a file-level `#if os(...)`) instead of co-existing as dead code
/// inside a single shared struct.
@MainActor
struct ReaderRoutingView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    let item: ComicSummary
    let chapterID: String
    let chapterTitle: String
    let localChapterDirectory: String?
    let initialPage: Int?
    let chapterSequence: [ComicChapter]?

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
    }

    var body: some View {
        #if os(macOS)
        MacReaderWindowView(
            vm: vm,
            item: item,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            localChapterDirectory: localChapterDirectory,
            initialPage: initialPage,
            chapterSequence: chapterSequence
        )
        .environment(library)
        #else
        ComicReaderView(
            vm: vm,
            item: item,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            localChapterDirectory: localChapterDirectory,
            initialPage: initialPage,
            chapterSequence: chapterSequence
        )
        .environment(library)
        #endif
    }
}
