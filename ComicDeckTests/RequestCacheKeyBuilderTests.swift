import XCTest
@testable import ComicDeck

final class RequestCacheKeyBuilderTests: XCTestCase {
    func testPrimaryRequestKeyKeepsRefererIsolated() {
        let first = request(referer: "https://e-hentai.org/")
        let second = request(referer: "https://example.com/")

        XCTAssertNotEqual(
            RequestCacheKeyBuilder.key(for: first),
            RequestCacheKeyBuilder.key(for: second)
        )
    }

    func testSharedImageResourceKeyIgnoresNonSensitiveHeaders() {
        let first = request(referer: "https://e-hentai.org/")
        let second = request(referer: "https://example.com/")

        XCTAssertEqual(
            RequestCacheKeyBuilder.sharedImageResourceKey(for: first),
            RequestCacheKeyBuilder.sharedImageResourceKey(for: second)
        )
    }

    func testSharedImageResourceKeyRejectsSensitiveHeaders() {
        var request = request(referer: "https://e-hentai.org/")
        request.setValue("ipb_member_id=123", forHTTPHeaderField: "Cookie")

        XCTAssertNil(RequestCacheKeyBuilder.sharedImageResourceKey(for: request))
    }

    private func request(referer: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://ehgt.org/thumb.jpg")!)
        request.httpMethod = "GET"
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return request
    }
}
