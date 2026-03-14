import CryptoKit
import Foundation

enum ReaderImagePipelineError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response"
        case let .httpStatus(code):
            return "HTTP \(code)"
        }
    }
}

struct ReaderImageCacheMetrics: Sendable {
    var memoryItems = 0
    var memoryBytes: Int64 = 0
    var diskBytes: Int64 = 0
    var memoryHits = 0
    var diskHits = 0
    var networkLoads = 0
    var inFlightHits = 0
    var misses = 0

    nonisolated init() {}

    var totalRequests: Int {
        memoryHits + diskHits + inFlightHits + misses
    }

    var hitRate: Double {
        let served = memoryHits + diskHits + inFlightHits
        let total = totalRequests
        guard total > 0 else { return 0 }
        return Double(served) / Double(total)
    }
}

actor ReaderImagePipeline {
    static let shared = ReaderImagePipeline()

    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private let maxConcurrent = 3
    private let maxCacheItems = 120
    private let maxMemoryCacheBytes: Int64 = 80 * 1024 * 1024
    private let maxDiskCacheBytes = 300 * 1024 * 1024
    private let pruneWriteThreshold = 24
    private let fileManager = FileManager.default
    private let diskCacheDirectory: URL
    private let session: URLSession
    private var writesSinceLastPrune = 0
    private var memoryCacheBytes: Int64 = 0
    private var metrics = ReaderImageCacheMetrics()

    init() {
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        self.diskCacheDirectory = root.appendingPathComponent("ReaderImageCache", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        try? fileManager.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }

    func loadData(for request: URLRequest) async throws -> Data {
        if let url = request.url, url.isFileURL {
            return try Data(contentsOf: url)
        }
        let key = cacheKey(for: request)

        if let data = cache[key] {
            touchMemoryCacheKey(key)
            metrics.memoryHits += 1
            return data
        }

        if let diskData = readDiskCache(for: key) {
            storeInCache(diskData, key: key)
            metrics.diskHits += 1
            return diskData
        }

        if let task = inFlight[key] {
            metrics.inFlightHits += 1
            return try await task.value
        }

        metrics.misses += 1

        let task = Task<Data, Error> {
            await self.acquireSlot()
            defer {
                self.releaseSlot()
            }
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ReaderImagePipelineError.invalidResponse
            }
            guard (200...399).contains(http.statusCode) else {
                throw ReaderImagePipelineError.httpStatus(http.statusCode)
            }
            return data
        }

        inFlight[key] = task
        do {
            let data = try await task.value
            inFlight[key] = nil
            metrics.networkLoads += 1
            storeInCache(data, key: key)
            return data
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func prefetch(requests: [URLRequest]) async {
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    do {
                        _ = try await self.loadData(for: request)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func clearAllCache() {
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        writesSinceLastPrune = 0
        memoryCacheBytes = 0
        metrics = ReaderImageCacheMetrics()
        if fileManager.fileExists(atPath: diskCacheDirectory.path) {
            try? fileManager.removeItem(at: diskCacheDirectory)
        }
        try? fileManager.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }

    func diskCacheSizeBytes() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        metrics.diskBytes = total
        return total
    }

    func cacheMetrics() -> ReaderImageCacheMetrics {
        var snapshot = metrics
        snapshot.memoryItems = cache.count
        snapshot.memoryBytes = memoryCacheBytes
        return snapshot
    }

    private func acquireSlot() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        activeCount += 1
    }

    private func releaseSlot() {
        activeCount = max(0, activeCount - 1)
        guard !waiters.isEmpty else { return }
        let continuation = waiters.removeFirst()
        continuation.resume()
    }

    private func storeInCache(_ data: Data, key: String) {
        let incomingBytes = Int64(data.count)
        if let existing = cache[key] {
            memoryCacheBytes -= Int64(existing.count)
        }
        touchMemoryCacheKey(key)
        cache[key] = data
        memoryCacheBytes += incomingBytes
        metrics.memoryItems = cache.count
        metrics.memoryBytes = memoryCacheBytes
        Task { await writeDiskCache(data: data, key: key) }

        trimMemoryCacheIfNeeded()
    }

    private func cacheFileURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appendingPathComponent(name).appendingPathExtension("bin")
    }

    private func cacheKey(for req: URLRequest) -> String {
        let method = req.httpMethod ?? "GET"
        let url = req.url?.absoluteString ?? ""
        let headers = (req.allHTTPHeaderFields ?? [:]).keys
            .sorted()
            .map { "\($0)=\((req.allHTTPHeaderFields ?? [:])[$0] ?? "")" }
            .joined(separator: "&")
        let bodyLen = req.httpBody?.count ?? 0
        return "\(method)|\(url)|\(headers)|\(bodyLen)"
    }

    private func readDiskCache(for key: String) -> Data? {
        let url = cacheFileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try? Data(contentsOf: url)
        if data != nil {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
        return data
    }

    private func writeDiskCache(data: Data, key: String) async {
        let url = cacheFileURL(for: key)
        do {
            try data.write(to: url, options: .atomic)
            writesSinceLastPrune += 1
            if writesSinceLastPrune >= pruneWriteThreshold {
                writesSinceLastPrune = 0
                try pruneDiskCacheIfNeeded()
            }
        } catch {
            return
        }
    }

    private func touchMemoryCacheKey(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private func trimMemoryCacheIfNeeded() {
        while cacheOrder.count > maxCacheItems || memoryCacheBytes > maxMemoryCacheBytes {
            let old = cacheOrder.removeFirst()
            if let removed = cache.removeValue(forKey: old) {
                memoryCacheBytes -= Int64(removed.count)
            }
        }
        metrics.memoryItems = cache.count
        metrics.memoryBytes = memoryCacheBytes
    }

    private func pruneDiskCacheIfNeeded() throws {
        let urls = try fileManager.contentsOfDirectory(
            at: diskCacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var items: [(url: URL, size: Int64, modifiedAt: Date)] = []
        var total: Int64 = 0
        items.reserveCapacity(urls.count)

        for url in urls {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            total += size
            items.append((url: url, size: size, modifiedAt: modifiedAt))
        }

        guard total > Int64(maxDiskCacheBytes) else { return }
        let sorted = items.sorted { $0.modifiedAt < $1.modifiedAt }
        var remaining = total
        for item in sorted {
            try? fileManager.removeItem(at: item.url)
            remaining -= item.size
            if remaining <= Int64(maxDiskCacheBytes) {
                break
            }
        }
    }
}

func buildURLRequest(from request: ImageRequest) -> URLRequest? {
    let normalizedURL = request.url.hasPrefix("//") ? "https:\(request.url)" : request.url
    guard let url = URL(string: normalizedURL),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" || scheme == "file"
    else {
        return nil
    }

    var req = URLRequest(url: url)
    req.timeoutInterval = 25
    req.cachePolicy = .returnCacheDataElseLoad
    let normalizedMethod = request.method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let method = normalizedMethod.isEmpty ? "GET" : normalizedMethod
    req.httpMethod = method
    if method != "GET" && method != "HEAD", let body = request.body, !body.isEmpty {
        req.httpBody = Data(body)
    } else {
        req.httpBody = nil
        req.setValue(nil, forHTTPHeaderField: "Content-Length")
    }
    for (k, v) in request.headers {
        req.setValue(v, forHTTPHeaderField: k)
    }
    if req.value(forHTTPHeaderField: "Accept") == nil {
        req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
    }
    if req.value(forHTTPHeaderField: "User-Agent") == nil {
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
    }
    if req.value(forHTTPHeaderField: "Referer") == nil, req.value(forHTTPHeaderField: "referer") == nil {
        if let host = url.host {
            req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }
    }
    return req
}

func imageRequestKey(_ req: ImageRequest) -> String {
    let headers = req.headers.keys.sorted().map { "\($0)=\(req.headers[$0] ?? "")" }.joined(separator: "&")
    let bodyLen = req.body?.count ?? 0
    return "\(req.method)|\(req.url)|\(headers)|\(bodyLen)"
}

func urlRequestKey(_ req: URLRequest) -> String {
    let method = req.httpMethod ?? "GET"
    let url = req.url?.absoluteString ?? ""
    let headers = (req.allHTTPHeaderFields ?? [:]).keys.sorted().map { "\($0)=\((req.allHTTPHeaderFields ?? [:])[$0] ?? "")" }.joined(separator: "&")
    let bodyLen = req.httpBody?.count ?? 0
    return "\(method)|\(url)|\(headers)|\(bodyLen)"
}
