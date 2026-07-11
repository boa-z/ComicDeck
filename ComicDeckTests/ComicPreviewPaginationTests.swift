import XCTest
@testable import ComicDeck

@MainActor
final class ComicPreviewPaginationTests: XCTestCase {
    func testNextStartPageUsesHighestPageInsteadOfImageCount() {
        let images = [preview(page: 1), preview(page: 3)]

        XCTAssertEqual(ComicPreviewPagination.nextStartPage(after: images), 4)
        XCTAssertEqual(ComicPreviewPagination.nextStartPage(after: []), 1)
    }

    func testMergeAppendsNewPagesAndRejectsDuplicatePages() {
        let existing = [preview(id: "existing-1", page: 1), preview(id: "existing-3", page: 3)]
        let page = ComicPreviewImagePage(
            images: [
                preview(id: "duplicate-3", page: 3),
                preview(id: "existing-1", page: 4),
                preview(id: "new-5", page: 5)
            ],
            nextToken: "next-2"
        )

        let result = ComicPreviewPagination.merge(
            existing: existing,
            page: page,
            requestedToken: "next-1"
        )

        XCTAssertEqual(result.images.map(\.id), ["existing-1", "existing-3", "new-5"])
        XCTAssertEqual(result.nextToken, "next-2")
    }

    func testMergeStopsRepeatedTokenWithoutDroppingNewImages() {
        let result = ComicPreviewPagination.merge(
            existing: [preview(id: "existing", page: 1)],
            page: ComicPreviewImagePage(
                images: [preview(id: "new", page: 2)],
                nextToken: " same-token "
            ),
            requestedToken: "same-token"
        )

        XCTAssertEqual(result.images.map(\.id), ["existing", "new"])
        XCTAssertNil(result.nextToken)
    }

    func testMergeKeepsAdvancedTokenForEmptyPage() {
        let result = ComicPreviewPagination.merge(
            existing: [],
            page: ComicPreviewImagePage(images: [], nextToken: "next-page"),
            requestedToken: nil
        )

        XCTAssertTrue(result.images.isEmpty)
        XCTAssertEqual(result.nextToken, "next-page")
    }

    private func preview(id: String? = nil, page: Int) -> ComicPreviewImage {
        ComicPreviewImage(
            id: id ?? "page-\(page)",
            imageURL: "https://example.com/\(page).jpg",
            page: page
        )
    }
}
