import SwiftUI

struct ReaderPageView: View {
    let pageIndex: Int
    let request: ImageRequest?
    let nonce: Int
    let supportsZoom: Bool
    let translationEnabled: Bool
    let translationShowOriginal: Bool
    let overlays: [ReaderTextBlock]
    let renderedAsset: ReaderRenderedPageAsset?
    let resolvedPageCount: Int
    let totalPages: Int
    let isLoadingMore: Bool
    let reloadPageAction: () -> Void
    let translatePageAction: (() -> Void)?
    let toggleTranslationAction: (() -> Void)?
    let onLongPressZoomStart: ((CGPoint) -> Void)?
    let onLongPressZoomEnd: (() -> Void)?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let request {
                let overlayCount = translationShowOriginal ? 0 : overlays.count
                let renderedRequest = translationShowOriginal ? nil : renderedAssetRequest()
                let activeOverlays = renderedRequest == nil && translationEnabled && overlayCount > 0 ? overlays : []
                if let urlRequest = renderedRequest ?? buildURLRequest(from: request) {
                    Group {
                        if supportsZoom {
                            ZoomableRemoteImage(
                                request: urlRequest,
                                overlays: activeOverlays,
                                displayScale: displayScale,
                                onLongPressZoomStart: onLongPressZoomStart,
                                onLongPressZoomEnd: onLongPressZoomEnd
                            )
                        } else {
                            PlainRemoteImage(
                                request: urlRequest,
                                overlays: activeOverlays
                            )
                        }
                    }
                    .id("\(pageIndex)-\(nonce)-\(urlRequestKey(urlRequest))")
                    .frame(maxWidth: .infinity, maxHeight: supportsZoom ? .infinity : nil)
                    .onAppear {
                        readerDebugLog(
                            "page render appear: page=\(pageIndex), zoom=\(supportsZoom), translationEnabled=\(translationEnabled), overlays=\(overlayCount), renderedAsset=\(renderedRequest != nil), url=\(urlRequest.url?.absoluteString ?? request.url)",
                            level: .debug
                        )
                        if let fileURL = urlRequest.url, fileURL.isFileURL {
                            let exists = FileManager.default.fileExists(atPath: fileURL.path)
                            readerDebugLog(
                                "page file check: page=\(pageIndex), path=\(fileURL.path), exists=\(exists)",
                                level: .debug
                            )
                        }
                    }
                    .onChange(of: overlayCount) { _, count in
                        readerDebugLog(
                            "page overlays updated: page=\(pageIndex), zoom=\(supportsZoom), translationEnabled=\(translationEnabled), overlays=\(count), renderedAsset=\(renderedRequest != nil)",
                            level: .info
                        )
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "xmark.octagon")
                            .foregroundStyle(.red)
                        Text(AppLocalization.text("reader.error.invalid_image_request", "Invalid image request"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                        Text(request.url)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(3)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ReaderPagePlaceholderView(
                    pageIndex: pageIndex,
                    resolvedPageCount: resolvedPageCount,
                    totalPages: totalPages,
                    isLoadingMore: isLoadingMore,
                    minHeight: supportsZoom ? 220 : 420
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: supportsZoom ? .infinity : nil)
        .background(Color.black)
        .contentShape(Rectangle())
    }

    private func renderedAssetRequest() -> URLRequest? {
        guard translationEnabled, let renderedAsset, !renderedAsset.localFilePath.isEmpty else {
            return nil
        }
        let fileURL = URL(fileURLWithPath: renderedAsset.localFilePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return URLRequest(url: fileURL)
    }
}

private struct ReaderPagePlaceholderView: View {
    let pageIndex: Int
    let resolvedPageCount: Int
    let totalPages: Int
    let isLoadingMore: Bool
    let minHeight: CGFloat

    private var readinessText: String? {
        guard totalPages > 0, isLoadingMore || resolvedPageCount < totalPages else { return nil }
        return AppLocalization.format(
            "reader.loading.pages_ready",
            "%lld/%lld pages ready",
            Int64(max(0, resolvedPageCount)),
            Int64(totalPages)
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 96, height: 132)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 5) {
                        Capsule()
                            .fill(.white.opacity(0.12))
                            .frame(width: 62, height: 6)
                        Capsule()
                            .fill(.white.opacity(0.09))
                            .frame(width: 42, height: 6)
                    }
                    .padding(.bottom, 18)
                }

            Text(AppLocalization.format("reader.loading.page_preparing", "Preparing page %lld", Int64(pageIndex + 1)))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.46))

            if let readinessText {
                Text(readinessText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.36))
            }
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(Color.black)
    }
}
