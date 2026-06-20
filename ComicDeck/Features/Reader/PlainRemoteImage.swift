import SwiftUI
import ImageIO

struct PlainRemoteImage: View {
    let request: URLRequest
    let overlays: [ReaderTextBlock]
    @State private var uiImage: PlatformImage?
    @State private var imageSize: CGSize?
    @State private var errorText: String?
    @State private var loading = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let uiImage {
                Image(platformImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.yellow)
                    Text(AppLocalization.text("reader.error.image_load_failed", "Failed to load image"))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(errorText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(3)
                }
                .padding()
            } else {
                imageSkeleton
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(ReaderPlainImageLayout.displayAspectRatio(for: imageSize ?? uiImage?.platformSize), contentMode: .fit)
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

    private var imageSkeleton: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 104, height: 144)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 5) {
                        Capsule()
                            .fill(.white.opacity(0.12))
                            .frame(width: 68, height: 6)
                        Capsule()
                            .fill(.white.opacity(0.09))
                            .frame(width: 46, height: 6)
                    }
                    .padding(.bottom, 18)
                }

            Text(AppLocalization.text("reader.loading.image", "Loading image..."))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.46))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                imageSize: sourceSize ?? imageSize ?? uiImage?.platformSize
            )
            readerDebugLog(
                "plain image load start: url=\(request.url?.absoluteString ?? "nil"), isFile=\(request.url?.isFileURL == true), width=\(Int(containerWidth.rounded())), source=\(Int(sourceSize?.width ?? 0))x\(Int(sourceSize?.height ?? 0)), target=\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))",
                level: .debug
            )
            guard let baseImage = await ReaderDecodedImageStore.shared.imageAsync(
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
            let image = await ReaderTranslatedImageRenderer.renderAsync(baseImage, overlays: overlays)
            imageSize = baseImage.platformSize
            uiImage = image
            readerDebugLog(
                "plain translated image ready: overlays=\(overlays.count), size=\(Int(image.platformSize.width))x\(Int(image.platformSize.height))",
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

nonisolated enum ReaderPlainImageLayout {
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
