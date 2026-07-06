import Foundation

struct BangumiViewer: Hashable {
    let id: String
    let username: String
    let nickname: String
}

struct BangumiSaveResult: Hashable {
    let progress: Int
    let status: TrackerReadingStatus?
}

struct BangumiTrackerClient {
    private let endpoint = URL(string: "https://api.bgm.tv/v0")!
    private let session: URLSession
    private let userAgent = "ComicDeck/0.0.1 (iOS; Tracker Integration)"

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateAccessToken(_ accessToken: String) async throws -> BangumiViewer {
        struct Response: Decodable {
            let id: Int
            let username: String
            let nickname: String
        }

        let response: Response = try await perform(
            path: "me",
            method: "GET",
            body: nil,
            accessToken: accessToken
        )
        return BangumiViewer(
            id: String(response.id),
            username: response.username,
            nickname: response.nickname
        )
    }

    func searchManga(title: String, accessToken: String) async throws -> [TrackerSearchResult] {
        struct Response: Decodable {
            struct Subject: Decodable {
                struct Images: Decodable {
                    let small: String?
                    let medium: String?
                    let large: String?
                }
                let id: Int
                let name: String
                let name_cn: String?
                let date: String?
                let images: Images?
                let eps: Int?
                let volumes: Int?
            }
            let data: [Subject]
        }

        let response: Response = try await perform(
            path: "search/subjects",
            method: "POST",
            body: [
                "keyword": title,
                "sort": "match",
                "filter": ["type": [1]]
            ],
            accessToken: accessToken
        )
        return response.data.map { subject in
            TrackerSearchResult(
                id: String(subject.id),
                title: subject.name_cn?.isEmpty == false ? (subject.name_cn ?? subject.name) : subject.name,
                subtitle: subject.name_cn == subject.name ? nil : subject.name,
                coverURL: subject.images?.large ?? subject.images?.medium ?? subject.images?.small,
                statusText: subject.date,
                chapterCount: subject.eps ?? subject.volumes,
                siteURL: "https://bgm.tv/subject/\(subject.id)"
            )
        }
    }

