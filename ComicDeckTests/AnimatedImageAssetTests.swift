import CoreGraphics
import ImageIO
import XCTest
@testable import ComicDeck

@MainActor
final class AnimatedImageAssetTests: XCTestCase {
    func testDecoderReadsFramesTimingAndLoopCount() throws {
        let data = try makeAnimatedGIF(
            frameDurations: [0.08, 0.16],
            loopCount: 3
        )

        let asset = try XCTUnwrap(AnimatedImageDecoder.decode(
            data: data,
            targetSize: CGSize(width: 12, height: 12),
            scale: 1,
            limits: .thumbnail
        ))

        XCTAssertEqual(asset.frames.count, 2)
        XCTAssertEqual(asset.loopCount, 3)
        XCTAssertEqual(asset.frames[0].duration, 0.08, accuracy: 0.001)
        XCTAssertEqual(asset.frames[1].duration, 0.16, accuracy: 0.001)
        XCTAssertEqual(asset.totalDuration, 0.24, accuracy: 0.001)
    }

    func testFrameSelectionLoopsAndStopsOnFinalFrame() {
        let image = PlatformImage()
        let asset = AnimatedImageAsset(
            frames: [
                AnimatedImageFrame(image: image, duration: 0.1),
                AnimatedImageFrame(image: image, duration: 0.2)
            ],
            loopCount: 2
        )

        XCTAssertEqual(asset.frameIndex(at: 0), 0)
        XCTAssertEqual(asset.frameIndex(at: 0.099), 0)
        XCTAssertEqual(asset.frameIndex(at: 0.1), 1)
        XCTAssertEqual(asset.frameIndex(at: 0.31), 0)
        XCTAssertEqual(asset.frameIndex(at: 0.6), 1)
        XCTAssertEqual(asset.frameIndex(at: 10), 1)
    }

    func testDecoderRejectsAnimationOverFrameLimit() throws {
        let data = try makeAnimatedGIF(
            frameDurations: [0.1, 0.1],
            loopCount: 0
        )
        let limits = AnimatedImageDecodeLimits(
            maximumFrameCount: 1,
            maximumDecodedBytes: 1_000_000,
            maximumPixelDimension: 100
        )

        XCTAssertNil(AnimatedImageDecoder.decode(
            data: data,
            targetSize: CGSize(width: 12, height: 12),
            scale: 1,
            limits: limits
        ))
    }

    func testDecoderRejectsAnimationOverDecodedMemoryLimit() throws {
        let data = try makeAnimatedGIF(
            frameDurations: [0.1, 0.1],
            loopCount: 0
        )
        let limits = AnimatedImageDecodeLimits(
            maximumFrameCount: 10,
            maximumDecodedBytes: 1,
            maximumPixelDimension: 100
        )

        XCTAssertNil(AnimatedImageDecoder.decode(
            data: data,
            targetSize: CGSize(width: 12, height: 12),
            scale: 1,
            limits: limits
        ))
    }

    private func makeAnimatedGIF(frameDurations: [Double], loopCount: Int) throws -> Data {
        let data = NSMutableData()
        let type = "com.compuserve.gif" as CFString
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            type,
            frameDurations.count,
            nil
        ))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopCount
            ]
        ] as CFDictionary)

        for (index, duration) in frameDurations.enumerated() {
            let image = try XCTUnwrap(makeImage(index: index))
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: duration,
                    kCGImagePropertyGIFDelayTime: duration
                ]
            ] as CFDictionary)
        }

        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func makeImage(index: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 12,
            height: 12,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(index == 0
            ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            : CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        return context.makeImage()
    }
}
