import Foundation
import ImageIO
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct AnimatedImageDecodeLimits: Sendable {
    let maximumFrameCount: Int
    let maximumDecodedBytes: Int
    let maximumPixelDimension: Int

    nonisolated static let thumbnail = AnimatedImageDecodeLimits(
        maximumFrameCount: 160,
        maximumDecodedBytes: 40 * 1024 * 1024,
        maximumPixelDimension: 800
    )

    nonisolated static let reader = AnimatedImageDecodeLimits(
        maximumFrameCount: 240,
        maximumDecodedBytes: 96 * 1024 * 1024,
        maximumPixelDimension: 1_600
    )
}

struct AnimatedImageFrame: @unchecked Sendable {
    let image: PlatformImage
    let duration: TimeInterval
}

final class AnimatedImageAsset: @unchecked Sendable, Identifiable {
    nonisolated let id = UUID()
    nonisolated let frames: [AnimatedImageFrame]
    nonisolated let loopCount: Int
    nonisolated let totalDuration: TimeInterval
    nonisolated private let frameEndTimes: [TimeInterval]

    nonisolated init(frames: [AnimatedImageFrame], loopCount: Int) {
        self.frames = frames
        self.loopCount = max(loopCount, 0)

        var elapsed: TimeInterval = 0
        self.frameEndTimes = frames.map { frame in
            elapsed += frame.duration
            return elapsed
        }
        self.totalDuration = elapsed
    }

    nonisolated var firstImage: PlatformImage? {
        frames.first?.image
    }

    nonisolated func frameIndex(at elapsed: TimeInterval) -> Int {
        guard frames.count > 1, totalDuration > 0 else { return 0 }

        let clampedElapsed = max(elapsed, 0)
        if loopCount > 0, clampedElapsed >= totalDuration * Double(loopCount) {
            return frames.count - 1
        }

        let loopElapsed = clampedElapsed.truncatingRemainder(dividingBy: totalDuration)
        return frameEndTimes.firstIndex(where: { loopElapsed < $0 }) ?? frames.count - 1
    }
}

nonisolated enum AnimatedImageDecoder {
    private static let defaultFrameDuration: TimeInterval = 0.1
    private static let minimumFrameDuration: TimeInterval = 0.02

    static func decodeAsync(
        data: Data,
        targetSize: CGSize,
        scale: CGFloat,
        limits: AnimatedImageDecodeLimits
    ) async -> AnimatedImageAsset? {
        await Task.detached(priority: .userInitiated) {
            decode(data: data, targetSize: targetSize, scale: scale, limits: limits)
        }.value
    }

    static func decode(
        data: Data,
        targetSize: CGSize,
        scale: CGFloat,
        limits: AnimatedImageDecodeLimits
    ) -> AnimatedImageAsset? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        guard isSupportedAnimationSource(source) else { return nil }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1, frameCount <= limits.maximumFrameCount else { return nil }

        let maxPixelSize = decodePixelSize(
            source: source,
            targetSize: targetSize,
            scale: scale,
            maximumPixelDimension: limits.maximumPixelDimension
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        var frames: [AnimatedImageFrame] = []
        frames.reserveCapacity(frameCount)
        var decodedBytes = 0

        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                return nil
            }
            decodedBytes += cgImage.bytesPerRow * cgImage.height
            guard decodedBytes <= limits.maximumDecodedBytes else { return nil }

            #if os(iOS)
            let image = PlatformImage(cgImage: cgImage, scale: max(scale, 1), orientation: .up)
            #elseif os(macOS)
            let image = PlatformImage(
                cgImage: cgImage,
                size: CGSize(width: cgImage.width, height: cgImage.height)
            )
            #endif
            frames.append(AnimatedImageFrame(
                image: image,
                duration: frameDuration(source: source, index: index)
            ))
        }

        return AnimatedImageAsset(frames: frames, loopCount: loopCount(source: source))
    }

    private static func isSupportedAnimationSource(_ source: CGImageSource) -> Bool {
        guard let type = CGImageSourceGetType(source) as String? else { return false }
        return [
            "com.compuserve.gif",
            "org.webmproject.webp",
            "public.heics",
            "public.png"
        ].contains(type)
    }

    private static func decodePixelSize(
        source: CGImageSource,
        targetSize: CGSize,
        scale: CGFloat,
        maximumPixelDimension: Int
    ) -> Int {
        let requested = Int(
            max(targetSize.width, targetSize.height, 1) * max(scale, 1)
        )
        if requested > 1 {
            return min(requested, maximumPixelDimension)
        }

        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return maximumPixelDimension
        }
        return min(max(width, height), maximumPixelDimension)
    }

    private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else {
            return defaultFrameDuration
        }

        let candidates: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime)
        ]

        for (dictionaryKey, unclampedKey, delayKey) in candidates {
            guard let dictionary = properties[dictionaryKey] as? [CFString: Any] else { continue }
            let duration = number(dictionary[unclampedKey]) ?? number(dictionary[delayKey])
            if let duration, duration.isFinite, duration > 0 {
                return max(duration, minimumFrameDuration)
            }
        }
        return defaultFrameDuration
    }

    private static func loopCount(source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] else { return 0 }
        let candidates: [(CFString, CFString)] = [
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount)
        ]
        for (dictionaryKey, loopKey) in candidates {
            if let dictionary = properties[dictionaryKey] as? [CFString: Any],
               let count = number(dictionary[loopKey]) {
                return max(Int(count), 0)
            }
        }
        return 0
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? Double { return value }
        return nil
    }
}

struct AnimatedPlatformImageView: View {
    let asset: AnimatedImageAsset
    var contentMode: ContentMode = .fit

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date.now

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: reduceMotion || scenePhase != .active
        )) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let index = reduceMotion ? 0 : asset.frameIndex(at: elapsed)
            Image(platformImage: asset.frames[index].image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        }
        .onChange(of: asset.id, initial: true) {
            startedAt = .now
        }
    }
}
