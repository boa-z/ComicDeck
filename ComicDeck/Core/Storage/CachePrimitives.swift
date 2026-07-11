import CryptoKit
import Foundation

struct DataCachePolicy: Sendable {
    let memoryTTL: TimeInterval
    let diskTTL: TimeInterval
    let maxMemoryItems: Int
    let maxMemoryBytes: Int64
    let maxDiskBytes: Int64

    nonisolated init(
        memoryTTL: TimeInterval,
        diskTTL: TimeInterval,
        maxMemoryItems: Int,
        maxMemoryBytes: Int64,
        maxDiskBytes: Int64
    ) {
        self.memoryTTL = memoryTTL
        self.diskTTL = diskTTL
        self.maxMemoryItems = maxMemoryItems
        self.maxMemoryBytes = maxMemoryBytes
        self.maxDiskBytes = maxDiskBytes
    }
}

enum DataCacheSource: Sendable, Equatable {
    case memory
    case disk
}

struct DataCacheHit: Sendable {
    let data: Data
    let source: DataCacheSource
}

struct ValueCachePolicy {
    let ttl: TimeInterval
    let maxEntries: Int

    nonisolated init(ttl: TimeInterval, maxEntries: Int) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }
}

@MainActor
final class TimedValueCache {
    private struct Entry {
        let value: Any
        let expiresAt: Date
        var lastAccessAt: Date
    }

    private let policy: ValueCachePolicy
    private var entries: [String: Entry] = [:]

    init(policy: ValueCachePolicy) {
        self.policy = policy
    }

    func value<Value>(forKey key: String) -> Value? {
        let now = Date()
        pruneExpiredEntries(now: now)
        guard var entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries[key] = nil
            return nil
        }
        entry.lastAccessAt = now
        entries[key] = entry
        guard let value = entry.value as? Value else {
            entries[key] = nil
            return nil
        }
        return value
    }

    func containsValue(forKey key: String) -> Bool {
        let now = Date()
        pruneExpiredEntries(now: now)
        guard entries[key]?.expiresAt ?? .distantPast > now else {
            entries[key] = nil
            return false
        }
        return true
    }

    func setValue<Value>(_ value: Value, forKey key: String) {
        let now = Date()
        entries[key] = Entry(
            value: value,
            expiresAt: now.addingTimeInterval(policy.ttl),
            lastAccessAt: now
        )
        trimIfNeeded(now: now)
    }

    func removeValue(forKey key: String) {
        entries[key] = nil
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    func removeAll(where shouldRemove: (String) -> Bool) {
        for key in entries.keys where shouldRemove(key) {
            entries[key] = nil
        }
    }

    private func pruneExpiredEntries(now: Date) {
        for (key, entry) in entries where entry.expiresAt <= now {
            entries[key] = nil
        }
    }

    private func trimIfNeeded(now: Date) {
        pruneExpiredEntries(now: now)
        guard entries.count > policy.maxEntries else { return }
        let overflow = entries.count - policy.maxEntries
        let victims = entries
            .sorted { $0.value.lastAccessAt < $1.value.lastAccessAt }
            .prefix(overflow)
            .map(\.key)
        for key in victims {
            entries[key] = nil
        }
    }
}

