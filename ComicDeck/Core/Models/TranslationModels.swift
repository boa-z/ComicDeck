import CoreGraphics
import Foundation

public enum ReaderPageTranslationStage: String, Codable, Sendable, Hashable {
    case idle
    case queued
    case detecting
    case ocr
    case translating
    case cleaning
    case rendering
    case ready
    case failed
    case unsupported
}

public enum ReaderPageTranslationStatus: String, Codable, Sendable, Hashable {
    case idle
    case processing
    case ready
    case failed
    case unsupported
}

public enum ReaderTranslationLanguage: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case japanese = "ja"
    case english = "en"
    case chineseSimplified = "zh-Hans"
    case chineseTraditional = "zh-Hant"
    case korean = "ko"

    public var id: String { rawValue }

    public var localeLanguage: Locale.Language {
        Locale.Language(identifier: rawValue)
    }

    public var title: String {
        switch self {
        case .japanese:
            return "Japanese"
        case .english:
            return "English"
        case .chineseSimplified:
            return "Chinese (Simplified)"
        case .chineseTraditional:
            return "Chinese (Traditional)"
        case .korean:
            return "Korean"
        }
    }
}

public enum ReaderTextReadingDirection: String, Codable, Sendable, Hashable {
    case horizontalLTR
    case horizontalRTL
    case verticalRL
}

public enum ReaderCleanupRegionKind: String, Codable, Sendable, Hashable {
    case text
    case bubble
    case caption
}

public enum ReaderRenderedPageMode: String, Codable, Sendable, Hashable {
    case original
    case translated
}

public nonisolated struct ReaderNormalizedRect: Codable, Sendable, Hashable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public nonisolated init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public nonisolated struct ReaderTextStyleHints: Codable, Sendable, Hashable {
    public enum FontStyle: String, Codable, Sendable, Hashable {
        case speechBubble
        case caption
        case narration
    }

    public let fontStyle: FontStyle
    public let prefersVerticalLayout: Bool

    public nonisolated init(fontStyle: FontStyle, prefersVerticalLayout: Bool) {
        self.fontStyle = fontStyle
        self.prefersVerticalLayout = prefersVerticalLayout
    }
}

public nonisolated struct ReaderTextBlock: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let sourceRect: ReaderNormalizedRect
    public let containerRect: ReaderNormalizedRect?
    public let readingDirection: ReaderTextReadingDirection
    public let sourceText: String
    public let translatedText: String?
    public let styleHints: ReaderTextStyleHints?
    public let zIndex: Int
    public let confidence: Double?

    public nonisolated init(
        id: String,
        sourceRect: ReaderNormalizedRect,
        containerRect: ReaderNormalizedRect?,
        readingDirection: ReaderTextReadingDirection,
        sourceText: String,
        translatedText: String?,
        styleHints: ReaderTextStyleHints?,
        zIndex: Int,
        confidence: Double?
    ) {
        self.id = id
        self.sourceRect = sourceRect
        self.containerRect = containerRect
        self.readingDirection = readingDirection
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.styleHints = styleHints
        self.zIndex = zIndex
        self.confidence = confidence
    }

    public func withSourceText(_ text: String, confidence: Double?) -> ReaderTextBlock {
        ReaderTextBlock(
            id: id,
            sourceRect: sourceRect,
            containerRect: containerRect,
            readingDirection: readingDirection,
            sourceText: text,
            translatedText: translatedText,
            styleHints: styleHints,
            zIndex: zIndex,
            confidence: confidence
        )
    }

    public func withTranslatedText(_ text: String?) -> ReaderTextBlock {
        ReaderTextBlock(
            id: id,
            sourceRect: sourceRect,
            containerRect: containerRect,
            readingDirection: readingDirection,
            sourceText: sourceText,
            translatedText: text,
            styleHints: styleHints,
            zIndex: zIndex,
            confidence: confidence
        )
    }
}

public nonisolated struct ReaderCleanupRegion: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let rect: ReaderNormalizedRect
    public let kind: ReaderCleanupRegionKind
    public let relatedBlockIDs: [String]
    public let maskAssetPath: String?
}

public nonisolated struct ReaderRenderedPageAsset: Codable, Sendable, Hashable {
    public let localFilePath: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let renderMode: ReaderRenderedPageMode
    public let provider: String
    public let updatedAt: Int64
}

public struct ReaderPagePresentationState: Codable, Sendable, Hashable {
    public let viewportSize: CGSize
    public let imageFrame: ReaderNormalizedRect?
    public let zoomScale: CGFloat
    public let contentOffset: CGPoint

    public nonisolated init(
        viewportSize: CGSize,
        imageFrame: ReaderNormalizedRect?,
        zoomScale: CGFloat,
        contentOffset: CGPoint
    ) {
        self.viewportSize = viewportSize
        self.imageFrame = imageFrame
        self.zoomScale = zoomScale
        self.contentOffset = contentOffset
    }
}

public nonisolated struct ReaderPageTranslationDocument: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let sourceKey: String
    public let comicID: String
    public let chapterID: String
    public let pageIndex: Int
    public let sourceLanguage: ReaderTranslationLanguage?
    public let targetLanguage: ReaderTranslationLanguage
    public let provider: String
    public let status: ReaderPageTranslationStatus
    public let currentStage: ReaderPageTranslationStage
    public let imageRequestKey: String
    public let imageFingerprint: String
    public let pipelineVersion: String
    public let providerConfigHash: String
    public let blocks: [ReaderTextBlock]
    public let cleanupRegions: [ReaderCleanupRegion]
    public let renderedAsset: ReaderRenderedPageAsset?
    public let errorText: String?
    public let updatedAt: Int64
}
