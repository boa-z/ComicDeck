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

enum DataCacheSource: Sendable {
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
final class TimedValueCache<Value> {
    private struct Entry {
        let value: Value
        let expiresAt: Date
        var lastAccessAt: Date
    }

    private let policy: ValueCachePolicy
    private var entries: [String: Entry] = [:]

    init(policy: ValueCachePolicy) {
        self.policy = policy
    }

    func value(forKey key: String) -> Value? {
        let now = Date()
        pruneExpiredEntries(now: now)
        guard var entry = entries[key] else { return nil }
        guard entry.expiresAt > now else {
            entries[key] = nil
            return nil
        }
        entry.lastAccessAt = now
        entries[key] = entry
        return entry.value
    }

    func containsValue(forKey key: String) -> Bool {
        value(forKey: key) != nil
    }

    func setValue(_ value: Value, forKey key: String) {
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

    private nonisolated static func bodyDigest(_ body: Data?) -> String {
        guard let body, !body.isEmpty else { return "no-body" }
        let hash = SHA256.hash(data: body)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

actor HybridDataCache {
    private struct MemoryEntry: Sendable {
        let data: Data
        let expiresAt: Date
        var lastAccessAt: Date
    }

    private struct DiskEntryMetadata: Codable, Sendable {
        let key: String
        let createdAt: Date
        var lastAccessAt: Date
        let expiresAt: Date
        let byteCount: Int64
    }

    private let policy: DataCachePolicy
    private let fileManager = FileManager.default
    private let directory: URL

    private var memoryEntries: [String: MemoryEntry] = [:]
    private var memoryBytes: Int64 = 0

    init(directoryName: String, policy: DataCachePolicy) {
        self.policy = policy
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func lookupData(forKey key: String) -> DataCacheHit? {
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

        guard var metadata = readMetadata(forKey: key) else { return nil }
        guard metadata.expiresAt > now else {
            removeDiskValue(forKey: key)
            return nil
        }

        let dataURL = dataFileURL(forKey: key)
        guard let data = try? Data(contentsOf: dataURL) else {
            removeDiskValue(forKey: key)
            return nil
        }

        metadata.lastAccessAt = now
        persistMetadata(metadata, forKey: key)
        storeMemoryValue(data, forKey: key, now: now)
        return DataCacheHit(data: data, source: .disk)
    }

    func store(_ data: Data, forKey key: String) {
        let now = Date()
        storeMemoryValue(data, forKey: key, now: now)
        do {
            try writeDiskValue(data, forKey: key, now: now)
            try pruneDiskIfNeeded(now: now)
        } catch {
            return
        }
    }

    func removeData(forKey key: String) {
        removeMemoryValue(forKey: key)
        removeDiskValue(forKey: key)
    }

    func removeAll() {
        memoryEntries.removeAll(keepingCapacity: true)
        memoryBytes = 0
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func memorySnapshot() -> (items: Int, bytes: Int64) {
        pruneExpiredMemoryEntries(now: Date())
        return (memoryEntries.count, memoryBytes)
    }

    func diskSizeBytes() -> Int64 {
        let now = Date()
        try? pruneDiskIfNeeded(now: now)
        guard let metadata = try? loadDiskMetadata() else { return 0 }
        return metadata.reduce(into: 0) { partialResult, item in
            if item.expiresAt > now {
                partialResult += item.byteCount
            }
        }
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

    private func writeDiskValue(_ data: Data, forKey key: String, now: Date) throws {
        let dataURL = dataFileURL(forKey: key)
        let metadata = DiskEntryMetadata(
            key: key,
            createdAt: now,
            lastAccessAt: now,
            expiresAt: now.addingTimeInterval(policy.diskTTL),
            byteCount: Int64(data.count)
        )
        try data.write(to: dataURL, options: .atomic)
        try persistMetadataThrowing(metadata, forKey: key)
    }

    private func loadDiskMetadata() throws -> [DiskEntryMetadata] {
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var metadata: [DiskEntryMetadata] = []
        metadata.reserveCapacity(urls.count)
        for url in urls where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(DiskEntryMetadata.self, from: data)
            else {
                try? fileManager.removeItem(at: url)
                continue
            }
            metadata.append(decoded)
        }
        return metadata
    }

    private func pruneDiskIfNeeded(now: Date) throws {
        var metadata = try loadDiskMetadata()
        for item in metadata where item.expiresAt <= now {
            removeDiskValue(forKey: item.key)
        }
        metadata = metadata.filter { $0.expiresAt > now && fileManager.fileExists(atPath: dataFileURL(forKey: $0.key).path) }
        var total = metadata.reduce(into: Int64(0)) { partialResult, item in
            partialResult += item.byteCount
        }
        guard total > policy.maxDiskBytes else { return }
        for item in metadata.sorted(by: { $0.lastAccessAt < $1.lastAccessAt }) {
            removeDiskValue(forKey: item.key)
            total -= item.byteCount
            if total <= policy.maxDiskBytes {
                break
            }
        }
    }

    private func dataFileURL(forKey key: String) -> URL {
        let fileName = RequestCacheKeyBuilder.digest(key)
        return directory.appendingPathComponent(fileName).appendingPathExtension("bin")
    }

    private func metadataFileURL(forKey key: String) -> URL {
        let fileName = RequestCacheKeyBuilder.digest(key)
        return directory.appendingPathComponent(fileName).appendingPathExtension("json")
    }

    private func readMetadata(forKey key: String) -> DiskEntryMetadata? {
        let url = metadataFileURL(forKey: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiskEntryMetadata.self, from: data)
    }

    private func persistMetadata(_ metadata: DiskEntryMetadata, forKey key: String) {
        try? persistMetadataThrowing(metadata, forKey: key)
    }

    private func persistMetadataThrowing(_ metadata: DiskEntryMetadata, forKey key: String) throws {
        let url = metadataFileURL(forKey: key)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    private func removeDiskValue(forKey key: String) {
        try? fileManager.removeItem(at: dataFileURL(forKey: key))
        try? fileManager.removeItem(at: metadataFileURL(forKey: key))
    }
}
