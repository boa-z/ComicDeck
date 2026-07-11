import XCTest
@testable import ComicDeck

@MainActor
final class ReaderImagePipelineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ImagePipelineURLProtocolStub.reset()
    }

    func testConcurrentRefererVariantsShareNetworkLoad() async throws {
        let fixture = try makeFixture()
        let pipeline = fixture.pipeline
        let cleanup = fixture.cleanup
        defer { cleanup() }
        let first = makeRequest(referer: "https://e-hentai.org/")
        let second = makeRequest(referer: "https://exhentai.org/")

        async let firstData = pipeline.loadData(for: first, priority: .thumbnail)
        async let secondData = pipeline.loadData(for: second, priority: .thumbnail)
        let results = try await (firstData, secondData)

        XCTAssertEqual(results.0, Self.imageData)
        XCTAssertEqual(results.1, Self.imageData)
        XCTAssertEqual(ImagePipelineURLProtocolStub.requestCount, 1)
        let metrics = await pipeline.cacheMetrics()
        XCTAssertEqual(metrics.memoryItems, 1)
        XCTAssertEqual(metrics.memoryBytes, Int64(Self.imageData.count))
    }

    func testSensitiveHeaderVariantsKeepNetworkLoadsIsolated() async throws {
        let fixture = try makeFixture()
        let pipeline = fixture.pipeline
        let cleanup = fixture.cleanup
        defer { cleanup() }
        var first = makeRequest(referer: "https://e-hentai.org/")
        var second = makeRequest(referer: "https://e-hentai.org/")
        first.setValue("session=first", forHTTPHeaderField: "Cookie")
        second.setValue("session=second", forHTTPHeaderField: "Cookie")

        async let firstData = pipeline.loadData(for: first, priority: .thumbnail)
        async let secondData = pipeline.loadData(for: second, priority: .thumbnail)
        _ = try await (firstData, secondData)

        XCTAssertEqual(ImagePipelineURLProtocolStub.requestCount, 2)
    }

    private func makeFixture() throws -> (pipeline: ReaderImagePipeline, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderImagePipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImagePipelineURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let pipeline = ReaderImagePipeline(session: session, cacheRootDirectory: root)
        return (pipeline, {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
        })
    }

    private func makeRequest(referer: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://images.example.test/cover.png")!)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        return request
    }

    nonisolated fileprivate static let imageData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
}

private final class ImagePipelineURLProtocolStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestCount = 0

    static var requestCount: Int {
        lock.withLock { storedRequestCount }
    }

    static func reset() {
        lock.withLock { storedRequestCount = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.storedRequestCount += 1 }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "image/png"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: ReaderImagePipelineTests.imageData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
