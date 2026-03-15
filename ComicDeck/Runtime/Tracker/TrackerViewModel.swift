import Foundation
import Observation

@MainActor
@Observable
final class TrackerViewModel {
    private enum PersistKey {
        static let tokenService = "boa.ComicDeck.Tracker"
    }

    var accounts: [TrackerProvider: TrackerAccount] = [:]
    var bindings: [String: [TrackerProvider: TrackerBinding]] = [:]
    var pendingEvents: [TrackerSyncEvent] = []
    var status = "Ready"
    var syncing = false

    private var database: SQLiteStore?
    private let aniListClient = AniListTrackerClient()
    private let bangumiClient = BangumiTrackerClient()

    func prepare(database: SQLiteStore) async throws {
        self.database = database
        try await reload()
        await flushPendingSync()
    }

    func reload() async throws {
        guard let database else { throw TrackerError.notPrepared }
        let loadedAccounts = try await database.listTrackerAccounts()
        accounts = Dictionary(uniqueKeysWithValues: loadedAccounts.map { ($0.provider, $0) })
        let loadedBindings = try await database.listTrackerBindings()
        bindings = Dictionary(grouping: loadedBindings) { binding in
            self.bindingKey(sourceKey: binding.sourceKey, comicID: binding.comicID)
        }
            .mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.provider, $0) }) }
        pendingEvents = try await database.listTrackerSyncEvents(limit: 200)
    }

    func account(for provider: TrackerProvider) -> TrackerAccount? {
        accounts[provider]
    }

    func validateConnection(_ provider: TrackerProvider) async throws -> TrackerAccount {
        let token = try accessToken(for: provider)
        let refreshed: TrackerAccount
        switch provider {
        case .aniList:
            let remote = try await aniListClient.validateAccessToken(token)
            refreshed = TrackerAccount(
                provider: .aniList,
                displayName: remote.name,
                remoteUserID: remote.id,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )
        case .bangumi:
            let remote = try await bangumiClient.validateAccessToken(token)
            refreshed = TrackerAccount(
                provider: .bangumi,
                displayName: remote.nickname.isEmpty ? remote.username : remote.nickname,
                remoteUserID: remote.id,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )
        }
        guard let database else { throw TrackerError.notPrepared }
        try await database.upsertTrackerAccount(refreshed)
        accounts[provider] = refreshed
        status = "Validated \(provider.title) connection"
        return refreshed
    }

    func binding(for item: ComicSummary, provider: TrackerProvider) -> TrackerBinding? {
        bindings[bindingKey(sourceKey: item.sourceKey, comicID: item.id)]?[provider]
    }

    func connectAniList(accessToken: String) async throws {
        try await connect(provider: .aniList, accessToken: accessToken)
    }

    func connectBangumi(accessToken: String) async throws {
        try await connect(provider: .bangumi, accessToken: accessToken)
    }

    private func connect(provider: TrackerProvider, accessToken: String) async throws {
        let trimmed = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TrackerError.invalidConfiguration("\(provider.title) access token cannot be empty.")
        }
        let viewer: TrackerAccount
        switch provider {
        case .aniList:
            let remote = try await aniListClient.validateAccessToken(trimmed)
            viewer = TrackerAccount(
                provider: .aniList,
                displayName: remote.name,
                remoteUserID: remote.id,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )
        case .bangumi:
            let remote = try await bangumiClient.validateAccessToken(trimmed)
            viewer = TrackerAccount(
                provider: .bangumi,
                displayName: remote.nickname.isEmpty ? remote.username : remote.nickname,
                remoteUserID: remote.id,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )
        }
        try SecureStore.save(trimmed, service: PersistKey.tokenService, account: tokenAccount(for: provider))
        guard let database else { throw TrackerError.notPrepared }
        try await database.upsertTrackerAccount(viewer)
        accounts[provider] = viewer
        status = "Connected \(provider.title) as \(viewer.displayName)"
    }

    func disconnect(_ provider: TrackerProvider) async throws {
        guard let database else { throw TrackerError.notPrepared }
        try SecureStore.save("", service: PersistKey.tokenService, account: tokenAccount(for: provider))
        try await database.deleteTrackerAccount(provider: provider)
        accounts.removeValue(forKey: provider)
        status = "Disconnected \(provider.title)"
    }

    func searchAniList(query: String) async throws -> [TrackerSearchResult] {
        let token = try accessToken(for: .aniList)
        return try await aniListClient.searchManga(title: query, accessToken: token)
    }

    func searchBangumi(query: String) async throws -> [TrackerSearchResult] {
        let token = try accessToken(for: .bangumi)
        return try await bangumiClient.searchManga(title: query, accessToken: token)
    }

    func search(_ provider: TrackerProvider, query: String) async throws -> [TrackerSearchResult] {
        switch provider {
        case .aniList:
            return try await searchAniList(query: query)
        case .bangumi:
            return try await searchBangumi(query: query)
        }
    }

    func bind(_ item: ComicSummary, provider: TrackerProvider, result: TrackerSearchResult) async throws {
        guard let database else { throw TrackerError.notPrepared }
        let binding = try await database.upsertTrackerBinding(
            provider: provider,
            sourceKey: item.sourceKey,
            comicID: item.id,
            remoteMediaID: result.id,
            remoteTitle: result.title,
            remoteCoverURL: result.coverURL,
            lastSyncedProgress: 0,
            lastSyncedStatus: nil
        )
        let key = bindingKey(sourceKey: item.sourceKey, comicID: item.id)
        bindings[key, default: [:]][provider] = binding
        status = "Linked to \(provider.title)"
    }

    func unbind(_ item: ComicSummary, provider: TrackerProvider) async throws {
        guard let database else { throw TrackerError.notPrepared }
        try await database.deleteTrackerBinding(provider: provider, sourceKey: item.sourceKey, comicID: item.id)
        let key = bindingKey(sourceKey: item.sourceKey, comicID: item.id)
        bindings[key]?[provider] = nil
        if bindings[key]?.isEmpty == true {
            bindings[key] = nil
        }
        pendingEvents.removeAll { $0.provider == provider && $0.sourceKey == item.sourceKey && $0.comicID == item.id }
        status = "Unlinked from \(provider.title)"
    }

    func syncNow(_ item: ComicSummary, progress: Int, status targetStatus: TrackerReadingStatus?, provider: TrackerProvider) async throws {
        guard let binding = binding(for: item, provider: provider) else {
            throw TrackerError.invalidConfiguration("No tracker binding exists yet.")
        }
        guard let database else { throw TrackerError.notPrepared }
        _ = try await database.enqueueTrackerSyncEvent(
            provider: provider,
            sourceKey: item.sourceKey,
            comicID: item.id,
            remoteMediaID: binding.remoteMediaID,
            targetProgress: progress,
            targetStatus: targetStatus
        )
        pendingEvents = try await database.listTrackerSyncEvents(limit: 200)
        await flushPendingSync()
    }

    func recordChapterCompletion(item: ComicSummary, chapterSequence: [ComicChapter], chapterID: String) async {
        guard !chapterSequence.isEmpty else { return }
        let progress = (chapterSequence.firstIndex(where: { $0.id == chapterID }) ?? -1) + 1
        guard progress > 0 else { return }
        let targetStatus: TrackerReadingStatus = progress >= chapterSequence.count ? .completed : .current
        do {
            guard let database else { throw TrackerError.notPrepared }
            for provider in TrackerProvider.allCases {
                guard let binding = binding(for: item, provider: provider) else { continue }
                _ = try await database.enqueueTrackerSyncEvent(
                    provider: provider,
                    sourceKey: item.sourceKey,
                    comicID: item.id,
                    remoteMediaID: binding.remoteMediaID,
                    targetProgress: progress,
                    targetStatus: targetStatus
                )
            }
            pendingEvents = try await database.listTrackerSyncEvents(limit: 200)
            await flushPendingSync()
        } catch {
            status = error.localizedDescription
        }
    }

    func flushPendingSync() async {
        guard !syncing else { return }
        guard let database else { return }
        syncing = true
        defer { syncing = false }
        do {
            let events = try await database.listTrackerSyncEvents(limit: 200)
            pendingEvents = events
            for event in events {
                do {
                    try await process(event)
                    try await database.deleteTrackerSyncEvent(id: event.id)
                } catch {
                    try? await database.markTrackerSyncEventFailed(id: event.id, errorMessage: error.localizedDescription)
                    status = "Tracker sync failed: \(error.localizedDescription)"
                }
            }
            try await reload()
            if pendingEvents.isEmpty {
                status = "Tracker sync complete"
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func process(_ event: TrackerSyncEvent) async throws {
        switch event.provider {
        case .aniList:
            let token = try accessToken(for: .aniList)
            let result = try await aniListClient.saveProgress(
                mediaID: event.remoteMediaID,
                progress: event.targetProgress,
                status: event.targetStatus,
                accessToken: token
            )
            guard let database else { throw TrackerError.notPrepared }
            _ = try await database.upsertTrackerBinding(
                provider: event.provider,
                sourceKey: event.sourceKey,
                comicID: event.comicID,
                remoteMediaID: event.remoteMediaID,
                remoteTitle: bindings[bindingKey(sourceKey: event.sourceKey, comicID: event.comicID)]?[event.provider]?.remoteTitle ?? event.remoteMediaID,
                remoteCoverURL: bindings[bindingKey(sourceKey: event.sourceKey, comicID: event.comicID)]?[event.provider]?.remoteCoverURL,
                lastSyncedProgress: result.progress,
                lastSyncedStatus: result.status ?? event.targetStatus
            )
        case .bangumi:
            let token = try accessToken(for: .bangumi)
            let result = try await bangumiClient.saveProgress(
                mediaID: event.remoteMediaID,
                progress: event.targetProgress,
                status: event.targetStatus,
                accessToken: token
            )
            guard let database else { throw TrackerError.notPrepared }
            _ = try await database.upsertTrackerBinding(
                provider: event.provider,
                sourceKey: event.sourceKey,
                comicID: event.comicID,
                remoteMediaID: event.remoteMediaID,
                remoteTitle: bindings[bindingKey(sourceKey: event.sourceKey, comicID: event.comicID)]?[event.provider]?.remoteTitle ?? event.remoteMediaID,
                remoteCoverURL: bindings[bindingKey(sourceKey: event.sourceKey, comicID: event.comicID)]?[event.provider]?.remoteCoverURL,
                lastSyncedProgress: result.progress,
                lastSyncedStatus: result.status ?? event.targetStatus
            )
        }
    }

    private func accessToken(for provider: TrackerProvider) throws -> String {
        let rawToken = try SecureStore.read(service: PersistKey.tokenService, account: tokenAccount(for: provider))
        let token = rawToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, !token.isEmpty else {
            throw TrackerError.missingAccessToken(provider)
        }
        return token
    }

    private func tokenAccount(for provider: TrackerProvider) -> String {
        "token.\(provider.rawValue)"
    }

    private func bindingKey(sourceKey: String, comicID: String) -> String {
        "\(sourceKey)::\(comicID)"
    }
}
