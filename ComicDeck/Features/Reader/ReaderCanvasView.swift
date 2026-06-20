import SwiftUI

struct ReaderCanvasView: View {
    let imageRequests: [ImageRequest?]
    let readerMode: ReaderMode
    let reloadNonce: Int
    let animatePageTransitions: Bool
    let translationEnabled: Bool
    let translationShowOriginal: Bool
    let translationBlocks: [Int: [ReaderTextBlock]]
    let translationRenderedAssets: [Int: ReaderRenderedPageAsset]
    let resolvedPageCount: Int
    let totalPages: Int
    let isLoadingMore: Bool
    let reloadPageAction: (Int) -> Void
    let translatePageAction: ((Int) -> Void)?
    let toggleTranslationAction: (() -> Void)?
    let onLongPressZoomStart: ((CGPoint) -> Void)?
    let onLongPressZoomEnd: (() -> Void)?
    @Binding var currentPage: Int
    let verticalCoordinator: ReaderVerticalCoordinator

    private let horizontalLoadRadius = 1
    private let verticalLoadRadius = 2
    @State private var settledLayoutSyncTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            if readerMode == .vertical {
                verticalReader(viewportHeight: geo.size.height)
            } else {
                horizontalReader
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var horizontalReader: some View {
        #if os(iOS)
        TabView(selection: $currentPage) {
            ForEach(Array(imageRequests.enumerated()), id: \.offset) { idx, request in
                horizontalPage(at: idx, request: shouldLoadPage(at: idx) ? request : nil)
                    .tag(idx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, readerMode == .rtl ? .rightToLeft : .leftToRight)
        #elseif os(macOS)
        horizontalPage(at: currentPage, request: imageRequests.indices.contains(currentPage) ? imageRequests[currentPage] : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        #endif
    }

    private func horizontalPage(at idx: Int, request: ImageRequest?) -> some View {
        ReaderPageView(
            pageIndex: idx,
            request: request,
            nonce: reloadNonce,
            supportsZoom: true,
            translationEnabled: translationEnabled,
            translationShowOriginal: translationShowOriginal,
            overlays: translationBlocks[idx] ?? [],
            renderedAsset: translationRenderedAssets[idx],
            resolvedPageCount: resolvedPageCount,
            totalPages: totalPages,
            isLoadingMore: isLoadingMore,
            reloadPageAction: { reloadPageAction(idx) },
            translatePageAction: translationEnabled ? { translatePageAction?(idx) } : nil,
            toggleTranslationAction: translationEnabled ? toggleTranslationAction : nil,
            onLongPressZoomStart: onLongPressZoomStart,
            onLongPressZoomEnd: onLongPressZoomEnd
        )
    }

    private func verticalReader(viewportHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(imageRequests.enumerated()), id: \.offset) { idx, request in
                        ReaderPageView(
                            pageIndex: idx,
                            request: request,
                            nonce: reloadNonce,
                            supportsZoom: false,
                            translationEnabled: translationEnabled,
                            translationShowOriginal: translationShowOriginal,
                            overlays: translationBlocks[idx] ?? [],
                            renderedAsset: translationRenderedAssets[idx],
                            resolvedPageCount: resolvedPageCount,
                            totalPages: totalPages,
                            isLoadingMore: isLoadingMore,
                            reloadPageAction: { reloadPageAction(idx) },
                            translatePageAction: translationEnabled ? { translatePageAction?(idx) } : nil,
                            toggleTranslationAction: translationEnabled ? toggleTranslationAction : nil,
                            onLongPressZoomStart: nil,
                            onLongPressZoomEnd: nil
                        )
                            .id(idx)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ReaderPageFramesPreferenceKey.self,
                                        value: [idx: geo.frame(in: .named("verticalReaderViewport"))]
                                    )
                                }
                            )
                    }
                }
                .onPreferenceChange(ReaderPageFramesPreferenceKey.self) { frames in
                    verticalCoordinator.recordPageFrames(frames)
                    if let target = verticalCoordinator.initialScrollTarget(currentPage: currentPage) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        scheduleSettledLayoutSyncIfNeeded()
                    }
                    syncCurrentPageFromVerticalLayout()
                }
                .onChange(of: verticalCoordinator.scrollTarget) { _, target in
                    guard let target else { return }
                    guard verticalCoordinator.initialScrollCompleted else { return }
                    if animatePageTransitions {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    } else {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    scheduleSettledLayoutSyncIfNeeded()
                }
                .onAppear {
                    verticalCoordinator.updateViewportHeight(viewportHeight)
                }
                .onChange(of: viewportHeight) { _, value in
                    verticalCoordinator.updateViewportHeight(value)
                    syncCurrentPageFromVerticalLayout()
                }
                .onChange(of: imageRequests.count) { _, _ in
                    settledLayoutSyncTask?.cancel()
                    verticalCoordinator.prepareForContent(currentPage: currentPage)
                }
                .onDisappear {
                    settledLayoutSyncTask?.cancel()
                    settledLayoutSyncTask = nil
                }
            }
            .background(Color.black)
            .coordinateSpace(name: "verticalReaderViewport")
        }
    }

    private func shouldLoadPage(at index: Int) -> Bool {
        if readerMode == .vertical {
            let centerPage = verticalCoordinator.currentPageFromLayout() ?? currentPage
            return abs(index - centerPage) <= verticalLoadRadius
        }
        return abs(index - currentPage) <= horizontalLoadRadius
    }

    private func syncCurrentPageFromVerticalLayout(now: Date = Date()) {
        if let resolved = verticalCoordinator.currentPageFromLayout(now: now), resolved != currentPage {
            currentPage = resolved
        }
    }

    private func scheduleSettledLayoutSyncIfNeeded(now: Date = Date()) {
        settledLayoutSyncTask?.cancel()
        guard let delay = verticalCoordinator.pendingSettledLayoutUpdateDelay(now: now) else { return }
        settledLayoutSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            syncCurrentPageFromVerticalLayout()
        }
    }
}
