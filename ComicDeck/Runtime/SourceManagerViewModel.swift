import Foundation
import Observation

private enum SMVMLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
private func smDebugLog(_ message: String, level: SMVMLogLevel = .debug) {
    guard RuntimeDebugConsole.isEnabled else { return }
    let line = "[SourceRuntime][\(level.rawValue)][SourceMgr] \(message)"
    NSLog("%@", line)
    RuntimeDebugConsole.shared.append(line)
}

/// Manages source installation, uninstallation, updates, and the remote source index.
/// Intended to be used as an @EnvironmentObject in SwiftUI.
@MainActor
@Observable
final class SourceManagerViewModel {
    private enum PersistKey {
        static let indexURL = "source.runtime.index.url"
        static let selectedSourceKey = "source.runtime.selected.source.key"
        static let autoLoadRemoteSources = "source.runtime.remote.autoload"
        static let lastRemoteRefreshTimestamp = "source.runtime.remote.lastRefreshTimestamp"
    }

    private static let defaultIndexURL = "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json"

    var indexURL = "" {
        didSet {
            guard oldValue != indexURL else { return }
            UserDefaults.standard.set(indexURL, forKey: PersistKey.indexURL)
        }
    }
    var remoteSources: [SourceConfigIndexItem] = []
    var installedSources: [InstalledSource] = []
    var availableSourceUpdates: [String: String] = [:]
    var refreshingIndex = false
    var updatingAll = false
    var operatingSourceKeys: Set<String> = []
    var autoLoadRemoteSources = false {
        didSet {
            guard oldValue != autoLoadRemoteSources else { return }
            UserDefaults.standard.set(autoLoadRemoteSources, forKey: PersistKey.autoLoadRemoteSources)
        }
    }
    var selectedSourceKey = "" {
        didSet {
            guard oldValue != selectedSourceKey else { return }
            UserDefaults.standard.set(selectedSourceKey, forKey: PersistKey.selectedSourceKey)
            onSelectedSourceChanged?(selectedSourceKey)
        }
    }
    var status = "Ready"
    var lastRemoteRefreshAt: Date? {
        didSet {
            let defaults = UserDefaults.standard
            if let lastRemoteRefreshAt {
                defaults.set(lastRemoteRefreshAt.timeIntervalSince1970, forKey: PersistKey.lastRemoteRefreshTimestamp)
            } else {
                defaults.removeObject(forKey: PersistKey.lastRemoteRefreshTimestamp)
            }
        }
    }

    var lastRemoteRefreshDescription: String {
        guard let lastRemoteRefreshAt else { return "Never refreshed" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last refreshed \(formatter.localizedString(for: lastRemoteRefreshAt, relativeTo: Date()))"
    }

    var selectedSource: InstalledSource? {
        installedSources.first { $0.key == selectedSourceKey }
    }

    /// Called whenever selectedSourceKey changes. ReaderViewModel wires this up.
    var onSelectedSourceChanged: ((String) -> Void)?

    private let sourceRepository = ComicSourceRepository()
    private let configService = SourceConfigService()
    private(set) var sourceStore: SourceStore?
    private(set) var sourceEngines: [String: ComicSourceScriptEngine] = [:]

    // MARK: - Init

    func prepare(sourceStore: SourceStore) async throws {
        self.sourceStore = sourceStore
        if indexURL.isEmpty {
            indexURL = UserDefaults.standard.string(forKey: PersistKey.indexURL) ?? Self.defaultIndexURL
        }
        autoLoadRemoteSources = UserDefaults.standard.object(forKey: PersistKey.autoLoadRemoteSources) as? Bool ?? false
        if let timestamp = UserDefaults.standard.object(forKey: PersistKey.lastRemoteRefreshTimestamp) as? TimeInterval {
            lastRemoteRefreshAt = Date(timeIntervalSince1970: timestamp)
        } else {
            lastRemoteRefreshAt = nil
        }
        let persistedSelectedKey = UserDefaults.standard.string(forKey: PersistKey.selectedSourceKey) ?? ""
        try await reloadInstalledSources()
        if !persistedSelectedKey.isEmpty,
           installedSources.contains(where: { $0.key == persistedSelectedKey }),
           selectedSourceKey != persistedSelectedKey {
            selectedSourceKey = persistedSelectedKey
        }
        // Ensure listeners (login/search state) are refreshed after sources are loaded.
        onSelectedSourceChanged?(selectedSourceKey)
        if autoLoadRemoteSources {
            await refreshRemoteSources()
        } else {
            remoteSources = []
            availableSourceUpdates = [:]
            status = "Repository auto-load is off. Tap Load Sources to fetch the index."
        }
    }

    // MARK: - Remote Index

    func refreshRemoteSources() async {
        refreshingIndex = true
        defer { refreshingIndex = false }
        guard !indexURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            remoteSources = []
            availableSourceUpdates = [:]
            status = "Please input source index URL"
            return
        }
        do {
            let list = try await configService.fetchIndex(from: indexURL)
            remoteSources = list
            recalculateSourceUpdates()
            lastRemoteRefreshAt = Date()
            smDebugLog("refreshRemoteSources ok: count=\(list.count)", level: .info)
            status = "Loaded source index: \(list.count) items"
        } catch {
            availableSourceUpdates = [:]
            smDebugLog("refreshRemoteSources failed: \(error.localizedDescription)", level: .error)
            status = "Index refresh failed: \(error.localizedDescription)"
        }
    }

