import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ReaderImageExportFormat: Sendable {
    case png
    case jpeg

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        }
    }
}

nonisolated enum ReaderImageExportServiceError: Error, Sendable {
    case destinationCreationFailed
    case encodingFailed
}

nonisolated struct ReaderImageExportService {
    static func write(
        _ image: CGImage,
        to url: URL,
        format: ReaderImageExportFormat,
        compressionQuality: Double = 0.92
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.type.identifier as CFString,
            1,
            nil
        ) else {
            throw ReaderImageExportServiceError.destinationCreationFailed
        }

        let properties: CFDictionary? = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality as String: compressionQuality] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ReaderImageExportServiceError.encodingFailed
        }
    }

    static func writeTemporaryPNG(_ image: CGImage, fileName: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicDeckPageExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        try write(image, to: url, format: .png)
        return url
    }
}
