import CoreGraphics
import Foundation

public enum ReaderTranslationStatus: String, Codable, Sendable, Hashable {
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

public struct ReaderTranslationOverlay: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let pageIndex: Int
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat
    public let text: String
    public let sourceText: String

    public nonisolated init(
        id: String,
        pageIndex: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        text: String,
        sourceText: String
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.text = text
        self.sourceText = sourceText
    }

    public var normalizedRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct ReaderPageTranslationRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let sourceKey: String
    public let comicID: String
    public let chapterID: String
    public let pageIndex: Int
    public let targetLanguage: ReaderTranslationLanguage
    public let provider: String
    public let status: ReaderTranslationStatus
    public let imageRequestKey: String
    public let imageFingerprint: String
    public let overlays: [ReaderTranslationOverlay]
    public let errorText: String?
    public let updatedAt: Int64

    public nonisolated init(
        id: Int64,
        sourceKey: String,
        comicID: String,
        chapterID: String,
        pageIndex: Int,
        targetLanguage: ReaderTranslationLanguage,
        provider: String,
        status: ReaderTranslationStatus,
        imageRequestKey: String,
        imageFingerprint: String,
        overlays: [ReaderTranslationOverlay],
        errorText: String?,
        updatedAt: Int64
    ) {
        self.id = id
        self.sourceKey = sourceKey
        self.comicID = comicID
        self.chapterID = chapterID
        self.pageIndex = pageIndex
        self.targetLanguage = targetLanguage
        self.provider = provider
        self.status = status
        self.imageRequestKey = imageRequestKey
        self.imageFingerprint = imageFingerprint
        self.overlays = overlays
        self.errorText = errorText
        self.updatedAt = updatedAt
    }
}

struct ReaderTranslationPageResult: Sendable, Hashable {
    let status: ReaderTranslationStatus
    let overlays: [ReaderTranslationOverlay]
    let errorText: String?
}
