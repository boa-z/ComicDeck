import SwiftUI

#if os(iOS)
import UIKit

struct ZoomableRemoteImage: UIViewRepresentable {
    let request: URLRequest
    let overlays: [ReaderTextBlock]
    var displayScale: CGFloat = 2.0
    var onLongPressZoomStart: ((CGPoint) -> Void)?
    var onLongPressZoomEnd: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(displayScale: displayScale)
    }

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView()
        context.coordinator.attach(view)
        view.setOverlays(overlays)
        view.onLongPressZoomStart = onLongPressZoomStart
        view.onLongPressZoomEnd = onLongPressZoomEnd
        context.coordinator.load(request)
        return view
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        context.coordinator.attach(uiView)
        uiView.setOverlays(overlays)
        uiView.onLongPressZoomStart = onLongPressZoomStart
        uiView.onLongPressZoomEnd = onLongPressZoomEnd
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
        private var lastRenderedBaseImage: PlatformImage?
        private var lastRenderedOverlays: [ReaderTextBlock]?
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
            loadTask = Task.detached(priority: .userInitiated) { [weak self, displayScale] in
                do {
                    let data = try await ReaderImagePipeline.shared.loadData(for: request, priority: .visible)
                    try Task.checkCancellation()
                    let targetSize = await MainActor.run {
                        self?.view?.bounds.size ?? .zero
                    }
                    try Task.checkCancellation()
                    guard let baseImage = await ReaderDecodedImageStore.shared.imageAsync(
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
                        self?.view?.setError(AppLocalization.text("reader.error.image_load_failed", "Failed to load image"))
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
            guard lastRenderedBaseImage !== baseImage || lastRenderedOverlays != overlays || view.imageView.image == nil else { return }
            lastRenderedBaseImage = baseImage
            lastRenderedOverlays = overlays

            Task { [weak self] in
                let image = await ReaderTranslatedImageRenderer.renderAsync(baseImage, overlays: overlays)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.view?.setImage(image)
                }
                readerDebugLog(
                    "zoom translated image ready: overlays=\(overlays.count), size=\(Int(image.platformSize.width.rounded()))x\(Int(image.platformSize.height.rounded()))",
                    level: .info
                )
            }
        }

        @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            view.toggleZoom(at: recognizer.location(in: view.imageView))
        }
    }
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    let imageView = UIImageView()
    let doubleTapRecognizer = UITapGestureRecognizer()
    private let longPressRecognizer = UILongPressGestureRecognizer()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private let errorLabel = UILabel()
    var currentOverlays: [ReaderTextBlock] = []
    var baseImage: PlatformImage?
    private var lastBoundsSize: CGSize = .zero
    private var shouldResetZoomOnNextLayout = false
    var onLongPressZoomStart: ((CGPoint) -> Void)?
    var onLongPressZoomEnd: (() -> Void)?
    private var isLongPressZoomed = false

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
        isScrollEnabled = true

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        addSubview(loadingIndicator)

        loadingLabel.text = AppLocalization.text("reader.loading.image", "Loading image...")
        loadingLabel.textColor = UIColor.white.withAlphaComponent(0.56)
        loadingLabel.font = .preferredFont(forTextStyle: .caption2)
        loadingLabel.textAlignment = .center
        loadingLabel.isHidden = true
        addSubview(loadingLabel)

        errorLabel.textColor = .white
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 2
        errorLabel.isHidden = true
        addSubview(errorLabel)

        doubleTapRecognizer.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTapRecognizer)

        longPressRecognizer.minimumPressDuration = 0.25
        longPressRecognizer.addTarget(self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPressRecognizer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBoundsSize {
            let shouldStayFitted = shouldResetZoomOnNextLayout || abs(zoomScale - minimumZoomScale) < 0.01
            lastBoundsSize = bounds.size
            recalculateZoomScales(resetToMinimum: shouldStayFitted)
        }
        loadingIndicator.center = CGPoint(x: bounds.midX, y: bounds.midY - 12)
        loadingLabel.frame = CGRect(x: 20, y: bounds.midY + 8, width: max(0, bounds.width - 40), height: 24)
        errorLabel.frame = CGRect(x: 20, y: bounds.midY - 20, width: max(0, bounds.width - 40), height: 40)
        centerImageIfNeeded()
    }

    func setLoading(_ loading: Bool) {
        if loading {
            errorLabel.isHidden = true
            loadingLabel.isHidden = false
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
            loadingLabel.isHidden = true
        }
    }

    func setImage(_ image: PlatformImage) {
        imageView.image = image
        errorLabel.isHidden = true
        setLoading(false)
        contentOffset = .zero
        contentInset = .zero
        shouldResetZoomOnNextLayout = true
        recalculateZoomScales(resetToMinimum: true)
    }

    func setBaseImage(_ image: PlatformImage) {
        baseImage = image
    }

    func setError(_ text: String) {
        setLoading(false)
        imageView.image = nil
        errorLabel.text = text.isEmpty ? AppLocalization.text("reader.error.image_load_failed", "Failed to load image") : text
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
        guard bounds.width > 0, bounds.height > 0 else {
            imageView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            shouldResetZoomOnNextLayout = true
            return
        }

        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size

        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let fitScale = min(widthScale, heightScale)
        let minScale = max(fitScale, 0.001)
        let maxScale = max(minScale * 4, minScale + 0.01)

        minimumZoomScale = minScale
        maximumZoomScale = maxScale
        if resetToMinimum {
            zoomScale = minScale
            shouldResetZoomOnNextLayout = false
        } else {
            zoomScale = min(max(zoomScale, minScale), maxScale)
        }
        isScrollEnabled = true
        centerImageIfNeeded()
    }

    func centerImageIfNeeded() {
        guard imageView.image != nil else {
            imageView.frame = bounds
            return
        }

        let horizontalInset = max(0, (bounds.width - contentSize.width) / 2)
        let verticalInset = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        isScrollEnabled = true
        centerImageIfNeeded()
    }

    func setOverlays(_ overlays: [ReaderTextBlock]) {
        currentOverlays = overlays
        readerDebugLog(
            "zoom translated image payload updated: overlays=\(overlays.count)",
            level: .info
        )
    }

    func toggleZoom(at point: CGPoint) {
        guard imageView.image != nil else { return }
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            zoom(to: zoomRect(for: targetZoomScale(multiplier: 2.0), center: point), animated: true)
        }
    }

    private func targetZoomScale(multiplier: CGFloat) -> CGFloat {
        min(maximumZoomScale, max(minimumZoomScale * multiplier, minimumZoomScale + 0.01))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            guard !isLongPressZoomed else { return }
            isLongPressZoomed = true
            let point = recognizer.location(in: imageView)
            zoom(to: zoomRect(for: targetZoomScale(multiplier: 1.75), center: point), animated: true)
            onLongPressZoomStart?(point)
        case .ended, .cancelled, .failed:
            guard isLongPressZoomed else { return }
            isLongPressZoomed = false
            setZoomScale(minimumZoomScale, animated: true)
            onLongPressZoomEnd?()
        default:
            break
        }
    }

    private func zoomRect(for scale: CGFloat, center: CGPoint) -> CGRect {
        let width = bounds.width / scale
        let height = bounds.height / scale
        return CGRect(x: center.x - width * 0.5, y: center.y - height * 0.5, width: width, height: height)
    }
}
#elseif os(macOS)
import AppKit
import ImageIO

