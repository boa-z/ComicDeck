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

        let response: Response = try await perform(
            path: "users/-/collections/\(mediaID)",
            method: "PATCH",
            body: body,
            accessToken: accessToken
        )
        return BangumiSaveResult(
            progress: response.ep_status ?? progress,
            status: response.type.flatMap(trackerStatus)
        )
    }

    private func perform<Response: Decodable>(
        path: String,
        method: String,
        body: Any?,
        accessToken: String
    ) async throws -> Response {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
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
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TrackerError.remoteFailure("Bangumi request failed (\(http.statusCode)): \(bodyText)")
        }
        return try JSONDecoder().decode(Response.self, from: data)
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
