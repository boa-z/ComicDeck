import SwiftUI
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
        private var lastRenderedBaseImage: UIImage?
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

            let image = ReaderTranslatedImageRenderer.render(baseImage, overlays: overlays)
            view.setImage(image)
            readerDebugLog(
                "zoom translated image ready: overlays=\(overlays.count), size=\(Int(image.size.width.rounded()))x\(Int(image.size.height.rounded()))",
                level: .info
            )
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
    var baseImage: UIImage?
    private var lastBoundsSize: CGSize = .zero
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
            lastBoundsSize = bounds.size
            recalculateZoomScales(resetToMinimum: false)
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

        imageView.transform = .identity
        imageView.frame = CGRect(origin: .zero, size: image.size)
        contentSize = image.size

        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let fitScale = min(widthScale, heightScale)
        let minScale = min(max(fitScale, 0.05), 1)
        let maxScale = max(minScale * 4, minScale + 0.01)

        minimumZoomScale = minScale
        maximumZoomScale = maxScale
        if resetToMinimum {
            zoomScale = minScale
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
