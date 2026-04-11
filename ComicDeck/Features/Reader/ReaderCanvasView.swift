import SwiftUI
import UIKit
import ImageIO

struct ReaderCanvasView: View {
    let imageRequests: [ImageRequest?]
    let readerMode: ReaderMode
    let reloadNonce: Int
    let animatePageTransitions: Bool
    let translationEnabled: Bool
    let translationShowOriginal: Bool
    let translationBlocks: [Int: [ReaderTextBlock]]
    let translationRenderedAssets: [Int: ReaderRenderedPageAsset]
    @Binding var currentPage: Int
    let verticalCoordinator: ReaderVerticalCoordinator

    private let horizontalLoadRadius = 1
    private let verticalLoadRadius = 2

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
        TabView(selection: $currentPage) {
            ForEach(Array(imageRequests.enumerated()), id: \.offset) { idx, request in
                ReaderPageView(
                    pageIndex: idx,
                    request: shouldLoadPage(at: idx) ? request : nil,
                    nonce: reloadNonce,
                    supportsZoom: true,
                    translationEnabled: translationEnabled,
                    translationShowOriginal: translationShowOriginal,
                    overlays: translationBlocks[idx] ?? [],
                    renderedAsset: translationRenderedAssets[idx]
                )
                    .tag(idx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .tabViewStyle(.page(indexDisplayMode: .never))
        .environment(\.layoutDirection, readerMode == .rtl ? .rightToLeft : .leftToRight)
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
                            renderedAsset: translationRenderedAssets[idx]
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
                    }
                    if let resolved = verticalCoordinator.currentPageFromLayout(), resolved != currentPage {
                        currentPage = resolved
                    }
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
                }
                .onAppear {
                    verticalCoordinator.updateViewportHeight(viewportHeight)
                }
                .onChange(of: viewportHeight) { _, value in
                    verticalCoordinator.updateViewportHeight(value)
                    if let resolved = verticalCoordinator.currentPageFromLayout(), resolved != currentPage {
                        currentPage = resolved
                    }
                }
                .onChange(of: imageRequests.count) { _, _ in
                    verticalCoordinator.prepareForContent(currentPage: currentPage)
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
}

struct ReaderPageFramesPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

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

struct PlainRemoteImage: View {
    let request: URLRequest
    let overlays: [ReaderTextBlock]
    @State private var uiImage: UIImage?
    @State private var imageSize: CGSize?
    @State private var errorText: String?
    @State private var loading = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text("Failed to load image")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(3)
                }
                .padding()
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .tint(.white)
                    Text(AppLocalization.text("reader.loading.image", "Loading image..."))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(ReaderPlainImageLayout.displayAspectRatio(for: imageSize ?? uiImage?.size), contentMode: .fit)
        .background(Color.black)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .task(id: loadTaskKey(containerWidth: proxy.size.width)) {
                        await load(containerWidth: proxy.size.width)
                    }
            }
        }
    }

    private func loadTaskKey(containerWidth: CGFloat) -> String {
        return "\(urlRequestKey(request))|w\(Int(max(containerWidth, 1).rounded()))|\(overlays.count)"
    }

    private func load(containerWidth: CGFloat) async {
        guard containerWidth > 0 else { return }

        loading = true
        defer { loading = false }
        errorText = nil
        uiImage = nil

        do {
            let data = try await ReaderImagePipeline.shared.loadData(for: request, priority: .visible)
            guard !Task.isCancelled else {
                readerDebugLog("plain image load cancelled", level: .warn)
                return
            }
            let sourceSize = Self.imageSourceSize(from: data)
            if let sourceSize {
                imageSize = sourceSize
            }
            let targetSize = ReaderPlainImageLayout.decodeTargetSize(
                for: containerWidth,
                imageSize: sourceSize ?? imageSize ?? uiImage?.size
            )
            readerDebugLog(
                "plain image load start: url=\(request.url?.absoluteString ?? "nil"), isFile=\(request.url?.isFileURL == true), width=\(Int(containerWidth.rounded())), source=\(Int(sourceSize?.width ?? 0))x\(Int(sourceSize?.height ?? 0)), target=\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))",
                level: .debug
            )
            guard let baseImage = ReaderDecodedImageStore.shared.image(
                for: request,
                data: data,
                targetSize: targetSize,
                scale: displayScale,
                allowOriginalSize: false
            ) else {
                readerDebugLog("plain image decode failed: dataBytes=\(data.count)", level: .error)
                throw ReaderImagePipelineError.invalidResponse
            }
            guard !Task.isCancelled else {
                readerDebugLog("plain image render cancelled", level: .warn)
                return
            }
            let image = ReaderTranslatedImageRenderer.render(baseImage, overlays: overlays)
            imageSize = baseImage.size
            uiImage = image
            readerDebugLog(
                "plain translated image ready: overlays=\(overlays.count), size=\(Int(image.size.width))x\(Int(image.size.height))",
                level: .info
            )
        } catch is CancellationError {
            readerDebugLog("plain image cancellation error caught", level: .warn)
            return
        } catch {
            errorText = error.localizedDescription
            readerDebugLog("plain image request error: \(error.localizedDescription), url=\(request.url?.absoluteString ?? "")", level: .error)
        }
    }

    private static func imageSourceSize(from data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0,
              height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

enum ReaderPlainImageLayout {
    static let fallbackAspectRatio: CGFloat = 0.7

    static func displayAspectRatio(for imageSize: CGSize?) -> CGFloat {
        guard let imageSize, imageSize.width > 0, imageSize.height > 0 else {
            return fallbackAspectRatio
        }
        let aspectRatio = imageSize.width / imageSize.height
        guard aspectRatio.isFinite, aspectRatio > 0 else {
            return fallbackAspectRatio
        }
        return aspectRatio
    }

    static func decodeTargetSize(for width: CGFloat, imageSize: CGSize?) -> CGSize {
        let resolvedWidth = max(width, 1)
        let resolvedHeight = max(resolvedWidth / displayAspectRatio(for: imageSize), 1)
        return CGSize(width: resolvedWidth, height: resolvedHeight)
    }
}

struct ZoomableRemoteImage: UIViewRepresentable {
    let request: URLRequest
    let overlays: [ReaderTextBlock]
    var displayScale: CGFloat = 2.0

    func makeCoordinator() -> Coordinator {
        Coordinator(displayScale: displayScale)
    }

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView()
        context.coordinator.attach(view)
        view.setOverlays(overlays)
        context.coordinator.load(request)
        return view
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        context.coordinator.attach(uiView)
        uiView.setOverlays(overlays)
        context.coordinator.updateRenderedImageIfNeeded()
        context.coordinator.load(request)
    }

    static func dismantleUIView(_ uiView: ZoomingImageScrollView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    final class Coordinator: NSObject {
        private weak var view: ZoomingImageScrollView?
        private var loadTask: Task<Void, Never>?
        private var currentKey = ""
        private var currentRequest: URLRequest?
        private let displayScale: CGFloat

        init(displayScale: CGFloat) {
            self.displayScale = displayScale
            super.init()
        }

        func attach(_ view: ZoomingImageScrollView) {
            guard self.view !== view else { return }
            self.view = view
            view.doubleTapRecognizer.addTarget(self, action: #selector(handleDoubleTap(_:)))
        }

        func load(_ request: URLRequest) {
            let key = urlRequestKey(request)
            currentRequest = request
            guard key != currentKey else { return }
            currentKey = key
            cancel()
            view?.setLoading(true)
            loadTask = Task { [weak self, displayScale] in
                do {
                    let data = try await ReaderImagePipeline.shared.loadData(for: request, priority: .visible)
                    guard !Task.isCancelled else { return }
                    let targetSize = await MainActor.run {
                        self?.view?.bounds.size ?? .zero
                    }
                    guard !Task.isCancelled else { return }
                    guard let baseImage = ReaderDecodedImageStore.shared.image(
                        for: request,
                        data: data,
                        targetSize: targetSize,
                        scale: displayScale,
                        allowOriginalSize: true
                    ) else {
                        throw ReaderImagePipelineError.invalidResponse
                    }
                    await MainActor.run {
                        self?.view?.setBaseImage(baseImage)
                        self?.updateRenderedImageIfNeeded()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.view?.setError("Failed to load image")
                    }
                    readerDebugLog(
                        "image request error: \(error.localizedDescription), url=\(request.url?.absoluteString ?? "")",
                        level: .error
                    )
                }
            }
        }

        func cancel() {
            loadTask?.cancel()
            loadTask = nil
        }

        @MainActor
        func updateRenderedImageIfNeeded() {
            guard let view, let baseImage = view.baseImage else { return }
            let overlays = view.currentOverlays
            let image = ReaderTranslatedImageRenderer.render(baseImage, overlays: overlays)
            view.setImage(image)
            readerDebugLog(
                "zoom translated image ready: overlays=\(overlays.count), size=\(Int(image.size.width.rounded()))x\(Int(image.size.height.rounded()))",
                level: .info
            )
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            if view.zoomScale > view.minimumZoomScale + 0.01 {
                view.setZoomScale(view.minimumZoomScale, animated: true)
                return
            }

            let targetScale = min(view.maximumZoomScale, 2.5)
            let point = recognizer.location(in: view.imageView)
            let zoomRect = zoomRect(for: targetScale, center: point, in: view)
            view.zoom(to: zoomRect, animated: true)
        }

        private func zoomRect(for scale: CGFloat, center: CGPoint, in view: ZoomingImageScrollView) -> CGRect {
            let width = view.bounds.width / scale
            let height = view.bounds.height / scale
            return CGRect(x: center.x - width * 0.5, y: center.y - height * 0.5, width: width, height: height)
        }
    }
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    let doubleTapRecognizer = UITapGestureRecognizer()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let errorLabel = UILabel()
    var currentOverlays: [ReaderTextBlock] = []
    var baseImage: UIImage?
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        bouncesZoom = true
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        isScrollEnabled = false

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        addSubview(loadingIndicator)

        errorLabel.textColor = .white
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 2
        errorLabel.isHidden = true
        addSubview(errorLabel)

        doubleTapRecognizer.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTapRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            recalculateZoomScales(resetToMinimum: false)
        }
        loadingIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY)
        errorLabel.frame = CGRect(x: 20, y: bounds.midY - 20, width: max(0, bounds.width - 40), height: 40)
        centerImageIfNeeded()
    }

    func setLoading(_ loading: Bool) {
        if loading {
            errorLabel.isHidden = true
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
    }

    func setImage(_ image: UIImage) {
        imageView.image = image
        errorLabel.isHidden = true
        setLoading(false)
        contentOffset = .zero
        contentInset = .zero
        recalculateZoomScales(resetToMinimum: true)
    }

    func setBaseImage(_ image: UIImage) {
        baseImage = image
    }

    func setError(_ text: String) {
        setLoading(false)
        imageView.image = nil
        errorLabel.text = text
        errorLabel.isHidden = false
        contentOffset = .zero
        contentInset = .zero
        contentSize = bounds.size
        minimumZoomScale = 1
        maximumZoomScale = 1
        zoomScale = 1
        isScrollEnabled = false
    }

    private func recalculateZoomScales(resetToMinimum: Bool) {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = bounds
            contentSize = bounds.size
            contentInset = .zero
            minimumZoomScale = 1
            maximumZoomScale = 1
            zoomScale = 1
            isScrollEnabled = false
            return
        }

        let boundsSize = bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return }

        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size

        let xScale = boundsSize.width / image.size.width
        let yScale = boundsSize.height / image.size.height
        let minScale = min(xScale, yScale)
        let maxScale = max(minScale * 4, minScale + 0.01)

        minimumZoomScale = minScale
        maximumZoomScale = maxScale

        if resetToMinimum {
            zoomScale = minScale
            contentOffset = .zero
        } else if zoomScale < minScale {
            zoomScale = minScale
        } else if zoomScale > maxScale {
            zoomScale = maxScale
        }

        isScrollEnabled = zoomScale > minimumZoomScale + 0.01
        centerImageIfNeeded()
    }

    private func centerImageIfNeeded() {
        var frameToCenter = imageView.frame
        if frameToCenter.size.width < bounds.size.width {
            frameToCenter.origin.x = (bounds.size.width - frameToCenter.size.width) * 0.5
        } else {
            frameToCenter.origin.x = 0
        }
        if frameToCenter.size.height < bounds.size.height {
            frameToCenter.origin.y = (bounds.size.height - frameToCenter.size.height) * 0.5
        } else {
            frameToCenter.origin.y = 0
        }
        imageView.frame = frameToCenter
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        isScrollEnabled = zoomScale > minimumZoomScale + 0.01
        centerImageIfNeeded()
    }

    func setOverlays(_ overlays: [ReaderTextBlock]) {
        currentOverlays = overlays
        readerDebugLog(
            "zoom translated image payload updated: overlays=\(overlays.count)",
            level: .info
        )
    }
}

