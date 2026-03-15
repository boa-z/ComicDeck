import Foundation

struct AniListViewer: Hashable {
    let id: String
    let name: String
}

struct AniListSaveResult: Hashable {
    let progress: Int
    let status: TrackerReadingStatus?
}

struct AniListTrackerClient {
    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private let oauthTokenEndpoint = URL(string: "https://anilist.co/api/v2/oauth/token")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validateAccessToken(_ accessToken: String) async throws -> AniListViewer {
        struct Response: Decodable {
            struct DataBody: Decodable {
                struct Viewer: Decodable {
                    let id: Int
                    let name: String
                }
                let viewer: Viewer

                enum CodingKeys: String, CodingKey {
                    case viewer = "Viewer"
                }
            }
            let data: DataBody?
            let errors: [GraphQLError]?
        }

        let response: Response = try await perform(
            query: "query { Viewer { id name } }",
            variables: [:],
            accessToken: accessToken
        )
        if let message = response.errors?.first?.message {
            throw TrackerError.remoteFailure(message)
        }
        guard let viewer = response.data?.viewer else {
            throw TrackerError.remoteFailure("AniList did not return a viewer profile.")
        }
        return AniListViewer(id: String(viewer.id), name: viewer.name)
    }

    func exchangeAuthorizationCode(
        clientID: String,
        clientSecret: String,
        authorizationCode: String
    ) async throws -> String {
        struct Response: Decodable {
            let access_token: String
            let token_type: String
        }

        var request = URLRequest(url: oauthTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "redirect_uri", value: AniListOAuthSession.redirectURI),
            URLQueryItem(name: "code", value: authorizationCode)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrackerError.remoteFailure("AniList OAuth token exchange did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TrackerError.remoteFailure("AniList OAuth token exchange failed (\(http.statusCode)): \(body)")
        }
        let tokenResponse = try JSONDecoder().decode(Response.self, from: data)
        guard tokenResponse.token_type.lowercased() == "bearer" else {
            throw TrackerError.remoteFailure("AniList OAuth returned an unsupported token type.")
        }
        return tokenResponse.access_token
    }

    func searchManga(title: String, accessToken: String) async throws -> [TrackerSearchResult] {
        struct Response: Decodable {
            struct DataBody: Decodable {
                struct Page: Decodable {
                    struct Media: Decodable {
                        struct Title: Decodable {
                            let romaji: String?
                            let english: String?
                            let native: String?
                            let userPreferred: String?
                        }
                        struct CoverImage: Decodable {
                            let large: String?
                            let medium: String?
                        }
                        let id: Int
                        let title: Title
                        let status: String?
                        let chapters: Int?
                        let siteUrl: String?
                        let coverImage: CoverImage?
                    }
                    let media: [Media]
                }
                let page: Page

                enum CodingKeys: String, CodingKey {
                    case page = "Page"
                }
            }
            let data: DataBody?
            let errors: [GraphQLError]?
        }

        let response: Response = try await perform(
            query: "query ($search: String!) { Page(page: 1, perPage: 12) { media(search: $search, type: MANGA, sort: SEARCH_MATCH) { id title { romaji english native userPreferred } status chapters siteUrl coverImage { large medium } } } }",
            variables: ["search": title],
            accessToken: accessToken
        )
        if let message = response.errors?.first?.message {
            throw TrackerError.remoteFailure(message)
        }
        return response.data?.page.media.map { media in
            let preferred = media.title.userPreferred ?? media.title.romaji ?? media.title.english ?? media.title.native ?? String(media.id)
            let subtitle = [media.title.native, media.title.english]
                .compactMap { value in
                    guard let value, !value.isEmpty, value != preferred else { return nil }
                    return value
                }
                .joined(separator: " · ")
            return TrackerSearchResult(
                id: String(media.id),
                title: preferred,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                coverURL: media.coverImage?.large ?? media.coverImage?.medium,
                statusText: media.status,
                chapterCount: media.chapters,
                siteURL: media.siteUrl
            )
        } ?? []
    }

    func saveProgress(
        mediaID: String,
        progress: Int,
        status: TrackerReadingStatus?,
        accessToken: String
    ) async throws -> AniListSaveResult {
        struct Response: Decodable {
            struct DataBody: Decodable {
                struct Entry: Decodable {
                    let progress: Int?
                    let status: String?
                }
                let saveMediaListEntry: Entry?

                enum CodingKeys: String, CodingKey {
                    case saveMediaListEntry = "SaveMediaListEntry"
                }
            }
            let data: DataBody?
            let errors: [GraphQLError]?
        }

        var variables: [String: Any] = [
            "mediaId": Int(mediaID) ?? 0,
            "progress": max(0, progress)
        ]
        if let status {
            variables["status"] = anilistStatus(status)
        }

        let response: Response = try await perform(
            query: "mutation ($mediaId: Int!, $progress: Int!, $status: MediaListStatus) { SaveMediaListEntry(mediaId: $mediaId, progress: $progress, status: $status) { progress status } }",
            variables: variables,
            accessToken: accessToken
        )
        if let message = response.errors?.first?.message {
            throw TrackerError.remoteFailure(message)
        }
        let entry = response.data?.saveMediaListEntry
        return AniListSaveResult(
            progress: entry?.progress ?? progress,
            status: entry?.status.flatMap(trackerStatus)
        )
    }

    private func perform<Response: Decodable>(
        query: String,
        variables: [String: Any],
        accessToken: String
    ) async throws -> Response {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query,
            "variables": variables
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrackerError.remoteFailure("AniList did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TrackerError.remoteFailure("AniList request failed (\(http.statusCode)): \(body)")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func anilistStatus(_ status: TrackerReadingStatus) -> String {
        switch status {
        case .current: return "CURRENT"
        case .completed: return "COMPLETED"
        case .paused: return "PAUSED"
        case .planning: return "PLANNING"
        case .dropped: return "DROPPED"
        }
    }

    private func trackerStatus(_ raw: String) -> TrackerReadingStatus? {
        switch raw.uppercased() {
        case "CURRENT": return .current
        case "COMPLETED": return .completed
        case "PAUSED": return .paused
        case "PLANNING": return .planning
        case "DROPPED": return .dropped
        default: return nil
        }
    }
}

private struct GraphQLError: Decodable {
    let message: String
}