enum RequestCacheKeyBuilder {
    nonisolated static func key(for request: URLRequest) -> String {
        composeKey(
            method: request.httpMethod,
            urlString: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
    }

    nonisolated static func sharedImageResourceKey(for request: URLRequest) -> String? {
        let method = (request.httpMethod ?? "GET")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard method == "GET", request.httpBody == nil else { return nil }
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || scheme == "file"
        else {
            return nil
        }
        guard !hasSensitiveHeaders(request.allHTTPHeaderFields ?? [:]) else {
            return nil
        }
        return [
            "IMAGE_RESOURCE",
            normalizedURLString(url.absoluteString)
        ].joined(separator: "|")
    }

    nonisolated static func digest(_ value: String) -> String {
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func composeKey(
        method: String?,
        urlString: String,
        headers: [String: String],
        body: Data?
    ) -> String {
        let normalizedHeaders = headers
            .map { ($0.key.lowercased(), $0.value) }
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 {
                    return lhs.1 < rhs.1
                }
                return lhs.0 < rhs.0
            }
            .map { "\($0)=\($1)" }
            .joined(separator: "&")
        return [
            (method ?? "GET").trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            normalizedURLString(urlString),
            normalizedHeaders,
            bodyDigest(body)
        ].joined(separator: "|")
    }

    private nonisolated static func normalizedURLString(_ urlString: String) -> String {
        urlString.hasPrefix("//") ? "https:\(urlString)" : urlString
    }

    private nonisolated static func hasSensitiveHeaders(_ headers: [String: String]) -> Bool {
        let sensitiveHeaders: Set<String> = [
            "authorization",
            "cookie",
            "proxy-authorization",
            "x-api-key",
            "x-auth-token"
        ]
        return headers.keys.contains { sensitiveHeaders.contains($0.lowercased()) }
    }

    private nonisolated static func bodyDigest(_ body: Data?) -> String {
        guard let body, !body.isEmpty else { return "no-body" }
        let hash = SHA256.hash(data: body)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated final class HybridDataCacheDiskStorage: @unchecked Sendable {
    private struct EntryMetadata: Codable, Sendable {
        let key: String
        let createdAt: Date
        var lastAccessAt: Date
        let expiresAt: Date
        let byteCount: Int64
    }

    private let fileManager = FileManager.default
    private let directory: URL
    private let diskTTL: TimeInterval
    private let maxDiskBytes: Int64
    private static let pruneStoreInterval = 32
    private static let pruneByteInterval: Int64 = 16 * 1024 * 1024
    // The first write also prunes caches created before automatic enforcement existed.
    private var storesSincePrune = HybridDataCacheDiskStorage.pruneStoreInterval - 1
    private var bytesSincePrune: Int64 = 0

    init(directory: URL, diskTTL: TimeInterval, maxDiskBytes: Int64) {
        self.directory = directory
        self.diskTTL = diskTTL
        self.maxDiskBytes = maxDiskBytes
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func lookupData(forKey key: String, now: Date) -> Data? {
        let metadataURL = metadataFileURL(forKey: key)
        let dataURL = dataFileURL(forKey: key)
        guard let metadataData = try? Data(contentsOf: metadataURL),
              var metadata = try? JSONDecoder().decode(EntryMetadata.self, from: metadataData),
              metadata.key == key,
              metadata.expiresAt > now,
              let data = try? Data(contentsOf: dataURL)
        else {
            removeData(forKey: key)
            return nil
        }

        metadata.lastAccessAt = now
        try? persistMetadata(metadata, forKey: key)
        return data
    }

    func store(_ data: Data, forKey key: String, now: Date) {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = EntryMetadata(
            key: key,
            createdAt: now,
            lastAccessAt: now,
            expiresAt: now.addingTimeInterval(diskTTL),
            byteCount: Int64(data.count)
        )
        do {
            try data.write(to: dataFileURL(forKey: key), options: .atomic)
            try persistMetadata(metadata, forKey: key)
            storesSincePrune += 1
            bytesSincePrune += Int64(data.count)
            if storesSincePrune >= Self.pruneStoreInterval || bytesSincePrune >= Self.pruneByteInterval {
                try? pruneIfNeeded(now: now)
            }
        } catch {
            removeData(forKey: key)
        }
    }

    func removeData(forKey key: String) {
        try? fileManager.removeItem(at: dataFileURL(forKey: key))
        try? fileManager.removeItem(at: metadataFileURL(forKey: key))
    }

    func removeAll() {
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        storesSincePrune = 0
        bytesSincePrune = 0
    }

    func diskSizeBytes(now: Date) -> Int64 {
        try? pruneIfNeeded(now: now)
        guard let metadata = try? loadMetadata() else { return 0 }
        return metadata.reduce(into: 0) { result, item in
            if item.expiresAt > now {
                result += item.byteCount
            }
        }
    }

    private func loadMetadata() throws -> [EntryMetadata] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var metadata: [EntryMetadata] = []
        metadata.reserveCapacity(urls.count)
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(EntryMetadata.self, from: data)
            else {
                try? fileManager.removeItem(at: url)
                try? fileManager.removeItem(
                    at: url.deletingPathExtension().appendingPathExtension("bin")
                )
                continue
            }
            metadata.append(decoded)
        }
        return metadata
    }

    private func pruneIfNeeded(now: Date) throws {
        var metadata = try loadMetadata()
        defer {
            storesSincePrune = 0
            bytesSincePrune = 0
        }
        for item in metadata where item.expiresAt <= now {
            removeData(forKey: item.key)
        }
        for item in metadata where !fileManager.fileExists(atPath: dataFileURL(forKey: item.key).path) {
            removeData(forKey: item.key)
        }
        metadata = metadata.filter {
            $0.expiresAt > now && fileManager.fileExists(atPath: dataFileURL(forKey: $0.key).path)
        }
        var total = metadata.reduce(into: Int64(0)) { result, item in
            result += item.byteCount
        }
        guard total > maxDiskBytes else { return }
        for item in metadata.sorted(by: { $0.lastAccessAt < $1.lastAccessAt }) {
            removeData(forKey: item.key)
            total -= item.byteCount
            if total <= maxDiskBytes {
                break
            }
        }
    }

    private func dataFileURL(forKey key: String) -> URL {
        directory
            .appendingPathComponent(RequestCacheKeyBuilder.digest(key))
            .appendingPathExtension("bin")
    }

    private func metadataFileURL(forKey key: String) -> URL {
        directory
            .appendingPathComponent(RequestCacheKeyBuilder.digest(key))
            .appendingPathExtension("json")
    }

    private func persistMetadata(_ metadata: EntryMetadata, forKey key: String) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataFileURL(forKey: key), options: .atomic)
    }
}

