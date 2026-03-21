import SwiftUI
import UIKit
import ImageIO

struct ReaderCanvasView: View {
    let imageRequests: [ImageRequest?]
    let readerMode: ReaderMode
    let reloadNonce: Int
    let animatePageTransitions: Bool
    @Binding var currentPage: Int
    @Binding var verticalPageFrames: [Int: CGRect]
    @Binding var verticalViewportHeight: CGFloat
    @Binding var verticalScrollTarget: Int?
    @Binding var verticalTrackingSuspendedUntil: Date
    let onUpdateCurrentPageFromVerticalLayout: () -> Void

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
                    supportsZoom: true
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
                            request: shouldLoadPage(at: idx) ? request : nil,
                            nonce: reloadNonce,
                            supportsZoom: false
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
                    verticalPageFrames = frames
                    onUpdateCurrentPageFromVerticalLayout()
                }
                .onChange(of: verticalScrollTarget) { _, target in
                    guard let target else { return }
                    if animatePageTransitions {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                    } else {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    let hold = Date().addingTimeInterval(0.35)
                    if verticalTrackingSuspendedUntil < hold {
                        verticalTrackingSuspendedUntil = hold
                    }
                }
                .onAppear {
                    verticalViewportHeight = max(1, viewportHeight)
                    verticalScrollTarget = currentPage
                }
                .onChange(of: viewportHeight) { _, value in
                    verticalViewportHeight = max(1, value)
                    onUpdateCurrentPageFromVerticalLayout()
                }
            }
            .background(Color.black)
            .coordinateSpace(name: "verticalReaderViewport")
        }
    }

    private func shouldLoadPage(at index: Int) -> Bool {
        let radius = readerMode == .vertical ? verticalLoadRadius : horizontalLoadRadius
        return abs(index - currentPage) <= radius
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

    var body: some View {
        ZStack {
            if let request {
                if let urlRequest = buildURLRequest(from: request) {
                    Group {
                        if supportsZoom {
                            ZoomableRemoteImage(request: urlRequest)
                        } else {
                            PlainRemoteImage(request: urlRequest)
                        }
                    }
                    .id("\(pageIndex)-\(nonce)-\(imageRequestKey(request))")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                ReaderPagePlaceholderView(pageIndex: pageIndex)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

private struct ReaderPagePlaceholderView: View {
    let pageIndex: Int

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(AppLocalization.format("reader.loading.page", "Loading page %lld", Int64(pageIndex + 1)))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct PlainRemoteImage: View {
    let request: URLRequest
    @State private var uiImage: UIImage?
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        GeometryReader { proxy in
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
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: "\(urlRequestKey(request))|\(Int(proxy.size.width.rounded()))x\(Int(proxy.size.height.rounded()))") {
                await load(targetSize: proxy.size)
            }
        }
    }

    private func load(targetSize: CGSize) async {
        if loading { return }
        loading = true
        defer { loading = false }
        errorText = nil
        uiImage = nil
        do {
            let data = try await ReaderImagePipeline.shared.loadData(for: request)
            guard let image = ReaderDecodedImageStore.shared.image(
                for: request,
                data: data,
                targetSize: targetSize,
                scale: UIScreen.main.scale,
                allowOriginalSize: false
            ) else {
                throw ReaderImagePipelineError.invalidResponse
            }
            uiImage = image
        } catch {
            errorText = error.localizedDescription
            readerDebugLog("plain image request error: \(error.localizedDescription), url=\(request.url?.absoluteString ?? "")", level: .error)
        }
    }
}

struct ZoomableRemoteImage: UIViewRepresentable {
    let request: URLRequest

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView()
        context.coordinator.attach(view)
        context.coordinator.load(request)
        return view
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        context.coordinator.attach(uiView)
        context.coordinator.load(request)
    }

    static func dismantleUIView(_ uiView: ZoomingImageScrollView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    final class Coordinator: NSObject {
        private weak var view: ZoomingImageScrollView?
        private var loadTask: Task<Void, Never>?
        private var currentKey = ""

        func attach(_ view: ZoomingImageScrollView) {
            guard self.view !== view else { return }
            self.view = view
            view.doubleTapRecognizer.addTarget(self, action: #selector(handleDoubleTap(_:)))
        }

        func load(_ request: URLRequest) {
            let key = urlRequestKey(request)
            guard key != currentKey else { return }
            currentKey = key
            cancel()
            view?.setLoading(true)
            loadTask = Task {
                do {
                    let data = try await ReaderImagePipeline.shared.loadData(for: request)
                    guard !Task.isCancelled else { return }
                    let targetSize = await MainActor.run {
                        self.view?.bounds.size ?? .zero
                    }
                    guard let image = ReaderDecodedImageStore.shared.image(
                        for: request,
                        data: data,
                        targetSize: targetSize,
                        scale: UIScreen.main.scale,
                        allowOriginalSize: true
                    ) else {
                        throw ReaderImagePipelineError.invalidResponse
                    }
                    await MainActor.run {
                        self.view?.setImage(image)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.view?.setError("Failed to load image")
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