/// macOS zoomable image wrapper.
///
/// Backed by `NSScrollView` (via `NSViewRepresentable`) rather than a SwiftUI
/// `ScrollView` + `.scaleEffect` + `MagnifyGesture` stack. The previous SwiftUI
/// implementation created a layout-solve feedback loop — the `ScrollView`
/// content size depended on the `Image` size, which depended on the
/// `.frame(maxWidth/maxHeight: .infinity)`, which depended on the scroll view,
/// driving the main thread to ~100% CPU whenever the reader was visible.
///
/// `NSScrollView.magnification` provides native trackpad pinch + ⌥-scroll zoom
/// with a stable layout, mirroring the iOS `UIScrollView`-based implementation
/// in the `#if os(iOS)` block above.
@MainActor
struct ZoomableRemoteImage: NSViewRepresentable {
    let request: URLRequest
    let overlays: [ReaderTextBlock]
    var displayScale: CGFloat = 2.0
    var onLongPressZoomStart: ((CGPoint) -> Void)?
    var onLongPressZoomEnd: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(displayScale: displayScale)
    }

    func makeNSView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView()
        context.coordinator.attach(view)
        view.setOverlays(overlays)
        view.onLongPressZoomStart = onLongPressZoomStart
        view.onLongPressZoomEnd = onLongPressZoomEnd
        context.coordinator.load(request)
        return view
    }

    func updateNSView(_ nsView: ZoomingImageScrollView, context: Context) {
        context.coordinator.attach(nsView)
        nsView.setOverlays(overlays)
        nsView.onLongPressZoomStart = onLongPressZoomStart
        nsView.onLongPressZoomEnd = onLongPressZoomEnd
        context.coordinator.updateRenderedImageIfNeeded()
        context.coordinator.load(request)
    }

    static func dismantleNSView(_ nsView: ZoomingImageScrollView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var view: ZoomingImageScrollView?
        private var loadTask: Task<Void, Never>?
        private var currentKey = ""
        private var currentRequest: URLRequest?
        private var lastRenderedBaseImage: PlatformImage?
        private var lastRenderedOverlays: [ReaderTextBlock]?
        private let displayScale: CGFloat

        init(displayScale: CGFloat) {
            self.displayScale = max(1, displayScale)
            super.init()
        }

        func attach(_ view: ZoomingImageScrollView) {
            guard self.view !== view else { return }
            self.view = view
            view.doubleClickRecognizer.target = self
            view.doubleClickRecognizer.action = #selector(handleDoubleClick(_:))
            view.longPressRecognizer.target = self
            view.longPressRecognizer.action = #selector(handleLongPress(_:))
        }

        func load(_ request: URLRequest) {
            let key = urlRequestKey(request)
            currentRequest = request
            guard key != currentKey else { return }
            currentKey = key
            cancel()
            lastRenderedBaseImage = nil
            lastRenderedOverlays = nil
            view?.baseImage = nil
            view?.imageView.image = nil
            view?.setLoading(true)
            loadTask = Task.detached(priority: .userInitiated) { [weak self, displayScale] in
                do {
                    let data = try await ReaderImagePipeline.shared.loadData(for: request, priority: .visible)
                    try Task.checkCancellation()
                    let viewportSize = await MainActor.run {
                        self?.view?.contentView.bounds.size ?? self?.view?.bounds.size ?? .zero
                    }
                    try Task.checkCancellation()
                    let sourceSize = Self.imageSourceSize(from: data)
                    let resolvedTarget = Self.decodeTargetSize(
                        viewportSize: viewportSize,
                        sourceSize: sourceSize
                    )
                    readerDebugLog(
                        "macOS image load start: url=\(request.url?.absoluteString ?? "nil"), bytes=\(data.count), viewport=\(Int(viewportSize.width.rounded()))x\(Int(viewportSize.height.rounded())), source=\(Int(sourceSize?.width ?? 0))x\(Int(sourceSize?.height ?? 0)), target=\(Int(resolvedTarget.width.rounded()))x\(Int(resolvedTarget.height.rounded()))",
                        level: .debug
                    )
                    guard let baseImage = await ReaderDecodedImageStore.shared.imageAsync(
                        for: request,
                        data: data,
                        targetSize: resolvedTarget,
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
                        self?.view?.setError(AppLocalization.text("reader.error.image_load_failed", "Failed to load image"))
                    }
                    readerDebugLog(
                        "macOS image request error: \(error.localizedDescription), url=\(request.url?.absoluteString ?? "")",
                        level: .error
                    )
                }
            }
        }

        private nonisolated static func decodeTargetSize(
            viewportSize: CGSize,
            sourceSize: CGSize?
        ) -> CGSize {
            guard viewportSize.width > 1, viewportSize.height > 1 else {
                return .zero
            }
            guard let sourceSize, sourceSize.width > 0, sourceSize.height > 0 else {
                return viewportSize
            }
            let widthScale = viewportSize.width / sourceSize.width
            let heightScale = viewportSize.height / sourceSize.height
            let fitScale = max(min(widthScale, heightScale), 0.001)
            return CGSize(
                width: max(sourceSize.width * fitScale, 1),
                height: max(sourceSize.height * fitScale, 1)
            )
        }

        private nonisolated static func imageSourceSize(from data: Data) -> CGSize? {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
                  width > 0,
                  height > 0 else {
                return nil
            }
            return CGSize(width: width, height: height)
        }

        func cancel() {
            loadTask?.cancel()
            loadTask = nil
        }

        @MainActor
        func updateRenderedImageIfNeeded() {
            guard let view, let baseImage = view.baseImage else { return }
            let overlays = view.currentOverlays
            guard lastRenderedBaseImage !== baseImage || lastRenderedOverlays != overlays || view.imageView.image == nil else { return }
            let shouldResetViewport = lastRenderedBaseImage !== baseImage || view.imageView.image == nil
            lastRenderedBaseImage = baseImage
            lastRenderedOverlays = overlays

            Task { [weak self] in
                let image = await ReaderTranslatedImageRenderer.renderAsync(baseImage, overlays: overlays)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.view?.setImage(image, resetViewport: shouldResetViewport)
                }
                readerDebugLog(
                    "macOS zoom translated image ready: overlays=\(overlays.count), size=\(Int(image.platformSize.width.rounded()))x\(Int(image.platformSize.height.rounded()))",
                    level: .info
                )
            }
        }

        @objc private func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let view else { return }
            let location = recognizer.location(in: view.imageView)
            view.toggleZoom(at: location)
        }

        @objc private func handleLongPress(_ recognizer: NSPressGestureRecognizer) {
            guard let view else { return }
            switch recognizer.state {
            case .began:
                let point = recognizer.location(in: view.imageView)
                view.beginLongPressZoom(at: point)
                view.onLongPressZoomStart?(point)
            case .ended, .cancelled, .failed:
                view.endLongPressZoom()
                view.onLongPressZoomEnd?()
            default:
                break
            }
        }
    }
}