    func resetIndexURLToOfficial() {
        indexURL = Self.defaultIndexURL
    }

    // MARK: - Install / Uninstall / Update

    func installFromIndex(_ item: SourceConfigIndexItem) async {
        guard let sourceStore else {
            status = "Store not initialized"
            return
        }
        let sourceKey = inferredKey(for: item)
        operatingSourceKeys.insert(sourceKey)
        defer { operatingSourceKeys.remove(sourceKey) }

        guard let resolvedURL = await configService.resolveScriptURL(indexURL: indexURL, item: item) else {
            status = "Cannot resolve script URL"
            return
        }

        do {
            let script = try await configService.downloadScript(from: resolvedURL)
            smDebugLog("installFromIndex downloading: url=\(resolvedURL), name=\(item.name)")

            let metadata = sourceRepository.parseSourceMetadata(script: script)
                ?? SourceScriptMetadata(
                    className: item.name,
                    name: item.name,
                    key: item.key ?? item.name.lowercased().replacingOccurrences(of: " ", with: "_"),
                    version: item.version ?? "0.0.0",
                    url: resolvedURL
                )

            _ = try await sourceStore.install(script: script, metadata: metadata, sourceURL: resolvedURL)
            invalidateEngine(for: metadata.key)
            smDebugLog("installFromIndex ok: key=\(metadata.key), version=\(metadata.version)", level: .info)
            try await reloadInstalledSources()
            if selectedSourceKey.isEmpty {
                selectedSourceKey = metadata.key
            }
            status = "Installed source: \(metadata.name)"
        } catch {
            smDebugLog("installFromIndex failed: \(error.localizedDescription)", level: .error)
            status = "Install failed: \(error.localizedDescription)"
        }
    }

    func uninstallSource(_ source: InstalledSource) async {
        guard let sourceStore else {
            status = "Store not initialized"
            return
        }
        operatingSourceKeys.insert(source.key)
        defer { operatingSourceKeys.remove(source.key) }
        do {
            try await sourceStore.uninstall(key: source.key)
            invalidateEngine(for: source.key)
            if selectedSourceKey == source.key {
                selectedSourceKey = ""
            }
            try await reloadInstalledSources()
            status = "Removed source: \(source.name)"
        } catch {
            status = "Remove failed: \(error.localizedDescription)"
        }
    }

    func updateSource(_ source: InstalledSource) async {
        guard let item = findRemoteSourceItem(for: source) else {
            status = "Cannot find update config for \(source.name)"
            return
        }
        operatingSourceKeys.insert(source.key)
        defer { operatingSourceKeys.remove(source.key) }
        await installFromIndex(item)
    }

    func updateAllSources() async {
        updatingAll = true
        defer { updatingAll = false }
        let sources = installedSources.filter { availableSourceUpdates[$0.key] != nil }
        guard !sources.isEmpty else {
            status = "No updates available"
            return
        }
        var updated = 0
        for source in sources {
            let before = installedSources.first(where: { $0.key == source.key })?.version
            await updateSource(source)
            let after = installedSources.first(where: { $0.key == source.key })?.version
            if before != after { updated += 1 }
        }
        status = "Updated \(updated)/\(sources.count) sources"
    }

