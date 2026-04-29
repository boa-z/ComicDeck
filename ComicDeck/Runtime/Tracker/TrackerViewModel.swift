import Foundation
import Observation

@MainActor
@Observable
final class TrackerViewModel {
    private enum PersistKey {
        static let tokenService = "boa.ComicDeck.Tracker"
        static let automaticSyncEnabled = "tracking.sync.automatic.enabled"
        static let automaticSyncDirection = "tracking.sync.automatic.direction"
        static let manualSyncDefaultDirection = "tracking.sync.manual.defaultDirection"

        static func automaticProviderSyncEnabled(_ provider: TrackerProvider) -> String {
            "tracking.sync.automatic.provider.\(provider.rawValue).enabled"
        }
    }

    var accounts: [TrackerProvider: TrackerAccount] = [:]
    var bindings: [String: [TrackerProvider: TrackerBinding]] = [:]
    var pendingEvents: [TrackerSyncEvent] = []
    var status = AppLocalization.text("tracking.status.ready", "Ready")
    var syncing = false
    var automaticSyncEnabled: Bool {
        didSet { UserDefaults.standard.set(automaticSyncEnabled, forKey: PersistKey.automaticSyncEnabled) }
    }
    var automaticSyncDirection: TrackerSyncDirection {
        didSet { UserDefaults.standard.set(automaticSyncDirection.rawValue, forKey: PersistKey.automaticSyncDirection) }
    }
    var manualSyncDefaultDirection: TrackerSyncDirection {
        didSet { UserDefaults.standard.set(manualSyncDefaultDirection.rawValue, forKey: PersistKey.manualSyncDefaultDirection) }
    }
    var automaticProviderSyncEnabled: [TrackerProvider: Bool]

    private var database: SQLiteStore?
    private let aniListClient = AniListTrackerClient()
    private let bangumiClient = BangumiTrackerClient()

    init(userDefaults: UserDefaults = .standard) {
        automaticSyncEnabled = Self.automaticSyncEnabled(from: userDefaults)
        automaticSyncDirection = Self.syncDirection(
            from: userDefaults.string(forKey: PersistKey.automaticSyncDirection),
            defaultValue: .localToRemote
        )
        manualSyncDefaultDirection = Self.syncDirection(
            from: userDefaults.string(forKey: PersistKey.manualSyncDefaultDirection),
            defaultValue: .localToRemote
        )
        automaticProviderSyncEnabled = Self.automaticProviderSyncEnabled(from: userDefaults)
    }

    func reloadSyncPreferences(userDefaults: UserDefaults = .standard) {
        automaticSyncEnabled = Self.automaticSyncEnabled(from: userDefaults)
        automaticSyncDirection = Self.syncDirection(
            from: userDefaults.string(forKey: PersistKey.automaticSyncDirection),
            defaultValue: .localToRemote
        )
        manualSyncDefaultDirection = Self.syncDirection(
            from: userDefaults.string(forKey: PersistKey.manualSyncDefaultDirection),
            defaultValue: .localToRemote
        )
        automaticProviderSyncEnabled = Self.automaticProviderSyncEnabled(from: userDefaults)
    }

    func prepare(database: SQLiteStore) async throws {
        self.database = database
        try await reload()
        await flushPendingSync()
    }

    func setAutomaticSyncEnabled(_ enabled: Bool, for provider: TrackerProvider) {
        automaticProviderSyncEnabled[provider] = enabled
        UserDefaults.standard.set(enabled, forKey: PersistKey.automaticProviderSyncEnabled(provider))
    }

    func automaticSyncEnabled(for provider: TrackerProvider) -> Bool {
        automaticProviderSyncEnabled[provider] ?? true
    }

    private static func automaticSyncEnabled(from userDefaults: UserDefaults) -> Bool {
        userDefaults.object(forKey: PersistKey.automaticSyncEnabled) == nil
            ? true
            : userDefaults.bool(forKey: PersistKey.automaticSyncEnabled)
    }