    func listMangaList(username: String, accessToken: String) async throws -> [TrackerListEntry] {
        struct Entry: Decodable {
            struct Subject: Decodable {
                struct Images: Decodable {
                    let small: String?
                    let medium: String?
                    let large: String?
                }
                let id: Int
                let type: Int?
                let name: String
                let name_cn: String?
                let images: Images?
                let eps: Int?
                let volumes: Int?
            }
            let subject: Subject
            let type: Int?
            let ep_status: Int?
            let updatedAt: Int64?

            enum CodingKeys: String, CodingKey {
                case subject
                case type
                case ep_status
                case updatedAt = "updated_at"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                subject = try container.decode(Subject.self, forKey: .subject)
                type = try container.decodeIfPresent(Int.self, forKey: .type)
                ep_status = try container.decodeIfPresent(Int.self, forKey: .ep_status)
                if let timestamp = try? container.decodeIfPresent(Int64.self, forKey: .updatedAt) {
                    updatedAt = timestamp
                } else if let raw = try? container.decodeIfPresent(String.self, forKey: .updatedAt) {
                    updatedAt = Self.timestamp(from: raw)
                } else {
                    updatedAt = nil
                }
            }

            private static func timestamp(from raw: String) -> Int64? {
                BangumiTimestampParser.timestamp(from: raw)
            }
        }

        struct Page: Decodable {
            let total: Int?
            let data: [Entry]
        }

        let pageSize = 50
        var offset = 0
        var entries: [Entry] = []
        while true {
            let page: Page = try await perform(
                path: "users/\(username)/collections",
                queryItems: [
                    URLQueryItem(name: "subject_type", value: "1"),
                    URLQueryItem(name: "limit", value: String(pageSize)),
                    URLQueryItem(name: "offset", value: String(offset))
                ],
                method: "GET",
                body: nil,
                accessToken: accessToken
            )
            entries.append(contentsOf: page.data)
            offset += page.data.count
            guard page.data.count == pageSize else { break }
            if let total = page.total, offset >= total { break }
        }

        let sortedEntries = entries
            .filter { $0.subject.type.map { $0 == 1 } ?? true }
            .map { entry in
                let title = entry.subject.name_cn?.isEmpty == false ? (entry.subject.name_cn ?? entry.subject.name) : entry.subject.name
                let subtitle = entry.subject.name_cn == entry.subject.name ? nil : entry.subject.name
                return TrackerListEntry(
                    id: String(entry.subject.id),
                    provider: .bangumi,
                    mediaID: String(entry.subject.id),
                    title: title,
                    subtitle: subtitle?.isEmpty == false ? subtitle : nil,
                    coverURL: entry.subject.images?.large ?? entry.subject.images?.medium ?? entry.subject.images?.small,
                    status: entry.type.flatMap(trackerStatus),
                    progress: entry.ep_status ?? 0,
                    chapterCount: entry.subject.eps ?? entry.subject.volumes,
                    siteURL: "https://bgm.tv/subject/\(entry.subject.id)",
                    updatedAt: entry.updatedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return (lhs.updatedAt ?? 0) > (rhs.updatedAt ?? 0)
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        var seenMediaIDs = Set<String>()
        return sortedEntries.filter { entry in
            seenMediaIDs.insert(entry.mediaID).inserted
        }
    }

    func saveProgress(
        mediaID: String,
        progress: Int,
        status: TrackerReadingStatus?,
        accessToken: String
    ) async throws -> BangumiSaveResult {
        struct Response: Decodable {
            let ep_status: Int?
            let type: Int?
        }

        var body: [String: Any] = [
            "ep_status": max(0, progress)
        ]
        if let status {
            body["type"] = bangumiCollectionType(status)
        }

        let path = "users/-/collections/\(mediaID.trimmingCharacters(in: .whitespacesAndNewlines))"
        let (http, data) = try await request(
            path: path,
            method: "PATCH",
            body: body,
            accessToken: accessToken
        )
        if (200...299).contains(http.statusCode) {
            if let response: Response = try? decodeResponse(data) {
                return BangumiSaveResult(
                    progress: response.ep_status ?? progress,
                    status: response.type.flatMap(trackerStatus)
                )
            }
            return BangumiSaveResult(progress: progress, status: status)
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 404, bodyText.localizedCaseInsensitiveContains("subject not collected") {
            let (postHTTP, postData) = try await request(
                path: path,
                method: "POST",
                body: body,
                accessToken: accessToken
            )
            guard (200...299).contains(postHTTP.statusCode) else {
                let postBody = String(data: postData, encoding: .utf8) ?? ""
                throw TrackerError.remoteFailure("Bangumi request failed (\(postHTTP.statusCode)): \(postBody)")
            }
            if let response: Response = try? decodeResponse(postData) {
                return BangumiSaveResult(
                    progress: response.ep_status ?? progress,
                    status: response.type.flatMap(trackerStatus)
                )
            }
            return BangumiSaveResult(progress: progress, status: status)
        }

        throw TrackerError.remoteFailure("Bangumi request failed (\(http.statusCode)): \(bodyText)")
    }

    private func perform<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String,
        body: Any?,
        accessToken: String
    ) async throws -> Response {
        let (http, data) = try await request(
            path: path,
            queryItems: queryItems,
            method: method,
            body: body,
            accessToken: accessToken
        )
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TrackerError.remoteFailure("Bangumi request failed (\(http.statusCode)): \(bodyText)")
        }
        return try decodeResponse(data)
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String,
        body: Any?,
        accessToken: String
    ) async throws -> (HTTPURLResponse, Data) {
        var components = URLComponents(url: endpoint.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw TrackerError.invalidConfiguration("Bangumi request URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrackerError.remoteFailure("Bangumi did not return an HTTP response.")
        }
        return (http, data)
    }

    private func decodeResponse<Response: Decodable>(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    private func bangumiCollectionType(_ status: TrackerReadingStatus) -> Int {
        switch status {
        case .planning: return 1
        case .completed: return 2
        case .current: return 3
        case .paused: return 4
        case .dropped: return 5
        }
    }

    private func trackerStatus(_ type: Int) -> TrackerReadingStatus? {
        switch type {
        case 1: return .planning
        case 2: return .completed
        case 3: return .current
        case 4: return .paused
        case 5: return .dropped
        default: return nil
        }
    }
}

private enum BangumiTimestampParser {
    private static let iso8601 = Date.ISO8601FormatStyle()
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static func timestamp(from raw: String) -> Int64? {
        if let timestamp = Int64(raw) {
            return timestamp
        }
        if let date = try? iso8601.parse(raw) {
            return Int64(date.timeIntervalSince1970)
        }
        if let date = try? fractionalISO8601.parse(raw) {
            return Int64(date.timeIntervalSince1970)
        }
        return nil
    }
}
