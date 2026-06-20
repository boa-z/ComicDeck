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

    private let session: URLSession
    private let cache: HybridDataCache
    private var inFlight: [String: Task<Data, Error>] = [:]
    private var activeCount = 0
    private var waiters: [(id: UUID, priority: LoadPriority, continuation: CheckedContinuation<Void, Never>)] = []
    private let maxConcurrent = 6
    private let maxVisibleSlots = 4
    private var metrics = ReaderImageCacheMetrics()
    private var prefetchGeneration = 0

    enum LoadPriority: Int, Comparable {
        case visible
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
        if let hit = await cache.lookupData(forKey: key) {
            switch hit.source {
            case .memory:
                metrics.memoryHits += 1
            case .disk:
                metrics.diskHits += 1
            }
            return hit.data
        }

        if let existingTask = inFlight[key] {
            metrics.inFlightHits += 1
            do {
                return try await existingTask.value
            } catch {
                inFlight[key] = nil
                throw error
            }
        }

        metrics.misses += 1
        let task = Task<Data, Error> {
            await self.acquireSlot(priority: priority)
            defer { self.releaseSlot() }
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
            await cache.store(data, forKey: key)
            return data
        } catch {
            inFlight[key] = nil
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
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll(keepingCapacity: true)
        metrics = ReaderImageCacheMetrics()
        await cache.removeAll()
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

    private func acquireSlot(priority: LoadPriority = .visible) async {
        if activeCount < maxConcurrent {
            if priority == .prefetch && activeCount >= maxVisibleSlots {
                await waitForVisibleSlot()
                return
            }
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append((id: UUID(), priority: priority, continuation: continuation))
            waiters.sort { $0.priority < $1.priority }
        }
        guard !Task.isCancelled else { return }
        activeCount += 1
    }

    private func waitForVisibleSlot() async {
        while activeCount >= maxVisibleSlots {
            await withCheckedContinuation { continuation in
                waiters.append((id: UUID(), priority: .prefetch, continuation: continuation))
            }
            guard !Task.isCancelled else { return }
        }
    }

    private func releaseSlot() {
        activeCount = max(0, activeCount - 1)
        while !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.continuation.resume()
            return
        }
    }
}

func buildURLRequest(from request: ImageRequest) -> URLRequest? {
    let normalizedURL = request.url.hasPrefix("//") ? "https:\(request.url)" : request.url
    
    let url: URL?
    if normalizedURL.hasPrefix("file://") || normalizedURL.hasPrefix("/") {
        if normalizedURL.hasPrefix("file://") {
            url = URL(string: normalizedURL)
        } else {
            url = URL(fileURLWithPath: normalizedURL)
        }
    } else {
        url = URL(string: normalizedURL)
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
        req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
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