    private static func automaticProviderSyncEnabled(from userDefaults: UserDefaults) -> [TrackerProvider: Bool] {
        Dictionary(uniqueKeysWithValues: TrackerProvider.allCases.map { provider in
            let key = PersistKey.automaticProviderSyncEnabled(provider)
            let enabled = userDefaults.object(forKey: key) == nil ? true : userDefaults.bool(forKey: key)
            return (provider, enabled)
        })
    }

    private static func syncDirection(from rawValue: String?, defaultValue: TrackerSyncDirection) -> TrackerSyncDirection {
        guard let rawValue, let direction = TrackerSyncDirection(rawValue: rawValue) else { return defaultValue }
        return direction
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
                remoteUserID: remote.username,
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

    func bindingGroups(provider: TrackerProvider, remoteMediaID: String) -> [[TrackerProvider: TrackerBinding]] {
        bindings.values
            .filter { providerBindings in
                providerBindings[provider]?.remoteMediaID == remoteMediaID
            }
            .sorted { lhs, rhs in
                guard let left = lhs[provider], let right = rhs[provider] else { return false }
                if left.sourceKey != right.sourceKey {
                    return left.sourceKey.localizedStandardCompare(right.sourceKey) == .orderedAscending
                }
                return left.comicID.localizedStandardCompare(right.comicID) == .orderedAscending
            }
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
                remoteUserID: remote.username,
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

    func loadMangaList(provider: TrackerProvider) async throws -> [TrackerListEntry] {
        guard let account = account(for: provider) else {
            throw TrackerError.missingAccessToken(provider)
        }
        let token = try accessToken(for: provider)
        let entries: [TrackerListEntry]
        switch provider {
        case .aniList:
            entries = try await aniListClient.listMangaList(userID: account.remoteUserID, accessToken: token)
        case .bangumi:
            entries = try await loadBangumiMangaList(account: account, accessToken: token)
        }
        status = AppLocalization.format(
            "tracking.subscriptions.loaded_status_format",
            "Loaded %@ %@ manga",
            String(entries.count),
            provider.title
        )
        return entries
    }

    private func loadBangumiMangaList(account: TrackerAccount, accessToken: String) async throws -> [TrackerListEntry] {
        do {
            return try await bangumiClient.listMangaList(username: account.remoteUserID, accessToken: accessToken)
        } catch {
            let remote = try await bangumiClient.validateAccessToken(accessToken)
            guard remote.username != account.remoteUserID else { throw error }
            let refreshed = TrackerAccount(
                provider: .bangumi,
                displayName: remote.nickname.isEmpty ? remote.username : remote.nickname,
                remoteUserID: remote.username,
                updatedAt: Int64(Date().timeIntervalSince1970)
            )
            guard let database else { throw TrackerError.notPrepared }
            try await database.upsertTrackerAccount(refreshed)
            accounts[.bangumi] = refreshed
            return try await bangumiClient.listMangaList(username: remote.username, accessToken: accessToken)
        }
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

    func bind(
        _ item: ComicSummary,
        provider: TrackerProvider,
        result: TrackerSearchResult,
        initialProgress: Int = 0,
        initialStatus: TrackerReadingStatus? = nil
    ) async throws {
        guard let database else { throw TrackerError.notPrepared }
        let binding = try await database.upsertTrackerBinding(
            provider: provider,
            sourceKey: item.sourceKey,
            comicID: item.id,
            remoteMediaID: result.id,
            remoteTitle: result.title,
            remoteCoverURL: result.coverURL,
            sourceTitle: item.title,
            sourceCoverURL: item.coverURL,
            lastSyncedProgress: initialProgress,
            lastSyncedStatus: initialStatus
        )
        let key = bindingKey(sourceKey: item.sourceKey, comicID: item.id)
        bindings[key, default: [:]][provider] = binding
        status = AppLocalization.format("tracking.binding.status.linked_format", "Linked to %@", provider.title)
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
        status = AppLocalization.format("tracking.binding.status.unlinked_format", "Unlinked from %@", provider.title)
    }

    func syncNow(_ item: ComicSummary, progress: Int, status targetStatus: TrackerReadingStatus?, provider: TrackerProvider) async throws {
        guard !syncing else {
            throw TrackerError.invalidConfiguration(AppLocalization.text("tracking.sync.error.already_running", "Tracker sync is already running."))
        }
        guard let binding = binding(for: item, provider: provider) else {
            throw TrackerError.invalidConfiguration(AppLocalization.text("tracking.sync.error.no_binding", "No tracker binding exists yet."))
        }
        guard let database else { throw TrackerError.notPrepared }
        let event = try await database.enqueueTrackerSyncEvent(
            provider: provider,
            sourceKey: item.sourceKey,
            comicID: item.id,
            remoteMediaID: binding.remoteMediaID,
            targetProgress: progress,
            targetStatus: targetStatus
        )
        pendingEvents = try await database.listTrackerSyncEvents(limit: 200)
        syncing = true
        defer { syncing = false }
        do {
            try await process(event)
            try await database.deleteTrackerSyncEvent(id: event.id)
            try await reload()
        } catch {
            try? await database.markTrackerSyncEventFailed(id: event.id, errorMessage: error.localizedDescription)
            pendingEvents = try await database.listTrackerSyncEvents(limit: 200)
            status = AppLocalization.format("tracking.sync.status.failed_format", "Tracker sync failed: %@", error.localizedDescription)
            throw error
        }
    }

    func recordChapterCompletion(item: ComicSummary, chapterSequence: [ComicChapter], chapterID: String) async {
        guard automaticSyncEnabled, automaticSyncDirection != .remoteToLocal else { return }
        guard !chapterSequence.isEmpty else { return }
        let progress = (chapterSequence.firstIndex(where: { $0.id == chapterID }) ?? -1) + 1
        guard progress > 0 else { return }
        let targetStatus: TrackerReadingStatus = progress >= chapterSequence.count ? .completed : .current
        do {
            guard let database else { throw TrackerError.notPrepared }
            for provider in TrackerProvider.allCases {
                guard account(for: provider) != nil, automaticSyncEnabled(for: provider) else { continue }
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

    func sync(
        item: ComicSummary,
        chapterSequence: [ComicChapter],
        provider: TrackerProvider,
        direction: TrackerSyncDirection,
        library: LibraryViewModel,
        allowLocalRegression: Bool
    ) async throws -> TrackerSyncSummary {
        guard let binding = binding(for: item, provider: provider) else {
            throw TrackerError.invalidConfiguration(AppLocalization.text("tracking.sync.error.no_binding", "No tracker binding exists yet."))
        }

        switch direction {
        case .localToRemote:
            let local = localProgress(item: item, chapterSequence: chapterSequence, library: library)
            try await syncNow(item, progress: local.progress, status: local.status, provider: provider)
            return TrackerSyncSummary(
                provider: provider,
                direction: direction,
                progress: local.progress,
                status: local.status,
                updatedLocalHistory: false,
                pushedRemote: true,
                pulledRemote: false
            )
        case .remoteToLocal:
            let remote = try await remoteEntry(for: binding, provider: provider)
            _ = try await updateBindingMetadata(from: remote, binding: binding)
            let updatedHistory = await applyRemoteProgress(
                remote,
                to: item,
                binding: binding,
                chapterSequence: chapterSequence,
                library: library,
                allowLocalRegression: allowLocalRegression
            )
            return TrackerSyncSummary(
                provider: provider,
                direction: direction,
                progress: remote.progress,
                status: remote.status,
                updatedLocalHistory: updatedHistory,
                pushedRemote: false,
                pulledRemote: true
            )
        case .bidirectional:
            let local = localProgress(item: item, chapterSequence: chapterSequence, library: library)
            let remote = try await remoteEntry(for: binding, provider: provider)
            if local.progress > remote.progress {
                try await syncNow(item, progress: local.progress, status: local.status, provider: provider)
                return TrackerSyncSummary(
                    provider: provider,
                    direction: direction,
                    progress: local.progress,
                    status: local.status,
                    updatedLocalHistory: false,
                    pushedRemote: true,
                    pulledRemote: false
                )
            }

            _ = try await updateBindingMetadata(from: remote, binding: binding)
            let updatedHistory = await applyRemoteProgress(
                remote,
                to: item,
                binding: binding,
                chapterSequence: chapterSequence,
                library: library,
                allowLocalRegression: allowLocalRegression
            )
            return TrackerSyncSummary(
                provider: provider,
                direction: direction,
                progress: remote.progress,
                status: remote.status,
                updatedLocalHistory: updatedHistory,
                pushedRemote: false,
                pulledRemote: true
            )
        }
    }

    private func localProgress(item: ComicSummary, chapterSequence: [ComicChapter], library: LibraryViewModel) -> (progress: Int, status: TrackerReadingStatus) {
        guard let history = library.latestHistoryForComic(sourceKey: item.sourceKey, comicID: item.id),
              let chapterID = history.chapterID,
              let index = chapterSequence.firstIndex(where: { $0.id == chapterID }) else {
            return (0, .planning)
        }
        let progress = index + 1
        return (progress, progress >= chapterSequence.count ? .completed : .current)
    }

    private func remoteEntry(for binding: TrackerBinding, provider: TrackerProvider) async throws -> TrackerListEntry {
        let entries = try await loadMangaList(provider: provider)
        guard let entry = entries.first(where: { $0.mediaID == binding.remoteMediaID }) else {
            throw TrackerError.remoteFailure(AppLocalization.format(
                "tracking.sync.error.remote_entry_missing_format",
                "Could not find remote tracker entry in %@ library.",
                provider.title
            ))
        }
        return entry
    }

    private func updateBindingMetadata(from entry: TrackerListEntry, binding: TrackerBinding) async throws -> TrackerBinding {
        guard let database else { throw TrackerError.notPrepared }
        let updated = try await database.upsertTrackerBinding(
            provider: binding.provider,
            sourceKey: binding.sourceKey,
            comicID: binding.comicID,
            remoteMediaID: binding.remoteMediaID,
            remoteTitle: entry.title,
            remoteCoverURL: entry.coverURL,
            lastSyncedProgress: entry.progress,
            lastSyncedStatus: entry.status
        )
        bindings[bindingKey(sourceKey: binding.sourceKey, comicID: binding.comicID), default: [:]][binding.provider] = updated
        return updated
    }

    private func applyRemoteProgress(
        _ entry: TrackerListEntry,
        to item: ComicSummary,
        binding: TrackerBinding,
        chapterSequence: [ComicChapter],
        library: LibraryViewModel,
        allowLocalRegression: Bool
    ) async -> Bool {
        guard !chapterSequence.isEmpty, entry.progress > 0 else { return false }
        let local = localProgress(item: item, chapterSequence: chapterSequence, library: library)
        guard entry.progress != local.progress else { return false }
        guard allowLocalRegression || entry.progress > local.progress else { return false }
        let index = min(max(entry.progress, 1), chapterSequence.count) - 1
        let chapter = chapterSequence[index]
        await library.recordReadingHistory(
            comicID: binding.comicID,
            sourceKey: binding.sourceKey,
            title: item.title,
            coverURL: item.coverURL,
            author: item.author,
            tags: item.tags,
            chapterID: chapter.id,
            chapter: chapter.title.isEmpty ? chapter.id : chapter.title,
            page: 1
        )
        return true
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
                    status = AppLocalization.format("tracking.sync.status.failed_format", "Tracker sync failed: %@", error.localizedDescription)
                }
            }
            try await reload()
            if pendingEvents.isEmpty {
                status = AppLocalization.text("tracking.sync.status.complete", "Tracker sync complete")
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
