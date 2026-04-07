import CoreGraphics
import Foundation
import ImageIO
import Vision

struct OCRTextRegion: Sendable, Hashable {
    let id: String
    let text: String
    let boundingBox: CGRect
}

protocol OCRProvider: Sendable {
    var name: String { get }
    func recognizeTextRegions(from imageData: Data) async throws -> [OCRTextRegion]
}

enum AppleVisionOCRProviderError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return AppLocalization.text("reader.translation.error.invalid_image", "Invalid image data")
        }
    }
}

struct AppleVisionOCRProvider: OCRProvider {
    let name = "apple-vision"

    func recognizeTextRegions(from imageData: Data) async throws -> [OCRTextRegion] {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AppleVisionOCRProviderError.invalidImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let regions = observations.enumerated().compactMap { index, observation -> OCRTextRegion? in
                    guard let top = observation.topCandidates(1).first else { return nil }
                    let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return OCRTextRegion(
                        id: "ocr-\(index)",
                        text: text,
                        boundingBox: observation.boundingBox
                    )
                }
                continuation.resume(returning: regions)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.01

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
