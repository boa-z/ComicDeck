import SwiftUI
import UIKit

struct ReaderPageView: View {
    let pageIndex: Int
    let request: ImageRequest?
    let nonce: Int
    let supportsZoom: Bool
    let translationEnabled: Bool
    let translationShowOriginal: Bool
    let overlays: [ReaderTextBlock]
    let renderedAsset: ReaderRenderedPageAsset?
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
                                displayScale: displayScale
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
                        Text("Invalid image request")
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
                    minHeight: supportsZoom ? 220 : 420
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: supportsZoom ? .infinity : nil)
        .background(Color.black)
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
    let minHeight: CGFloat

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(AppLocalization.format("reader.loading.page", "Loading page %lld", Int64(pageIndex + 1)))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .background(Color.black)
    }
}