enum ReaderTranslatedImageRenderer {
    private struct TranslationBlock {
        let rect: CGRect
        let text: String
        let sourceTexts: [String]
    }

    static func render(_ image: UIImage, overlays: [ReaderTextBlock]) -> UIImage {
        guard !overlays.isEmpty else { return image }
        let blocks = mergeOverlaysIntoBlocks(overlays, imageSize: image.size)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
            for block in blocks {
                let layout = layoutRect(for: block.text, in: block.rect, imageSize: image.size)
                UIColor.white.withAlphaComponent(0.94).setFill()
                UIBezierPath(roundedRect: layout.rect, cornerRadius: 8).fill()
                NSString(string: block.text).draw(in: layout.rect.insetBy(dx: 6, dy: 4), withAttributes: layout.attributes)
                readerDebugLog(
                    "translated block layout: sourceRect=\(block.rect), drawnRect=\(layout.rect), font=\(layout.font.pointSize), merged=\(block.sourceTexts.count)",
                    level: .debug
                )
            }
        }
        readerDebugLog(
            "translated image rendered: overlays=\(overlays.count), blocks=\(blocks.count), size=\(Int(rendered.size.width.rounded()))x\(Int(rendered.size.height.rounded()))",
            level: .info
        )
        return rendered
    }

    private static func mergeOverlaysIntoBlocks(_ overlays: [ReaderTextBlock], imageSize: CGSize) -> [TranslationBlock] {
        let rects = overlays.map { overlay in
            (
                overlay: overlay,
                rect: CGRect(
                    x: overlay.sourceRect.x * imageSize.width,
                    y: overlay.sourceRect.y * imageSize.height,
                    width: max(overlay.sourceRect.width * imageSize.width, 44),
                    height: max(overlay.sourceRect.height * imageSize.height, 24)
                ).integral
            )
        }.sorted { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) < 18 {
                return lhs.rect.minX < rhs.rect.minX
            }
            return lhs.rect.minY < rhs.rect.minY
        }

        var blocks: [TranslationBlock] = []
        for item in rects {
            if let last = blocks.last, shouldMerge(item.rect, into: last.rect) {
                let mergedRect = last.rect.union(item.rect).insetBy(dx: -6, dy: -4)
                let mergedText = [last.text, item.overlay.translatedText ?? item.overlay.sourceText]
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                let mergedSources = last.sourceTexts + [item.overlay.sourceText]
                blocks[blocks.count - 1] = TranslationBlock(
                    rect: clamp(mergedRect.integral, imageSize: imageSize),
                    text: mergedText,
                    sourceTexts: mergedSources
                )
            } else {
                blocks.append(
                    TranslationBlock(
                        rect: clamp(item.rect.insetBy(dx: -4, dy: -2).integral, imageSize: imageSize),
                        text: item.overlay.translatedText ?? item.overlay.sourceText,
                        sourceTexts: [item.overlay.sourceText]
                    )
                )
            }
        }
        readerDebugLog(
            "translation blocks merged: overlays=\(overlays.count), blocks=\(blocks.count)",
            level: .info
        )
        return blocks
    }

    private static func shouldMerge(_ lhs: CGRect, into rhs: CGRect) -> Bool {
        let verticalGap = max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY, 0)
        let horizontalGap = max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX, 0)
        let sameRow = abs(lhs.midY - rhs.midY) <= max(lhs.height, rhs.height) * 0.7
        let overlapsHorizontally = lhs.maxX >= rhs.minX - 16 && rhs.maxX >= lhs.minX - 16
        let overlapsVertically = lhs.maxY >= rhs.minY - 12 && rhs.maxY >= lhs.minY - 12
        return (sameRow && horizontalGap <= 36) || (overlapsHorizontally && verticalGap <= 28) || (overlapsVertically && horizontalGap <= 24)
    }

    private static func layoutRect(for text: String, in originRect: CGRect, imageSize: CGSize) -> (rect: CGRect, attributes: [NSAttributedString.Key: Any], font: UIFont) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        let maxWidth = min(max(originRect.width * 1.8, 72), max(imageSize.width - originRect.minX - 4, 72))
        let fontSizes: [CGFloat] = [16, 15, 14, 13, 12, 11, 10]

        for fontSize in fontSizes {
            let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph
            ]
            let textRect = NSString(string: text).boundingRect(
                with: CGSize(width: maxWidth - 12, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            let candidate = CGRect(
                x: originRect.minX,
                y: originRect.minY,
                width: max(originRect.width, ceil(textRect.width) + 12),
                height: max(originRect.height, ceil(textRect.height) + 8)
            )
            let clamped = clamp(candidate.integral, imageSize: imageSize)
            if clamped.height >= ceil(textRect.height) + 8 {
                return (clamped, attributes, font)
            }
        }

        let font = UIFont.systemFont(ofSize: 10, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        return (clamp(originRect.integral, imageSize: imageSize), attributes, font)
    }

    private static func clamp(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        let width = min(rect.width, imageSize.width)
        let height = min(rect.height, imageSize.height)
        let x = min(max(0, rect.minX), max(imageSize.width - width, 0))
        let y = min(max(0, rect.minY), max(imageSize.height - height, 0))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

final class ReaderDecodedImageStore {
    static let shared = ReaderDecodedImageStore()

    private final class CacheBox {
        let image: UIImage

        init(_ image: UIImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, CacheBox>()

    init() {
        cache.countLimit = 48
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func trim() {
        cache.removeAllObjects()
    }

    func image(
        for request: URLRequest,
        data: Data,
        targetSize: CGSize,
        scale: CGFloat,
        allowOriginalSize: Bool
    ) -> UIImage? {
        let key = cacheKey(for: request, targetSize: targetSize, scale: scale, allowOriginalSize: allowOriginalSize)
        if let cached = cache.object(forKey: key as NSString) {
            return cached.image
        }
        guard let image = decodeImage(
            data: data,
            targetSize: targetSize,
            scale: scale,
            allowOriginalSize: allowOriginalSize
        ) else {
            return nil
        }
        cache.setObject(CacheBox(image), forKey: key as NSString, cost: image.memoryCost)
        return image
    }

    private func cacheKey(
        for request: URLRequest,
        targetSize: CGSize,
        scale: CGFloat,
        allowOriginalSize: Bool
    ) -> String {
        let width = Int(max(targetSize.width, 1).rounded(.up))
        let height = Int(max(targetSize.height, 1).rounded(.up))
        return "\(urlRequestKey(request))|\(width)x\(height)@\(scale)|\(allowOriginalSize)"
    }

    private func decodeImage(
        data: Data,
        targetSize: CGSize,
        scale: CGFloat,
        allowOriginalSize: Bool
    ) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let pixelWidth = max(Int((max(targetSize.width, 1) * scale).rounded(.up)), 1)
        let pixelHeight = max(Int((max(targetSize.height, 1) * scale).rounded(.up)), 1)
        let maxPixelSize = max(allowOriginalSize ? max(pixelWidth, pixelHeight) * 2 : max(pixelWidth, pixelHeight), 1)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        }
        return UIImage(data: data)
    }
}

private extension UIImage {
    var memoryCost: Int {
        guard let cgImage else {
            return Int(size.width * size.height * scale * scale * 4)
        }
        return cgImage.bytesPerRow * cgImage.height
    }
}