actor HybridDataCache {
    private struct MemoryEntry: Sendable {
        let data: Data
        let expiresAt: Date
        var lastAccessAt: Date
    }

    private let policy: DataCachePolicy
    private let diskStorage: HybridDataCacheDiskStorage

    private var memoryEntries: [String: MemoryEntry] = [:]
    private var memoryBytes: Int64 = 0
    private var keyMutationVersions: [String: UInt64] = [:]
    private var clearGeneration: UInt64 = 0
    private var diskOperationTail: Task<Void, Never>?

    init(directoryName: String, policy: DataCachePolicy, rootDirectory: URL? = nil) {
        self.policy = policy
        let root = rootDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.diskStorage = HybridDataCacheDiskStorage(
            directory: root.appendingPathComponent(directoryName, isDirectory: true),
            diskTTL: policy.diskTTL,
            maxDiskBytes: policy.maxDiskBytes
        )
    }

    func lookupData(forKey key: String) async -> DataCacheHit? {
        let now = Date()
        pruneExpiredMemoryEntries(now: now)
        if var entry = memoryEntries[key] {
            guard entry.expiresAt > now else {
                removeMemoryValue(forKey: key)
                return nil
            }
            entry.lastAccessAt = now
            memoryEntries[key] = entry
            return DataCacheHit(data: entry.data, source: .memory)
        }

        let mutationVersion = keyMutationVersions[key, default: 0]
        let lookupClearGeneration = clearGeneration
        let storage = diskStorage
        let data = await performDiskOperation {
            storage.lookupData(forKey: key, now: now)
        }

        guard mutationVersion == keyMutationVersions[key, default: 0],
              lookupClearGeneration == clearGeneration
        else {
            return currentMemoryHit(forKey: key, now: Date())
        }
        guard let data else { return nil }
        storeMemoryValue(data, forKey: key, now: now)
        return DataCacheHit(data: data, source: .disk)
    }

    func store(_ data: Data, forKey key: String) {
        let now = Date()
        recordMutation(forKey: key)
        storeMemoryValue(data, forKey: key, now: now)
        let storage = diskStorage
        enqueueDiskOperation {
            storage.store(data, forKey: key, now: now)
        }
    }

    func removeData(forKey key: String) async {
        recordMutation(forKey: key)
        removeMemoryValue(forKey: key)
        let storage = diskStorage
        await performDiskOperation {
            storage.removeData(forKey: key)
        }
    }

    func removeAll() async {
        memoryEntries.removeAll(keepingCapacity: true)
        memoryBytes = 0
        keyMutationVersions.removeAll(keepingCapacity: true)
        clearGeneration &+= 1
        let storage = diskStorage
        await performDiskOperation {
            storage.removeAll()
        }
    }

    func memorySnapshot() -> (items: Int, bytes: Int64) {
        pruneExpiredMemoryEntries(now: Date())
        return (memoryEntries.count, memoryBytes)
    }

    func diskSizeBytes() async -> Int64 {
        let now = Date()
        let storage = diskStorage
        return await performDiskOperation {
            storage.diskSizeBytes(now: now)
        }
    }

    func flushPendingDiskOperations() async {
        await diskOperationTail?.value
    }

    private func storeMemoryValue(_ data: Data, forKey key: String, now: Date) {
        if let existing = memoryEntries.removeValue(forKey: key) {
            memoryBytes -= Int64(existing.data.count)
        }
        memoryEntries[key] = MemoryEntry(
            data: data,
            expiresAt: now.addingTimeInterval(policy.memoryTTL),
            lastAccessAt: now
        )
        memoryBytes += Int64(data.count)
        trimMemoryIfNeeded(now: now)
    }

    private func removeMemoryValue(forKey key: String) {
        if let existing = memoryEntries.removeValue(forKey: key) {
            memoryBytes -= Int64(existing.data.count)
        }
    }

    private func trimMemoryIfNeeded(now: Date) {
        pruneExpiredMemoryEntries(now: now)
        guard memoryEntries.count > policy.maxMemoryItems || memoryBytes > policy.maxMemoryBytes else { return }
        let victims = memoryEntries.sorted { $0.value.lastAccessAt < $1.value.lastAccessAt }
        for victim in victims {
            guard memoryEntries.count > policy.maxMemoryItems || memoryBytes > policy.maxMemoryBytes else { break }
            removeMemoryValue(forKey: victim.key)
        }
    }

    private func pruneExpiredMemoryEntries(now: Date) {
        let expiredKeys = memoryEntries.compactMap { key, entry in
            entry.expiresAt <= now ? key : nil
        }
        for key in expiredKeys {
            removeMemoryValue(forKey: key)
        }
    }

    private func recordMutation(forKey key: String) {
        keyMutationVersions[key, default: 0] &+= 1
    }

    private func currentMemoryHit(forKey key: String, now: Date) -> DataCacheHit? {
        guard var entry = memoryEntries[key], entry.expiresAt > now else {
            removeMemoryValue(forKey: key)
            return nil
        }
        entry.lastAccessAt = now
        memoryEntries[key] = entry
        return DataCacheHit(data: entry.data, source: .memory)
    }

    private func enqueueDiskOperation(_ operation: @escaping @Sendable () -> Void) {
        let previous = diskOperationTail
        diskOperationTail = Task.detached(priority: .utility) {
            await previous?.value
            operation()
        }
    }

    private func performDiskOperation<Result: Sendable>(
        _ operation: @escaping @Sendable () -> Result
    ) async -> Result {
        let previous = diskOperationTail
        let operationTask = Task.detached(priority: .utility) {
            await previous?.value
            return operation()
        }
        diskOperationTail = Task.detached(priority: .utility) {
            _ = await operationTask.value
        }
        return await operationTask.value
    }
}
