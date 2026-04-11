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

    func testKoharuDocumentMappingPreservesBlocksAndRenderedAsset() {
        let document = KoharuDocumentDetail(
            id: "doc-1",
            name: "page-1",
            width: 1000,
            height: 2000,
            textBlocks: [
                KoharuTextBlockDetail(
                    id: "block-1",
                    x: 100,
                    y: 200,
                    width: 300,
                    height: 400,
                    confidence: 0.82,
                    sourceDirection: .vertical,
                    renderedDirection: .horizontal,
                    sourceLanguage: "ja",
                    rotationDeg: nil,
                    detectedFontSizePx: 28,
                    detector: "ctd",
                    text: "こんにちは",
                    translation: "Hello",
                    renderX: 90,
                    renderY: 180,
                    renderWidth: 320,
                    renderHeight: 420
                )
            ],
            image: "source-image",
            segment: "segment-image",
            inpainted: "inpainted-image",
            brushLayer: nil,
            rendered: "rendered-image"
        )

        let mapped = KoharuPageTranslationDocumentMapper.makeDocument(
            detail: document,
            sourceKey: "source-a",
            comicID: "comic-1",
            chapterID: "chapter-1",
            pageIndex: 5,
            sourceLanguage: .japanese,
            targetLanguage: .english,
            imageRequestKey: "GET|https://example.com/page-5.jpg",
            imageFingerprint: "fingerprint-5",
            providerConfigHash: "koharu-http://localhost:8080",
            renderedAssetLocalFilePath: "/tmp/koharu-page-5.png"
        )

        XCTAssertEqual(mapped.provider, "koharu")
        XCTAssertEqual(mapped.pipelineVersion, "koharu-page-translation-v1")
        XCTAssertEqual(mapped.status, .ready)
        XCTAssertEqual(mapped.currentStage, .ready)
        XCTAssertEqual(mapped.renderedAsset?.localFilePath, "/tmp/koharu-page-5.png")
        XCTAssertEqual(mapped.renderedAsset?.pixelWidth, 1000)
        XCTAssertEqual(mapped.renderedAsset?.pixelHeight, 2000)
        XCTAssertEqual(mapped.blocks.count, 1)
        XCTAssertEqual(
            mapped.blocks[0].sourceRect,
            ReaderNormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        )
        XCTAssertEqual(
            mapped.blocks[0].containerRect,
            ReaderNormalizedRect(x: 0.09, y: 0.09, width: 0.32, height: 0.21)
        )
        XCTAssertEqual(mapped.blocks[0].readingDirection, .verticalRL)
        XCTAssertEqual(mapped.blocks[0].sourceText, "こんにちは")
        XCTAssertEqual(mapped.blocks[0].translatedText, "Hello")
        XCTAssertEqual(mapped.blocks[0].confidence, 0.82)
    }
}