    func checkSourceUpdates() {
        recalculateSourceUpdates()
        let count = availableSourceUpdates.count
        status = count == 0 ? "No updates available" : "Updates available: \(count)"
    }

    func isOperating(on key: String) -> Bool {
        operatingSourceKeys.contains(key)
    }

    func resolvedKey(for item: SourceConfigIndexItem) -> String {
        inferredKey(for: item)
    }

    func installedSource(for key: String) -> InstalledSource? {
        installedSources.first(where: { $0.key == key })
    }

    func selectSource(_ source: InstalledSource) {
        selectedSourceKey = source.key
        smDebugLog("selectSource: key=\(source.key)", level: .info)
        status = "Selected source: \(source.name)"
    }

    // MARK: - Engine Access

    func getOrCreateEngine(sourceKey: String, script: String) throws -> ComicSourceScriptEngine {
        if let existing = sourceEngines[sourceKey] {
            existing.setStorageKey(sourceKey)
            return existing
        }
        let engine = try sourceRepository.createSourceEngine(script: script)
        engine.setStorageKey(sourceKey)
        sourceEngines[sourceKey] = engine
        smDebugLog("engine created: key=\(sourceKey)", level: .info)
        return engine
    }

    func getOrCreateEngineAsync(sourceKey: String, script: String, runEngine: @escaping (@escaping () throws -> ComicSourceScriptEngine) async throws -> ComicSourceScriptEngine) async throws -> ComicSourceScriptEngine {
        if let existing = sourceEngines[sourceKey] {
            existing.setStorageKey(sourceKey)
            return existing
        }
        let repo = sourceRepository
        let engine = try await runEngine {
            try repo.createSourceEngine(script: script)
        }
        engine.setStorageKey(sourceKey)
        sourceEngines[sourceKey] = engine
        return engine
    }

    func getOrCreateEngine(for source: InstalledSource, runEngine: @escaping (@escaping () throws -> ComicSourceScriptEngine) async throws -> ComicSourceScriptEngine) async throws -> ComicSourceScriptEngine {
        if let existing = sourceEngines[source.key] {
            existing.setStorageKey(source.key)
            return existing
        }
        guard let sourceStore else {
            throw ScriptEngineError.invalidResult("source store not initialized")
        }
        let script = try await sourceStore.readScript(fileName: source.scriptFileName)
        return try await getOrCreateEngineAsync(sourceKey: source.key, script: script, runEngine: runEngine)
    }

    func invalidateEngine(for key: String) {
        sourceEngines[key] = nil
    }

    // MARK: - Private Helpers

    func reloadInstalledSources() async throws {
        guard let sourceStore else { return }
        let list = try await sourceStore.listInstalled()
        installedSources = list
        recalculateSourceUpdates()
        if selectedSourceKey.isEmpty, let first = list.first {
            selectedSourceKey = first.key
        } else if !selectedSourceKey.isEmpty, !list.contains(where: { $0.key == selectedSourceKey }) {
            selectedSourceKey = list.first?.key ?? ""
        }
    }

    private func recalculateSourceUpdates() {
        guard !remoteSources.isEmpty, !installedSources.isEmpty else {
            availableSourceUpdates = [:]
            return
        }
        var remoteByKey: [String: SourceConfigIndexItem] = [:]
        for item in remoteSources {
            remoteByKey[inferredKey(for: item)] = item
        }
        var updates: [String: String] = [:]
        for source in installedSources {
            guard let remote = remoteByKey[source.key] else { continue }
            guard let remoteVersion = remote.version?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !remoteVersion.isEmpty
            else { continue }
            if isVersion(remoteVersion, newerThan: source.version) {
                updates[source.key] = remoteVersion
            }
        }
        availableSourceUpdates = updates
    }

    private func findRemoteSourceItem(for source: InstalledSource) -> SourceConfigIndexItem? {
        if let direct = remoteSources.first(where: { inferredKey(for: $0) == source.key }) {
            return direct
        }
        return remoteSources.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(source.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
    }

    private func inferredKey(for item: SourceConfigIndexItem) -> String {
        if let key = item.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        return item.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(left.count, right.count)
        for idx in 0..<count {
            let l = idx < left.count ? left[idx] : 0
            let r = idx < right.count ? right[idx] : 0
            if l != r { return l > r }
        }
        return false
    }
}
