import SwiftUI
import UIKit

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

        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let fitScale = min(widthScale, heightScale)
        let minScale = min(max(fitScale, 0.05), 1)
        let maxScale = max(minScale + 0.01, 4)

        minimumZoomScale = minScale
        maximumZoomScale = maxScale
        if resetToMinimum {
            zoomScale = minScale
        } else {
            zoomScale = min(max(zoomScale, minScale), maxScale)
        }
        contentSize = image.size
        isScrollEnabled = zoomScale > minimumZoomScale + 0.01
        centerImageIfNeeded()
    }

    func centerImageIfNeeded() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else {
            imageView.frame = bounds
            return
        }

        let scaledSize = CGSize(width: image.size.width * zoomScale, height: image.size.height * zoomScale)
        let horizontalInset = max(0, (bounds.width - scaledSize.width) / 2)
        let verticalInset = max(0, (bounds.height - scaledSize.height) / 2)
        contentInset = UIEdgeInsets(top: verticalInset, left: horizontalInset, bottom: verticalInset, right: horizontalInset)

        imageView.frame = CGRect(origin: .zero, size: image.size)
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