/// macOS counterpart of the iOS `ZoomingImageScrollView` (UIScrollView subclass).
///
/// Uses `NSScrollView.magnification` for zoom, which decouples content layout
/// from the scroll geometry and eliminates the SwiftUI layout feedback loop.
final class ZoomingImageScrollView: NSScrollView {
    let imageView = NSImageView()
    let doubleClickRecognizer = NSClickGestureRecognizer()
    let longPressRecognizer = NSPressGestureRecognizer()
    private let loadingIndicator = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    var currentOverlays: [ReaderTextBlock] = []
    var baseImage: PlatformImage?
    private var lastBoundsSize: CGSize = .zero
    private var isLongPressZoomed = false
    private var longPressRestoreMagnification: CGFloat = 1
    var onLongPressZoomStart: ((CGPoint) -> Void)?
    var onLongPressZoomEnd: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .black
        drawsBackground = true
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .allowed
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 4

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.translatesAutoresizingMaskIntoConstraints = true
        imageView.autoresizingMask = []
        documentView = imageView

        // Gestures attach to the clip view so they keep working while zoomed.
        doubleClickRecognizer.numberOfClicksRequired = 2
        doubleClickRecognizer.delaysPrimaryMouseButtonEvents = false
        contentView.addGestureRecognizer(doubleClickRecognizer)

