import Foundation
import ImageIO

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ImageCropRegion: Hashable, Sendable {
    let x1: Double?
    let y1: Double?
    let x2: Double?
    let y2: Double?

    nonisolated var cacheKey: String {
        [
            x1.map(Self.format) ?? "",
            y1.map(Self.format) ?? "",
            x2.map(Self.format) ?? "",
            y2.map(Self.format) ?? ""
        ].joined(separator: ",")
    }

    nonisolated static func parse(from urlString: String?) -> ImageCropRegion? {
        guard let urlString else { return nil }
        guard let markerRange = cropMarkerRange(in: urlString) else { return nil }
        let parameterText = String(urlString[markerRange.lowerBound...].dropFirst())
        var x1: Double?
        var y1: Double?
        var x2: Double?
        var y2: Double?

        for parameter in parameterText.split(separator: "&") {
            let parts = parameter.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let axis = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let range = parts[1].split(separator: "-", maxSplits: 1)
            guard range.count == 2,
                  let start = Double(range[0]),
                  let end = Double(range[1]),
                  end > start
            else {
                continue
            }
            switch axis {
            case "x":
                x1 = start
                x2 = end
            case "y":
                y1 = start
                y2 = end
            default:
                continue
            }
        }

        guard x1 != nil || y1 != nil else { return nil }
        return ImageCropRegion(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    nonisolated static func stripMarker(from urlString: String) -> String {
        guard let markerRange = cropMarkerRange(in: urlString) else {
            return urlString
        }
        return String(urlString[..<markerRange.lowerBound])
    }

    nonisolated fileprivate func pixelRect(sourceWidth: Int, sourceHeight: Int) -> CGRect? {
        let minX = max(0, min(Double(sourceWidth), x1 ?? 0))
        let minY = max(0, min(Double(sourceHeight), y1 ?? 0))
        let maxX = max(minX, min(Double(sourceWidth), x2 ?? Double(sourceWidth)))
        let maxY = max(minY, min(Double(sourceHeight), y2 ?? Double(sourceHeight)))
        let width = maxX - minX
        let height = maxY - minY
        guard width > 1, height > 1 else { return nil }
        return CGRect(
            x: minX.rounded(.down),
            y: minY.rounded(.down),
            width: width.rounded(.up),
            height: height.rounded(.up)
        )
    }

    private nonisolated static func cropMarkerRange(in value: String) -> Range<String.Index>? {
        value.range(of: "@x=") ?? value.range(of: "@y=")
    }

    private nonisolated static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}

final class ReaderDecodedImageStore {
    static let shared = ReaderDecodedImageStore()

    private final class CacheBox {
        let image: PlatformImage

        init(_ image: PlatformImage) {
            self.image = image
        }
    }

    private let cache = NSCache<NSString, CacheBox>()
    private let inFlightLock = NSLock()
    private var inFlightDecodes: [String: (id: UUID, task: Task<PlatformImage?, Never>)] = [:]

    init() {
        cache.countLimit = 48
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    func trim() {
        cache.removeAllObjects()
    }

    func removeImage(
        for request: URLRequest,
        targetSize: CGSize,
        scale: CGFloat,
        allowOriginalSize: Bool,
        cropRegion: ImageCropRegion? = nil
    ) {
        let key = Self.cacheKey(
            for: request,
            targetSize: targetSize,
            scale: scale,
            allowOriginalSize: allowOriginalSize,
            cropRegion: cropRegion
        )
        cache.removeObject(forKey: key as NSString)
    }

    func image(
        for request: URLRequest,
        data: Data,
        targetSize: CGSize,
        scale: CGFloat,
        allowOriginalSize: Bool,
        cropRegion: ImageCropRegion? = nil
    ) -> PlatformImage? {
        let key = Self.cacheKey(
            for: request,
            targetSize: targetSize,
            scale: scale,
            allowOriginalSize: allowOriginalSize,
            cropRegion: cropRegion
        )
        if let cached = cache.object(forKey: key as NSString) {
            return cached.image
        }
        guard let image = Self.decodeImage(
            data: data,
            targetSize: targetSize,
            scale: scale,
            allowOriginalSize: allowOriginalSize,
            cropRegion: cropRegion
        ) else {
            return nil
        }
        cache.setObject(CacheBox(image), forKey: key as NSString, cost: image.platformMemoryCost)
        return image
    }

    func imageAsync(
        for request: URLRequest,
        data: Data,
        targetSize: CGSize,
        scale: CGFloat,
        allowOriginalSize: Bool,
        cropRegion: ImageCropRegion? = nil
    ) async -> PlatformImage? {
        let key = Self.cacheKey(
            for: request,
            targetSize: targetSize,
            scale: scale,
            allowOriginalSize: allowOriginalSize,
            cropRegion: cropRegion
        )
        if let cached = cache.object(forKey: key as NSString) {
            return cached.image
        }
        if let task = decodeTask(forKey: key) {
            return await task.value
        }

        let taskID = UUID()
        let task = Task.detached(priority: .userInitiated) { [data, targetSize, scale, allowOriginalSize, cropRegion] in
            Self.decodeImage(
                data: data,
                targetSize: targetSize,
                scale: scale,
                allowOriginalSize: allowOriginalSize,
                cropRegion: cropRegion
            )
        }
        setDecodeTask(task, id: taskID, forKey: key)
        let image = await task.value
        removeDecodeTask(forKey: key, id: taskID)
        guard let image else { return nil }
        cache.setObject(CacheBox(image), forKey: key as NSString, cost: image.platformMemoryCost)
        return image
    }

    private func decodeTask(forKey key: String) -> Task<PlatformImage?, Never>? {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlightDecodes[key]?.task
    }

    private func setDecodeTask(_ task: Task<PlatformImage?, Never>, id: UUID, forKey key: String) {
        inFlightLock.lock()
        inFlightDecodes[key] = (id, task)
        inFlightLock.unlock()
    }

    private func removeDecodeTask(forKey key: String, id: UUID) {
        inFlightLock.lock()
        if inFlightDecodes[key]?.id == id {
            inFlightDecodes[key] = nil
        }
        inFlightLock.unlock()
    }

    private nonisolated static func cacheKey(
        for request: URLRequest,
        targetSize: CGSize,
        scale: CGFloat,
        allowOriginalSize: Bool,
        cropRegion: ImageCropRegion?
    ) -> String {
        let width = Int(max(targetSize.width, 1).rounded(.up))
        let height = Int(max(targetSize.height, 1).rounded(.up))
        return "\(cacheResourceKey(for: request))|\(width)x\(height)@\(scale)|\(allowOriginalSize)|crop=\(cropRegion?.cacheKey ?? "none")"
    }

    private nonisolated static func cacheResourceKey(for request: URLRequest) -> String {
        RequestCacheKeyBuilder.sharedImageResourceKey(for: request) ?? urlRequestKey(request)
    }

    private nonisolated static func decodeImage(
        data: Data,
        targetSize: CGSize,
        scale: CGFloat,
        allowOriginalSize: Bool,
        cropRegion: ImageCropRegion?
    ) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return PlatformImage(data: data)
        }

        if let cropRegion,
           let image = decodeCroppedImage(source: source, cropRegion: cropRegion, scale: scale) {
            return image
        }

        let pixelWidth = max(Int((max(targetSize.width, 1) * scale).rounded(.up)), 1)
        let pixelHeight = max(Int((max(targetSize.height, 1) * scale).rounded(.up)), 1)

        let maxPixelSize: Int
        if allowOriginalSize, targetSize == .zero {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let srcWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                  let srcHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
                return PlatformImage(data: data)
            }
            maxPixelSize = max(srcWidth, srcHeight)
        } else {
            maxPixelSize = max(allowOriginalSize ? max(pixelWidth, pixelHeight) * 2 : max(pixelWidth, pixelHeight), 1)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            #if os(iOS)
            return PlatformImage(cgImage: cgImage, scale: scale, orientation: .up)
            #elseif os(macOS)
            return PlatformImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
            #endif
        }
        return PlatformImage(data: data)
    }

    private nonisolated static func decodeCroppedImage(
        source: CGImageSource,
        cropRegion: ImageCropRegion,
        scale: CGFloat
    ) -> PlatformImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary),
              let cropRect = cropRegion.pixelRect(sourceWidth: cgImage.width, sourceHeight: cgImage.height),
              let cropped = cgImage.cropping(to: cropRect)
        else {
            return nil
        }

        #if os(iOS)
        return PlatformImage(cgImage: cropped, scale: scale, orientation: .up)
        #elseif os(macOS)
        return PlatformImage(cgImage: cropped, size: CGSize(width: cropped.width, height: cropped.height))
        #endif
    }
}
