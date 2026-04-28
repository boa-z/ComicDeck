import UIKit
import ImageIO

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
