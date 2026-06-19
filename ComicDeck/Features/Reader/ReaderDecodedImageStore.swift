import Foundation
import ImageIO

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

final class ReaderDecodedImageStore {
    static let shared = ReaderDecodedImageStore()

    private final class CacheBox {
        let image: PlatformImage

        init(_ image: PlatformImage) {
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
    ) -> PlatformImage? {
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
        cache.setObject(CacheBox(image), forKey: key as NSString, cost: image.platformMemoryCost)
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
    ) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return PlatformImage(data: data)
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
}
