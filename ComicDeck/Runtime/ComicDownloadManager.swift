import Foundation
import UniformTypeIdentifiers

extension Notification.Name {
    static let comicDownloadDidUpdate = Notification.Name("comic.download.did.update")
}

enum ComicDownloadNotificationKey {
    static let item = "item"
}

actor ComicDownloadManager {
    struct Payload: Sendable {
        let sourceKey: String
        let comicID: String
        let comicTitle: String
        let coverURL: String?
        let comicDescription: String?
        let chapterID: String
        let chapterTitle: String
        let requests: [ImageRequest]
    }

    /// How often to flush progress to the database (every N pages).
    private let progressFlushInterval = 1
    /// Max number of retry attempts for a single image download.
    private let maxRetries = 3

    private let database: SQLiteStore
    private let rootDirectory: URL
    private let session: URLSession
    private let fileManager = FileManager.default
    private let maxConcurrent = 2

    private var pending: [Payload] = []
    private var runningKeys: Set<String> = []
    private var workerTask: Task<Void, Never>?
    private var runtimeQueueItems: [String: DownloadChapterItem] = [:]

    init(database: SQLiteStore, rootDirectory: URL) {
        self.database = database
        self.rootDirectory = rootDirectory
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        fileManager.createFile(atPath: rootDirectory.appendingPathComponent(".nomedia").path, contents: Data())
    }

    func enqueue(_ payload: Payload) async throws {
        let key = chapterKey(sourceKey: payload.sourceKey, comicID: payload.comicID, chapterID: payload.chapterID)
        let chapterDir = chapterDirectory(for: payload)
        try await database.upsertDownloadChapter(
            sourceKey: payload.sourceKey,
            comicID: payload.comicID,
            comicTitle: payload.comicTitle,
            coverURL: payload.coverURL,
            comicDescription: payload.comicDescription,
            chapterID: payload.chapterID,
            chapterTitle: payload.chapterTitle,
            status: .pending,
            totalPages: payload.requests.count,
            downloadedPages: 0,
            directoryPath: chapterDir.path,
            errorMessage: nil
        )
        let snapshot = try await database.getDownloadChapter(
            sourceKey: payload.sourceKey,
            comicID: payload.comicID,
            chapterID: payload.chapterID
        )
        await DownloadLiveActivityManager.shared.upsert(
            chapterKey: key,
            comicTitle: payload.comicTitle,
            chapterTitle: payload.chapterTitle,
            status: DownloadStatus.pending.rawValue,
            downloadedPages: 0,
            totalPages: payload.requests.count
        )
        if let snapshot {
            runtimeQueueItems[key] = snapshot
        }
        await postUpdate(item: snapshot)

        guard !runningKeys.contains(key), !pending.contains(where: {
            chapterKey(sourceKey: $0.sourceKey, comicID: $0.comicID, chapterID: $0.chapterID) == key
        }) else {
            return
        }
        pending.append(payload)
        startWorkerIfNeeded()
    }

    // MARK: - Worker Loop

    private func startWorkerIfNeeded() {
        guard workerTask == nil else { return }
        workerTask = Task { [weak self] in
            await self?.workerLoop()
        }
    }

    private func workerLoop() async {
        defer { workerTask = nil }
        while true {
            while runningKeys.count < maxConcurrent, !pending.isEmpty {
                let payload = pending.removeFirst()
                let key = chapterKey(sourceKey: payload.sourceKey, comicID: payload.comicID, chapterID: payload.chapterID)
                runningKeys.insert(key)
                Task {
                    await self.process(payload)
                }
            }

            if pending.isEmpty && runningKeys.isEmpty {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: - Chapter Processing

    private func process(_ payload: Payload) async {
        let key = chapterKey(sourceKey: payload.sourceKey, comicID: payload.comicID, chapterID: payload.chapterID)
        defer {
            runningKeys.remove(key)
        }

        do {
            let chapterDir = chapterDirectory(for: payload)
            let comicDir = comicDirectory(for: payload)
            try fileManager.createDirectory(at: chapterDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: comicDir, withIntermediateDirectories: true)

            try await database.updateDownloadProgress(
                sourceKey: payload.sourceKey,
                comicID: payload.comicID,
                chapterID: payload.chapterID,
                status: .downloading,
                downloadedPages: 0,
                totalPages: payload.requests.count,
                errorMessage: nil
            )
            let downloadingItem = try await database.getDownloadChapter(
                sourceKey: payload.sourceKey,
                comicID: payload.comicID,
                chapterID: payload.chapterID
            )
            await DownloadLiveActivityManager.shared.upsert(
                chapterKey: key,
                comicTitle: payload.comicTitle,
                chapterTitle: payload.chapterTitle,
                status: DownloadStatus.downloading.rawValue,
                downloadedPages: 0,
                totalPages: payload.requests.count
            )
            if let downloadingItem {
                runtimeQueueItems[key] = downloadingItem
            }
            await postUpdate(item: downloadingItem)

            var downloaded = 0
            for (index, imageRequest) in payload.requests.enumerated() {
                let pageFileURL = chapterDir.appendingPathComponent(fileName(for: imageRequest, index: index))
                if !fileManager.fileExists(atPath: pageFileURL.path) {
                    // Exponential backoff retry: 1s, 2s, 4s
                    try await downloadWithRetry(request: imageRequest, to: pageFileURL)
                }
                downloaded += 1

                // Throttle progress updates: flush every N pages or on the last page.
                let isLastPage = downloaded == payload.requests.count
                if downloaded % progressFlushInterval == 0 || isLastPage {
                    try await database.updateDownloadProgress(
                        sourceKey: payload.sourceKey,
                        comicID: payload.comicID,
                        chapterID: payload.chapterID,
                        status: .downloading,
                        downloadedPages: downloaded,
                        totalPages: payload.requests.count,
                        errorMessage: nil
                    )
                    let progressItem = try await database.getDownloadChapter(
                        sourceKey: payload.sourceKey,
                        comicID: payload.comicID,
                        chapterID: payload.chapterID
                    )
                    await DownloadLiveActivityManager.shared.upsert(
                        chapterKey: key,
                        comicTitle: payload.comicTitle,
                        chapterTitle: payload.chapterTitle,
                        status: DownloadStatus.downloading.rawValue,
                        downloadedPages: downloaded,
                        totalPages: payload.requests.count
                    )
                    if let progressItem {
                        runtimeQueueItems[key] = progressItem
                    }
                    await postUpdate(item: progressItem)
                }
            }

            try await ensureCoverSaved(for: payload, in: comicDir)
            try writeMetadata(for: payload, in: chapterDir)
            try await database.updateDownloadProgress(
                sourceKey: payload.sourceKey,
                comicID: payload.comicID,
                chapterID: payload.chapterID,
                status: .completed,
                downloadedPages: payload.requests.count,
                totalPages: payload.requests.count,
                errorMessage: nil
            )
            try await database.upsertOfflineChapter(
                sourceKey: payload.sourceKey,
                comicID: payload.comicID,
                comicTitle: payload.comicTitle,
                coverURL: payload.coverURL,
                comicDescription: payload.comicDescription,
                chapterID: payload.chapterID,
                chapterTitle: payload.chapterTitle,
                pageCount: payload.requests.count,
                verifiedPageCount: payload.requests.count,
                integrityStatus: .complete,
                directoryPath: chapterDir.path,
                downloadedAt: Int64(Date().timeIntervalSince1970),
                lastVerifiedAt: Int64(Date().timeIntervalSince1970)
            )
            try await database.deleteDownloadTask(
                sourceKey: payload.sourceKey,
                comicID: payload.comicID,
                chapterID: payload.chapterID
            )
            await DownloadLiveActivityManager.shared.end(
                chapterKey: key,
                finalStatus: DownloadStatus.completed.rawValue,
                comicTitle: payload.comicTitle,
                chapterTitle: payload.chapterTitle,
                downloadedPages: payload.requests.count,
                totalPages: payload.requests.count
            )
            runtimeQueueItems.removeValue(forKey: key)
            await postUpdate(item: nil)
        } catch {
            try? await database.updateDownloadProgress(
                sourceKey: payload.sourceKey,
                comicID: payload.comicID,
                chapterID: payload.chapterID,
                status: .failed,
                downloadedPages: 0,
                totalPages: payload.requests.count,
                errorMessage: error.localizedDescription
            )
            let failedItem = try? await database.getDownloadChapter(
                sourceKey: payload.sourceKey,
                comicID: payload.comicID,
                chapterID: payload.chapterID
            )
            await DownloadLiveActivityManager.shared.end(
                chapterKey: key,
                finalStatus: DownloadStatus.failed.rawValue,
                comicTitle: payload.comicTitle,
                chapterTitle: payload.chapterTitle,
                downloadedPages: 0,
                totalPages: payload.requests.count
            )
            if let failedItem {
                runtimeQueueItems[key] = failedItem
            }
            await postUpdate(item: failedItem)
        }
    }

    // MARK: - Download With Retry

    /// Downloads a single image with exponential backoff retry.
    private func downloadWithRetry(request: ImageRequest, to destinationURL: URL) async throws {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                try await downloadOne(request: request, to: destinationURL)
                return
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    let delayNs = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: delayNs)
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func downloadOne(request: ImageRequest, to destinationURL: URL) async throws {
        guard let urlRequest = makeRequest(from: request) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        try data.write(to: destinationURL, options: .atomic)
    }

    // MARK: - Helpers

    private func writeMetadata(for payload: Payload, in directory: URL) throws {
        let metadata: [String: Any] = [
            "sourceKey": payload.sourceKey,
            "comicID": payload.comicID,
            "comicTitle": payload.comicTitle,
            "coverURL": payload.coverURL ?? "",
            "comicDescription": payload.comicDescription ?? "",
            "chapterID": payload.chapterID,
            "chapterTitle": payload.chapterTitle,
            "totalPages": payload.requests.count,
            "downloadedAt": Int64(Date().timeIntervalSince1970)
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func fileName(for request: ImageRequest, index: Int) -> String {
        let normalizedURL = request.url.hasPrefix("//") ? "https:\(request.url)" : request.url
        let ext: String
        if let url = URL(string: normalizedURL) {
            let candidate = url.pathExtension.lowercased()
            if !candidate.isEmpty {
                ext = candidate
            } else if let type = UTType(filenameExtension: "jpg") {
                ext = type.preferredFilenameExtension ?? "jpg"
            } else {
                ext = "jpg"
            }
        } else {
            ext = "jpg"
        }
        return String(format: "%04d.%@", index + 1, ext)
    }

    private func makeRequest(from request: ImageRequest) -> URLRequest? {
        let normalizedURL = request.url.hasPrefix("//") ? "https:\(request.url)" : request.url
        guard let url = URL(string: normalizedURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.cachePolicy = .reloadIgnoringLocalCacheData

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
        if req.value(forHTTPHeaderField: "Referer") == nil,
           req.value(forHTTPHeaderField: "referer") == nil,
           let host = url.host {
            req.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }
        return req
    }

    private func chapterDirectory(for payload: Payload) -> URL {
        comicDirectory(for: payload)
            .appendingPathComponent(safeName(payload.chapterID), isDirectory: true)
    }

    private func comicDirectory(for payload: Payload) -> URL {
        rootDirectory
            .appendingPathComponent(safeName(payload.sourceKey), isDirectory: true)
            .appendingPathComponent(safeName(payload.comicID), isDirectory: true)
    }

    private func ensureCoverSaved(for payload: Payload, in comicDirectory: URL) async throws {
        guard let coverURL = payload.coverURL,
              let remoteURL = URL(string: coverURL),
              let scheme = remoteURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return
        }

        if let existing = existingCoverFile(in: comicDirectory),
           fileManager.fileExists(atPath: existing.path) {
            return
        }

        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let ext = remoteURL.pathExtension.isEmpty ? "jpg" : remoteURL.pathExtension.lowercased()
        let destination = comicDirectory.appendingPathComponent("cover.\(ext)")
        try data.write(to: destination, options: .atomic)
    }

    private func existingCoverFile(in comicDirectory: URL) -> URL? {
        let supported = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif"]
        return supported
            .map { comicDirectory.appendingPathComponent("cover.\($0)") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private func chapterKey(sourceKey: String, comicID: String, chapterID: String) -> String {
        "\(sourceKey)|\(comicID)|\(chapterID)"
    }

    private func safeName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let name = String(mapped)
        return name.isEmpty ? "_" : name
    }

    private func postUpdate(item: DownloadChapterItem?) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .comicDownloadDidUpdate,
                object: nil,
                userInfo: item.map { [ComicDownloadNotificationKey.item: $0] }
            )
        }
    }

    func currentQueueItems() -> [DownloadChapterItem] {
        runtimeQueueItems.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id > rhs.id
        }
    }
}
