import CoreGraphics
import ImageIO
import XCTest
@testable import ComicDeck

final class ReaderImageExportServiceTests: XCTestCase {
    func testPNGExportRunsOffMainActorAndRoundTripsImageDimensions() async throws {
        let image = try XCTUnwrap(Self.makeTestImage())
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderImageExportServiceTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("page.png", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await Task.detached(priority: .utility) {
            try ReaderImageExportService.write(image, to: url, format: .png)
        }.value

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 3)
        XCTAssertEqual(decoded.height, 2)
    }

    private nonisolated static func makeTestImage() -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: 3,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        return context.makeImage()
    }
}
