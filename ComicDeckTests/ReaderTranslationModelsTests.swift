import XCTest
@testable import ComicDeck

final class ReaderTranslationModelsTests: XCTestCase {
    func testReaderPageTranslationDocumentJSONRoundTripPreservesBlocksRegionsAndArtifact() throws {
        let document = ReaderPageTranslationDocument(
            id: 0,
            sourceKey: "source-a",
            comicID: "comic-1",
            chapterID: "chapter-1",
            pageIndex: 3,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            provider: "apple-block-translation",
            status: .ready,
            currentStage: .rendering,
            imageRequestKey: "GET|https://example.com/page-3.jpg",
            imageFingerprint: "fingerprint-123",
            pipelineVersion: "reader-page-translation-v1",
            providerConfigHash: "provider-hash-123",
            blocks: [
                ReaderTextBlock(
                    id: "block-1",
                    sourceRect: ReaderNormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25),
                    containerRect: ReaderNormalizedRect(x: 0.08, y: 0.18, width: 0.34, height: 0.3),
                    readingDirection: .verticalRL,
                    sourceText: "こんにちは",
                    translatedText: "Hello",
                    styleHints: ReaderTextStyleHints(fontStyle: .speechBubble, prefersVerticalLayout: true),
                    zIndex: 0,
                    confidence: 0.91
                )
            ],
            cleanupRegions: [
                ReaderCleanupRegion(
                    id: "cleanup-1",
                    rect: ReaderNormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.25),
                    kind: .text,
                    relatedBlockIDs: ["block-1"],
                    maskAssetPath: nil
                )
            ],
            renderedAsset: ReaderRenderedPageAsset(
                localFilePath: "/tmp/translated-page-3.png",
                pixelWidth: 1200,
                pixelHeight: 1800,
                renderMode: .translated,
                provider: "apple-block-translation",
                updatedAt: 123456
            ),
            errorText: nil,
            updatedAt: 123456
        )

        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ReaderPageTranslationDocument.self, from: encoded)

        XCTAssertEqual(decoded, document)
    }
}
