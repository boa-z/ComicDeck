import Foundation
import ImageIO

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

    private struct InFlightImageLoad {
        let id: UUID
        let task: Task<Data, Error>
    }

    private let session: URLSession
    private let cache: HybridDataCache
    private var inFlight: [String: InFlightImageLoad] = [:]
    private var recentFailures: [String: Date] = [:]
    private var activeCount = 0
    private var waiters: [(id: UUID, key: String, priority: LoadPriority, continuation: CheckedContinuation<Bool, Never>)] = []
    private let maxConcurrent = 8
    private let maxPrefetchSlots = 2
    private let prefetchFailureCooldown: TimeInterval = 15
    private var metrics = ReaderImageCacheMetrics()
    private var prefetchGeneration = 0

    enum LoadPriority: Int, Comparable {
        case visible
        case thumbnail
        case prefetch

        static func < (lhs: LoadPriority, rhs: LoadPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        self.cache = HybridDataCache(
            directoryName: "ReaderImageCache",
            policy: DataCachePolicy(
                memoryTTL: 10 * 60,
                diskTTL: 24 * 60 * 60,
                maxMemoryItems: 120,
                maxMemoryBytes: 80 * 1024 * 1024,
                maxDiskBytes: 300 * 1024 * 1024
            )
        )
    }

    func loadData(for request: URLRequest, priority: LoadPriority = .visible) async throws -> Data {
        let url = request.url
        let isFileURL = url?.isFileURL == true || url?.scheme?.lowercased() == "file"
        if isFileURL, let url {
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
        }

        let key = RequestCacheKeyBuilder.key(for: request)
        let sharedResourceKey = RequestCacheKeyBuilder.sharedImageResourceKey(for: request)
        let queueKey = sharedResourceKey ?? key
        let lookupKeys = cacheLookupKeys(primary: key, shared: sharedResourceKey)
        if priority == .prefetch,
           let retryAfter = retryAfter(forKeys: lookupKeys),
           retryAfter > Date() {
            throw CancellationError()
        }
        if let hit = await cachedImageData(forKeys: lookupKeys) {
            switch hit.source {
            case .memory:
                metrics.memoryHits += 1
            case .disk:
                metrics.diskHits += 1
            }
            return hit.data
        }

        if let existingLoad = inFlightLoad(forKey: key) {
            metrics.inFlightHits += 1
            upgradeWaitingRequest(forKey: queueKey, to: priority)
            do {
                return try await existingLoad.task.value
            } catch {
                removeInFlightLoad(forKey: key, id: existingLoad.id)
                throw error
            }
        }

        metrics.misses += 1
        let loadID = UUID()
        let task = Task<Data, Error> {
            guard await self.acquireSlot(forKey: queueKey, priority: priority) else {
                throw CancellationError()
            }
            defer { self.releaseSlot() }
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ReaderImagePipelineError.invalidResponse
            }
            guard (200...399).contains(http.statusCode) else {
                throw ReaderImagePipelineError.httpStatus(http.statusCode)
            }
            try Self.validateImageData(data, response: http)
            return data
        }
        let load = InFlightImageLoad(id: loadID, task: task)

        storeInFlightLoad(load, forKey: key)
        do {
            let data = try await task.value
            removeInFlightLoad(forKey: key, id: loadID)
            clearFailures(forKeys: lookupKeys)
            metrics.networkLoads += 1
            await cache.store(data, forKey: key)
            if let sharedResourceKey, sharedResourceKey != key {
                await cache.store(data, forKey: sharedResourceKey)
            }
            return data
        } catch {
            removeInFlightLoad(forKey: key, id: loadID)
            recordFailure(forKeys: lookupKeys, priority: priority, error: error)
            throw error
        }
    }

    func prefetch(requests: [URLRequest], generation: Int) async {
        await withTaskGroup(of: Void.self) { group in
            for request in requests {
                group.addTask {
                    guard await self.prefetchGeneration == generation else { return }
                    do {
                        _ = try await self.loadData(for: request, priority: .prefetch)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func beginPrefetchSession() -> Int {
        prefetchGeneration += 1
        return prefetchGeneration
    }

    func cancelPrefetchSession() {
        prefetchGeneration += 1
    }

    func clearAllCache() async {
        var cancelledLoadIDs = Set<UUID>()
        for load in inFlight.values where cancelledLoadIDs.insert(load.id).inserted {
            load.task.cancel()
        }
        let pendingWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in pendingWaiters {
            waiter.continuation.resume(returning: false)
        }
        inFlight.removeAll(keepingCapacity: true)
        metrics = ReaderImageCacheMetrics()
        recentFailures.removeAll(keepingCapacity: true)
        await cache.removeAll()
    }

    func removeCachedData(for request: URLRequest) async {
        let key = RequestCacheKeyBuilder.key(for: request)
        let sharedResourceKey = RequestCacheKeyBuilder.sharedImageResourceKey(for: request)
        let lookupKeys = cacheLookupKeys(primary: key, shared: sharedResourceKey)
        clearFailures(forKeys: lookupKeys)
        await cache.removeData(forKey: key)
        if let sharedResourceKey, sharedResourceKey != key {
            await cache.removeData(forKey: sharedResourceKey)
        }
    }

    func diskCacheSizeBytes() async -> Int64 {
        let bytes = await cache.diskSizeBytes()
        metrics.diskBytes = bytes
        return bytes
    }

    func cacheMetrics() async -> ReaderImageCacheMetrics {
        var snapshot = metrics
        let memory = await cache.memorySnapshot()
        snapshot.memoryItems = memory.items
        snapshot.memoryBytes = memory.bytes
        snapshot.diskBytes = await cache.diskSizeBytes()
        return snapshot
    }

    private func acquireSlot(forKey key: String, priority: LoadPriority = .visible) async -> Bool {
        if hasCapacity(for: priority) {
            activeCount += 1
            return true
        }
        let waiterID = UUID()
        let reserved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id: waiterID, key: key, priority: priority, continuation: continuation))
                waiters.sort { $0.priority < $1.priority }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
        if Task.isCancelled, reserved {
            releaseSlot()
            return false
        }
        return reserved
    }

    private func hasCapacity(for priority: LoadPriority) -> Bool {
        guard activeCount < maxConcurrent else { return false }
        return priority != .prefetch || activeCount < maxPrefetchSlots
    }

    private func cacheLookupKeys(primary: String, shared: String?) -> [String] {
        guard let shared, shared != primary else {
            return [primary]
        }
        return [primary, shared]
    }

    private func inFlightLoad(forKey key: String) -> InFlightImageLoad? {
        inFlight[key]
    }

    private func storeInFlightLoad(_ load: InFlightImageLoad, forKey key: String) {
        inFlight[key] = load
    }

    private func removeInFlightLoad(forKey key: String, id: UUID) {
        if inFlight[key]?.id == id {
            inFlight[key] = nil
        }
    }

    private func cachedImageData(forKeys keys: [String]) async -> DataCacheHit? {
        for key in keys {
            guard let hit = await cache.lookupData(forKey: key) else {
                continue
            }
            do {
                try Self.validateImageData(hit.data, response: nil)
                return hit
            } catch {
                await cache.removeData(forKey: key)
            }
        }
        return nil
    }

    private func retryAfter(forKeys keys: [String]) -> Date? {
        var latest: Date?
        for key in keys {
            guard let retryAfter = recentFailures[key] else { continue }
            if latest.map({ retryAfter > $0 }) ?? true {
                latest = retryAfter
            }
        }
        return latest
    }

    private func clearFailures(forKeys keys: [String]) {
        for key in keys {
            recentFailures[key] = nil
        }
    }

    private func recordFailure(forKeys keys: [String], priority: LoadPriority, error: Error) {
        guard priority == .prefetch, !(error is CancellationError) else {
            return
        }
        let retryAfter = Date().addingTimeInterval(prefetchFailureCooldown)
        for key in keys {
            recentFailures[key] = retryAfter
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func upgradeWaitingRequest(forKey key: String, to priority: LoadPriority) {
        guard let index = waiters.firstIndex(where: { $0.key == key }) else {
            return
        }
        guard priority < waiters[index].priority else {
            return
        }
        waiters[index].priority = priority
        waiters.sort { $0.priority < $1.priority }
    }

    private func releaseSlot() {
        activeCount = max(0, activeCount - 1)
        resumeNextWaiterIfPossible()
    }

    private func resumeNextWaiterIfPossible() {
        guard let index = waiters.firstIndex(where: { hasCapacity(for: $0.priority) }) else {
            return
        }
        let next = waiters.remove(at: index)
        activeCount += 1
        next.continuation.resume(returning: true)
    }

    private nonisolated static func validateImageData(_ data: Data, response: HTTPURLResponse?) throws {
        guard !data.isEmpty else {
            throw ReaderImagePipelineError.invalidResponse
        }

        let contentType = response?.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if likelyTextPayload(data) {
            throw ReaderImagePipelineError.invalidResponse
        }

        if imageDataIsDecodable(data) {
            return
        }

        guard imageDataHasKnownSignature(data) else {
            throw ReaderImagePipelineError.invalidResponse
        }

        if let contentType, contentType.hasPrefix("image/"), !contentType.contains("svg") {
            return
        }
    }

    private nonisolated static func imageDataIsDecodable(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            return false
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        return width > 0 && height > 0
    }

    private nonisolated static func imageDataHasKnownSignature(_ data: Data) -> Bool {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return true }
        if data.starts(with: [0x42, 0x4D]) { return true }
        if data.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }
        if data.starts(with: [0x00, 0x00, 0x02, 0x00]) { return true }
        if data.starts(with: [0x49, 0x49, 0x2A, 0x00]) { return true }
        if data.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return true }
        if data.starts(with: [0x49, 0x49, 0x2B, 0x00]) { return true }
        if data.starts(with: [0x4D, 0x4D, 0x00, 0x2B]) { return true }
        if data.starts(with: [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]) { return true }
        if data.starts(with: [0xFF, 0x4F, 0xFF, 0x51]) { return true }

        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           Array(data.dropFirst(8).prefix(4)) == [0x57, 0x45, 0x42, 0x50] {
            return true
        }

        if data.count >= 12,
           Array(data.dropFirst(4).prefix(4)) == [0x66, 0x74, 0x79, 0x70] {
            let brand = Array(data.dropFirst(8).prefix(4))
            let knownBrands: [[UInt8]] = [
                [0x61, 0x76, 0x69, 0x66],
                [0x61, 0x76, 0x69, 0x73],
                [0x68, 0x65, 0x69, 0x63],
                [0x68, 0x65, 0x69, 0x78],
                [0x6D, 0x69, 0x66, 0x31],
                [0x6D, 0x73, 0x66, 0x31]
            ]
            return knownBrands.contains(brand)
        }

        return false
    }

    private nonisolated static func likelyTextPayload(_ data: Data) -> Bool {
        let prefix = String(decoding: data.prefix(64), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<!doctype")
            || prefix.hasPrefix("<html")
            || prefix.hasPrefix("<script")
            || prefix.hasPrefix("<svg")
            || prefix.hasPrefix("{")
            || prefix.hasPrefix("[")
    }
}

func buildURLRequest(from request: ImageRequest) -> URLRequest? {
    let normalizedURL = normalizedImageURLString(request.url)
    
    let url: URL?
    if normalizedURL.hasPrefix("file://") || normalizedURL.hasPrefix("/") {
        if normalizedURL.hasPrefix("file://") {
            url = URL(string: normalizedURL) ?? fileURL(fromFileSchemeString: normalizedURL)
        } else {
            url = URL(fileURLWithPath: normalizedURL)
        }
    } else {
        url = URL(string: normalizedURL) ?? percentEncodedURL(from: normalizedURL)
    }
    
    guard let url,
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" || scheme == "file"
    else {
        return nil
    }

    var req = URLRequest(url: url)
    req.timeoutInterval = 25
    let normalizedMethod = request.method.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased()
    let method = normalizedMethod.isEmpty ? "GET" : normalizedMethod
    req.httpMethod = method
    if method != "GET" && method != "HEAD", let body = request.body, !body.isEmpty {
        req.httpBody = Data(body)
    } else {
        req.httpBody = nil
        req.setValue(nil as String?, forHTTPHeaderField: "Content-Length")
    }
    for (k, v) in request.headers {
        req.setValue(v, forHTTPHeaderField: k)
    }
    if req.value(forHTTPHeaderField: "Accept") == nil {
        req.setValue("image/avif,image/heic,image/heif,image/webp,image/jpeg,image/png,image/gif,image/apng,*/*;q=0.6", forHTTPHeaderField: "Accept")
    }
    if req.value(forHTTPHeaderField: "User-Agent") == nil {
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
    }
    if req.value(forHTTPHeaderField: "Referer") == nil, req.value(forHTTPHeaderField: "referer") == nil,
       let host = url.host {
        req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
    }
    return req
}

private func normalizedImageURLString(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let decodedEntities = trimmed
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
    let withoutCropMarker = stripImageCropMarker(from: decodedEntities)
    return withoutCropMarker.hasPrefix("//") ? "https:\(withoutCropMarker)" : withoutCropMarker
}

private func stripImageCropMarker(from value: String) -> String {
    guard let markerRange = value.range(of: "@x=") ?? value.range(of: "@y=") else {
        return value
    }
    return String(value[..<markerRange.lowerBound])
}

private func percentEncodedURL(from value: String) -> URL? {
    guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
        return nil
    }
    return URL(string: encoded)
}

private func fileURL(fromFileSchemeString value: String) -> URL? {
    guard value.hasPrefix("file://") else { return nil }
    let path = String(value.dropFirst("file://".count)).removingPercentEncoding
        ?? String(value.dropFirst("file://".count))
    return URL(fileURLWithPath: path)
}

func imageRequestKey(_ req: ImageRequest) -> String {
    if let urlRequest = buildURLRequest(from: req) {
        return RequestCacheKeyBuilder.key(for: urlRequest)
    }
    let bodyData = req.body.map { Data($0) }
    let headers = req.headers
        .map { ($0.key.lowercased(), $0.value) }
        .sorted { lhs, rhs in
            if lhs.0 == rhs.0 {
                return lhs.1 < rhs.1
            }
            return lhs.0 < rhs.0
        }
        .map { "\($0)=\($1)" }
        .joined(separator: "&")
    let bodyDigest = bodyData.map { RequestCacheKeyBuilder.digest($0.base64EncodedString()) } ?? "no-body"
    return [
        req.method.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).uppercased(),
        req.url,
        headers,
        bodyDigest
    ].joined(separator: "|")
}

nonisolated func urlRequestKey(_ req: URLRequest) -> String {
    RequestCacheKeyBuilder.key(for: req)
}