        longPressRecognizer.minimumPressDuration = 0.25
        longPressRecognizer.allowableMovement = 8
        contentView.addGestureRecognizer(longPressRecognizer)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingIndicator)

        loadingLabel.stringValue = AppLocalization.text("reader.loading.image", "Loading image...")
        loadingLabel.textColor = NSColor.white.withAlphaComponent(0.56)
        loadingLabel.font = .preferredFont(forTextStyle: .caption2)
        loadingLabel.alignment = .center
        loadingLabel.isBezeled = false
        loadingLabel.drawsBackground = false
        loadingLabel.isSelectable = false
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingLabel.isHidden = true
        addSubview(loadingLabel)

        errorLabel.textColor = .white
        errorLabel.font = .preferredFont(forTextStyle: .caption1)
        errorLabel.alignment = .center
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isBezeled = false
        errorLabel.drawsBackground = false
        errorLabel.isSelectable = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.cell?.truncatesLastVisibleLine = true
        errorLabel.cell?.wraps = true
        errorLabel.isHidden = true
        addSubview(errorLabel)

        NSLayoutConstraint.activate([
            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            loadingLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            loadingLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            loadingLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 8),
            errorLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    override func layout() {
        super.layout()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            recalculateMagnificationScales()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        recalculateMagnificationScales()
    }

    func setLoading(_ loading: Bool) {
        if loading {
            errorLabel.isHidden = true
            loadingLabel.isHidden = false
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
            loadingLabel.isHidden = true
        }
    }

    func setImage(_ image: PlatformImage, resetViewport: Bool = true) {
        imageView.image = image
        errorLabel.isHidden = true
        setLoading(false)
        if resetViewport {
            contentView.setBoundsOrigin(.zero)
            shouldResetZoomOnNextLayout = true
        }
        recalculateMagnificationScales(resetToMin: resetViewport)
    }

    func setBaseImage(_ image: PlatformImage) {
        baseImage = image
    }

    func setError(_ text: String) {
        setLoading(false)
        imageView.image = nil
        errorLabel.stringValue = text.isEmpty
            ? AppLocalization.text("reader.error.image_load_failed", "Failed to load image")
            : text
        errorLabel.isHidden = false
        magnification = 1
        minMagnification = 1
        maxMagnification = 1
    }

    private var shouldResetZoomOnNextLayout = false

    private func recalculateMagnificationScales(resetToMin: Bool = false) {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = bounds
            minMagnification = 1
            maxMagnification = 1
            magnification = 1
            return
        }
        guard bounds.width > 0, bounds.height > 0 else {
            imageView.frame = NSRect(origin: .zero, size: image.size)
            shouldResetZoomOnNextLayout = true
            return
        }

        // Size the document view to the image's natural dimensions; magnification
        // drives the on-screen scale independently (no frame/scale feedback).
        imageView.frame = NSRect(origin: .zero, size: image.size)

        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let fitScale = max(min(widthScale, heightScale), 0.001)
        let minScale = fitScale
        let maxScale = max(fitScale * 4, fitScale + 0.01)

        maxMagnification = maxScale
        minMagnification = minScale
        if resetToMin || shouldResetZoomOnNextLayout {
            magnification = minScale
            centerContentInView(atMinScale: minScale)
            shouldResetZoomOnNextLayout = false
        } else {
            magnification = min(max(magnification, minScale), maxScale)
        }
    }

    private func centerContentInView(atMinScale minScale: CGFloat) {
        guard let image = imageView.image else { return }
        let scaledWidth = image.size.width * minScale
        let scaledHeight = image.size.height * minScale
        let horizontalInset = max(0, (bounds.width - scaledWidth) / 2)
        let verticalInset = max(0, (bounds.height - scaledHeight) / 2)
        contentView.setBoundsOrigin(NSPoint(
            x: -horizontalInset / minScale,
            y: -verticalInset / minScale
        ))
    }

    func setOverlays(_ overlays: [ReaderTextBlock]) {
        guard currentOverlays != overlays else { return }
        currentOverlays = overlays
        readerDebugLog(
            "macOS zoom translated image payload updated: overlays=\(overlays.count)",
            level: .info
        )
    }

    func toggleZoom(at point: CGPoint) {
        guard imageView.image != nil else { return }
        let anchor = contentViewAnchor(forDocumentPoint: point)
        if magnification > minMagnification + 0.01 {
            setMagnification(minMagnification, centeredAt: anchor)
        } else {
            let target = min(maxMagnification, max(minMagnification * 2.0, minMagnification + 0.01))
            setMagnification(target, centeredAt: anchor)
        }
    }

    func beginLongPressZoom(at point: CGPoint) {
        guard imageView.image != nil, !isLongPressZoomed else { return }
        isLongPressZoomed = true
        longPressRestoreMagnification = magnification
        let target = min(maxMagnification, max(minMagnification * 1.75, minMagnification + 0.01))
        let anchor = contentViewAnchor(forDocumentPoint: point)
        setMagnification(target, centeredAt: anchor)
    }

    func endLongPressZoom() {
        guard isLongPressZoomed else { return }
        isLongPressZoomed = false
        let target = max(minMagnification, min(longPressRestoreMagnification, maxMagnification))
        // Anchor at the current visible center so the view does not jump.
        let anchor = NSPoint(
            x: contentView.bounds.midX,
            y: contentView.bounds.midY
        )
        setMagnification(target, centeredAt: anchor)
    }

    /// Converts a point in the document view (`imageView`) coordinate space to
    /// the contentView coordinate space expected by `setMagnification(_:centeredAt:)`.
    private func contentViewAnchor(forDocumentPoint point: CGPoint) -> CGPoint {
        contentView.convert(point, from: imageView)
    }
}
#endif
