import SwiftUI

/// Shared routing shell for the comic detail entry point.
///
/// Both iOS and macOS call sites instantiate `ComicDetailRoutingView`, which
/// forwards to the platform-specific detail experience: iOS uses the in-stack
/// `ComicDetailView` (single-column scrolling), while macOS uses the multi-tab
/// `MacComicDetailWorkspaceView`. Keeping this shell separate lets the two
/// platform implementations be physically isolated in their own files (each
/// guarded by a file-level `#if os(...)`) instead of co-existing as dead code
/// inside a single shared struct.
@MainActor
struct ComicDetailRoutingView: View {
    @Bindable var vm: ReaderViewModel
    @Environment(LibraryViewModel.self) private var library
    let item: ComicSummary
    var onTagSelected: ((String, String) -> Void)? = nil
    var initialReadRoute: ReaderLaunchContext? = nil
    var onConsumeInitialReadRoute: (() -> Void)? = nil
    var onNavigateBack: (() -> Void)? = nil

    init(
        vm: ReaderViewModel,
        item: ComicSummary,
        onTagSelected: ((String, String) -> Void)? = nil,
        initialReadRoute: ReaderLaunchContext? = nil,
        onConsumeInitialReadRoute: (() -> Void)? = nil,
        onNavigateBack: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.item = item
        self.onTagSelected = onTagSelected
        self.initialReadRoute = initialReadRoute
        self.onConsumeInitialReadRoute = onConsumeInitialReadRoute
        self.onNavigateBack = onNavigateBack
    }

    var body: some View {
        #if os(macOS)
        MacComicDetailWorkspaceView(
            vm: vm,
            item: item,
            onTagSelected: onTagSelected,
            initialReadRoute: initialReadRoute,
            onConsumeInitialReadRoute: onConsumeInitialReadRoute,
            onNavigateBack: onNavigateBack
        )
        .environment(library)
        #else
        ComicDetailView(
            vm: vm,
            item: item,
            onTagSelected: onTagSelected,
            initialReadRoute: initialReadRoute,
            onConsumeInitialReadRoute: onConsumeInitialReadRoute,
            onNavigateBack: onNavigateBack
        )
        .environment(library)
        #endif
    }
}
