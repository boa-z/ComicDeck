import XCTest
@testable import ComicDeck

@MainActor
final class HybridDataCacheTests: XCTestCase {
    func testLatestQueuedWriteWinsOnDisk() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root: root)

        await cache.store(Data("first".utf8), forKey: "cover")
        await cache.store(Data("latest".utf8), forKey: "cover")
        await cache.flushPendingDiskOperations()

        let reloaded = makeCache(root: root)
        let hit = await reloaded.lookupData(forKey: "cover")

        XCTAssertEqual(hit?.data, Data("latest".utf8))
        XCTAssertEqual(hit?.source, .disk)
    }

    func testRemoveAllWaitsForEarlierWritesAndLeavesDiskEmpty() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root: root)

        await cache.store(Data("image".utf8), forKey: "cover")
        await cache.removeAll()

        let reloaded = makeCache(root: root)
        let hit = await reloaded.lookupData(forKey: "cover")
        let diskSize = await reloaded.diskSizeBytes()

        XCTAssertNil(hit)
        XCTAssertEqual(diskSize, 0)
    }

    func testRemoveDataWaitsForQueuedWriteAndPersistsDeletion() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root: root)

        await cache.store(Data("image".utf8), forKey: "cover")
        await cache.removeData(forKey: "cover")

        let reloaded = makeCache(root: root)
        let hit = await reloaded.lookupData(forKey: "cover")

        XCTAssertNil(hit)
    }

    func testQueuedWritesAutomaticallyEnforceDiskLimit() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let maxDiskBytes: Int64 = 128
        let cache = makeCache(root: root, maxDiskBytes: maxDiskBytes)

        for index in 0..<33 {
            await cache.store(Data(repeating: UInt8(index), count: 64), forKey: "image-\(index)")
        }
        await cache.flushPendingDiskOperations()

        XCTAssertLessThanOrEqual(try storedDataBytes(root: root), maxDiskBytes)
    }

    private func makeCache(root: URL, maxDiskBytes: Int64 = 4_096) -> HybridDataCache {
        HybridDataCache(
            directoryName: "HybridDataCacheTests",
            policy: DataCachePolicy(
                memoryTTL: 60,
                diskTTL: 60,
                maxMemoryItems: 4,
                maxMemoryBytes: 1_024,
                maxDiskBytes: maxDiskBytes
            ),
            rootDirectory: root
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComicDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func storedDataBytes(root: URL) throws -> Int64 {
        let cacheDirectory = root.appendingPathComponent("HybridDataCacheTests", isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "bin" }
            .reduce(into: Int64(0)) { total, url in
                total += Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
    }
}
