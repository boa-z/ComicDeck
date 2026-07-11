import Foundation
import Observation
import Security
import SwiftUI

@MainActor
@Observable
final class SettingsScreenModel {
    private enum WebDAVPersistKey {
        static let directoryURL = "backup.webdav.directoryURL"
        static let username = "backup.webdav.username"
        static let remoteFileName = "backup.webdav.remoteFileName"
        static let lastSyncAt = "backup.webdav.lastSyncAt"
        static let lastSyncSummary = "backup.webdav.lastSyncSummary"
        static let uploadSnapshots = "backup.webdav.uploadSnapshots"
        static let passwordService = "boa.ComicDeck.WebDAV"
        static let passwordAccount = "backup.webdav.password"
        static let passwordFallback = "backup.webdav.passwordFallback"
    }

    var readerCacheSize = "Calculating..."
    var readerCacheMemory = "Calculating..."
    var readerCacheHitRate = "Calculating..."
    var clearingReaderCache = false
    var sharedLogURL: URL?
    var sharedBackupURL: URL?
    var sharingLog = false
    var sharingBackup = false
    var restoringBackup = false
    var debugShareError: String?
    var backupError: String?
    var backupSuccessMessage: String?
    var backupExportSuccessMessage: String?
    var webDAVDirectoryURL = ""
    var webDAVUsername = ""
    var webDAVPassword = ""
    var webDAVRemoteFileName = "comicdeck-backup-latest.json"
    var webDAVUploadSnapshots = true
    var testingWebDAV = false
    var uploadingWebDAV = false
    var downloadingWebDAV = false
    var deletingWebDAVEntry = false
    var loadingWebDAVEntries = false
    var webDAVStatus = "Not configured"
    var webDAVEntries: [WebDAVRemoteBackup] = []
    var webDAVEntriesLoaded = false
    var webDAVLastSyncAt: Date?
    var webDAVLastSyncSummary = "Never synced"
    var webDAVError: String?
    var webDAVSuccessMessage: String?

    private let webDAVService = WebDAVSyncService()

    init() {
        loadWebDAVConfiguration()
    }

    func loadReaderCacheSize(using library: LibraryViewModel) async {
        readerCacheSize = await library.readerCacheSizeText()
        let metrics = await library.readerCacheMetrics()
        readerCacheMemory = ByteCountFormatter.string(fromByteCount: metrics.memoryBytes, countStyle: .memory)
        readerCacheHitRate = metrics.totalRequests == 0
            ? AppLocalization.text("settings.reader.cache_no_reads", "No reads yet")
            : AppLocalization.format(
                "settings.reader.cache_hit_rate_format",
                "%d%% hit rate",
                Int((metrics.hitRate * 100).rounded())
            )
    }

    func clearReaderCache(using library: LibraryViewModel) async {
        clearingReaderCache = true
        await library.clearReaderCache()
        await loadReaderCacheSize(using: library)
        clearingReaderCache = false
    }

    func prepareDebugLogShare(using console: RuntimeDebugConsole) {
        sharingLog = true
        debugShareError = nil
        do {
            sharedLogURL = try makeDebugLogExport(using: console)
        } catch {
            debugShareError = error.localizedDescription
        }
        sharingLog = false
    }

    func makeDebugLogExport(using console: RuntimeDebugConsole) throws -> URL {
        try console.exportLogSnapshot()
    }

    func prepareBackupShare(using library: LibraryViewModel, tracker: TrackerViewModel) async {
        sharingBackup = true
        backupError = nil
        defer { sharingBackup = false }
        do {
            sharedBackupURL = try await makeBackupExport(using: library, tracker: tracker)
        } catch {
            backupError = error.localizedDescription
        }
    }

    func makeBackupExport(using library: LibraryViewModel, tracker: TrackerViewModel) async throws -> URL {
        let payload = library.createBackupPayload(tracker: tracker)
        return try await Task.detached(priority: .utility) {
            try AppBackupService.writePayload(payload)
        }.value
    }

    func restoreBackup(
        from url: URL,
        using library: LibraryViewModel,
        sourceManager: SourceManagerViewModel,
        tracker: TrackerViewModel
    ) async {
        restoringBackup = true
        backupError = nil
        backupSuccessMessage = nil
        defer { restoringBackup = false }

        do {
            let payload = try await Task.detached(priority: .utility) {
                try AppBackupService.readPayload(from: url)
            }.value
            try await library.restore(from: payload, sourceManager: sourceManager, tracker: tracker)
            backupSuccessMessage = AppLocalization.text("settings.backup.restored_message", "Backup restored. Preferences, library data, and tracker settings have been reloaded.")
        } catch {
            backupError = error.localizedDescription
        }
    }

    func saveWebDAVConfiguration() {
        let defaults = UserDefaults.standard
        defaults.set(webDAVDirectoryURL, forKey: WebDAVPersistKey.directoryURL)
        defaults.set(webDAVUsername, forKey: WebDAVPersistKey.username)
        defaults.set(webDAVRemoteFileName, forKey: WebDAVPersistKey.remoteFileName)
        defaults.set(webDAVUploadSnapshots, forKey: WebDAVPersistKey.uploadSnapshots)
        do {
            try SecureStore.save(webDAVPassword, service: WebDAVPersistKey.passwordService, account: WebDAVPersistKey.passwordAccount)
            defaults.removeObject(forKey: WebDAVPersistKey.passwordFallback)
        } catch {
            if shouldFallbackWebDAVPasswordStorage(for: error) {
                defaults.set(webDAVPassword, forKey: WebDAVPersistKey.passwordFallback)
            } else {
                webDAVError = error.localizedDescription
            }
        }
        if webDAVDirectoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            webDAVEntries = []
            webDAVEntriesLoaded = false
            webDAVLastSyncAt = nil
            webDAVLastSyncSummary = AppLocalization.text("webdav.status.not_configured", "Not configured")
        }
    }

    func testWebDAVConnection() async {
        testingWebDAV = true
        webDAVError = nil
        webDAVSuccessMessage = nil
        defer { testingWebDAV = false }
        do {
            saveWebDAVConfiguration()
            try await webDAVService.testConnection(currentWebDAVConfiguration())
            webDAVStatus = AppLocalization.text("webdav.status.connection_verified", "Connection verified")
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.connection_verified", "Connection verified"))
            webDAVSuccessMessage = AppLocalization.text("webdav.success.connection_verified", "WebDAV connection verified.")
        } catch {
            webDAVStatus = AppLocalization.text("webdav.status.connection_failed", "Connection failed")
            webDAVError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.connection_failed", "Connection failed"))
        }
    }

    func uploadBackupToWebDAV(using library: LibraryViewModel, tracker: TrackerViewModel) async {
        uploadingWebDAV = true
        webDAVError = nil
        webDAVSuccessMessage = nil
        defer { uploadingWebDAV = false }

        do {
            saveWebDAVConfiguration()
            let payload = library.createBackupPayload(tracker: tracker)
            try await webDAVService.uploadBackup(payload, configuration: currentWebDAVConfiguration())
            if webDAVUploadSnapshots {
                _ = try await webDAVService.uploadSnapshotBackup(payload, configuration: currentWebDAVConfiguration())
            }
            webDAVStatus = AppLocalization.text("webdav.status.uploaded", "Uploaded backup to WebDAV")
            webDAVSuccessMessage = webDAVUploadSnapshots
                ? AppLocalization.text("webdav.success.uploaded_with_snapshot", "Latest backup and timestamped snapshot uploaded to WebDAV.")
                : AppLocalization.text("webdav.success.uploaded", "Backup uploaded to WebDAV.")
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.uploaded_summary", "Uploaded backup"))
            await refreshWebDAVEntries()
        } catch {
            webDAVStatus = AppLocalization.text("webdav.status.upload_failed", "Upload failed")
            webDAVError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.upload_failed", "Upload failed"))
        }
    }

    func restoreBackupFromWebDAV(
        using library: LibraryViewModel,
        sourceManager: SourceManagerViewModel,
        tracker: TrackerViewModel
    ) async {
        downloadingWebDAV = true
        webDAVError = nil
        webDAVSuccessMessage = nil
        defer { downloadingWebDAV = false }

        do {
            saveWebDAVConfiguration()
            let payload = try await webDAVService.downloadBackup(configuration: currentWebDAVConfiguration())
            try await library.restore(from: payload, sourceManager: sourceManager, tracker: tracker)
            webDAVStatus = AppLocalization.text("webdav.status.downloaded_restored", "Downloaded and restored backup")
            webDAVSuccessMessage = AppLocalization.text("webdav.success.restored_configured", "Backup downloaded from WebDAV and restored.")
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.restored_from_webdav", "Restored from WebDAV"))
        } catch {
            webDAVStatus = AppLocalization.text("webdav.status.download_failed", "Download failed")
            webDAVError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.restore_failed", "Restore failed"))
        }
    }

    func restoreLatestBackupFromWebDAV(
        using library: LibraryViewModel,
        sourceManager: SourceManagerViewModel,
        tracker: TrackerViewModel
    ) async {
        downloadingWebDAV = true
        webDAVError = nil
        webDAVSuccessMessage = nil
        defer { downloadingWebDAV = false }

        do {
            saveWebDAVConfiguration()
            let payload = try await webDAVService.downloadLatestBackup(configuration: currentWebDAVConfiguration())
            try await library.restore(from: payload, sourceManager: sourceManager, tracker: tracker)
            webDAVStatus = AppLocalization.text("webdav.status.restored_latest", "Restored latest remote backup")
            webDAVSuccessMessage = AppLocalization.text("webdav.success.restored_latest", "Latest WebDAV backup restored.")
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.restored_latest_summary", "Restored latest backup"))
        } catch {
            webDAVStatus = AppLocalization.text("webdav.status.restore_failed", "Restore failed")
            webDAVError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.restore_failed", "Restore failed"))
        }
    }

    func refreshWebDAVEntries() async {
        loadingWebDAVEntries = true
        webDAVError = nil
        defer { loadingWebDAVEntries = false }

        do {
            saveWebDAVConfiguration()
            webDAVEntries = try await webDAVService.listBackups(configuration: currentWebDAVConfiguration())
            webDAVEntriesLoaded = true
            webDAVStatus = webDAVEntries.isEmpty
                ? AppLocalization.text("webdav.status.no_remote_backups", "No remote backups found")
                : AppLocalization.format("webdav.status.loaded_remote_backups_format", "Loaded %d remote backups", webDAVEntries.count)
            updateWebDAVSyncMetadata(summary: webDAVStatus)
        } catch {
            webDAVStatus = AppLocalization.text("webdav.status.remote_listing_failed", "Remote listing failed")
            webDAVError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.remote_listing_failed", "Remote listing failed"))
        }
    }

    func restoreBackupFromWebDAVEntry(
        _ entry: WebDAVRemoteBackup,
        using library: LibraryViewModel,
        sourceManager: SourceManagerViewModel,
        tracker: TrackerViewModel
    ) async {
        downloadingWebDAV = true
        webDAVError = nil
        webDAVSuccessMessage = nil
        defer { downloadingWebDAV = false }

        do {
            saveWebDAVConfiguration()
            let payload = try await webDAVService.downloadBackup(from: entry.url, configuration: currentWebDAVConfiguration())
            try await library.restore(from: payload, sourceManager: sourceManager, tracker: tracker)
            webDAVStatus = AppLocalization.format("webdav.status.restored_entry_format", "Restored %@", entry.name)
            webDAVSuccessMessage = AppLocalization.format("webdav.success.restored_entry_format", "Backup restored from %@.", entry.name)
            updateWebDAVSyncMetadata(summary: webDAVStatus)
        } catch {
            webDAVStatus = AppLocalization.text("webdav.status.restore_failed", "Restore failed")
            webDAVError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.restore_failed", "Restore failed"))
        }
    }

    func deleteWebDAVEntry(_ entry: WebDAVRemoteBackup) async {
        deletingWebDAVEntry = true
        webDAVError = nil
        webDAVSuccessMessage = nil
        defer { deletingWebDAVEntry = false }

        do {
            saveWebDAVConfiguration()
            try await webDAVService.deleteBackup(entry, configuration: currentWebDAVConfiguration())
            webDAVEntries.removeAll { $0.id == entry.id }
            webDAVStatus = AppLocalization.format("webdav.status.deleted_entry_format", "Deleted %@", entry.name)
            updateWebDAVSyncMetadata(summary: webDAVStatus)
            webDAVSuccessMessage = AppLocalization.format("webdav.success.deleted_entry_format", "Deleted %@.", entry.name)
        } catch {
            webDAVStatus = AppLocalization.text("webdav.status.delete_failed", "Delete failed")
            webDAVError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: AppLocalization.text("webdav.status.delete_failed", "Delete failed"))
        }
    }

    private func loadWebDAVConfiguration() {
        let defaults = UserDefaults.standard
        webDAVDirectoryURL = defaults.string(forKey: WebDAVPersistKey.directoryURL) ?? ""
        webDAVUsername = defaults.string(forKey: WebDAVPersistKey.username) ?? ""
        webDAVRemoteFileName = defaults.string(forKey: WebDAVPersistKey.remoteFileName) ?? "comicdeck-backup-latest.json"
        webDAVUploadSnapshots = defaults.object(forKey: WebDAVPersistKey.uploadSnapshots) as? Bool ?? true
        webDAVPassword = (
            (try? SecureStore.read(service: WebDAVPersistKey.passwordService, account: WebDAVPersistKey.passwordAccount))
            ?? defaults.string(forKey: WebDAVPersistKey.passwordFallback)
            ?? ""
        )
        webDAVLastSyncAt = defaults.object(forKey: WebDAVPersistKey.lastSyncAt) as? Date
        webDAVLastSyncSummary = defaults.string(forKey: WebDAVPersistKey.lastSyncSummary)
            ?? AppLocalization.text("webdav.status.never_synced", "Never synced")
        webDAVStatus = webDAVDirectoryURL.isEmpty
            ? AppLocalization.text("webdav.status.not_configured", "Not configured")
            : AppLocalization.text("webdav.status.ready", "Ready")
    }

    private func currentWebDAVConfiguration() -> WebDAVSyncConfiguration {
        WebDAVSyncConfiguration(
            directoryURLString: webDAVDirectoryURL,
            username: webDAVUsername,
            password: webDAVPassword,
            remoteFileName: webDAVRemoteFileName
        )
    }

    private func updateWebDAVSyncMetadata(summary: String) {
        webDAVLastSyncAt = Date()
        webDAVLastSyncSummary = summary
        let defaults = UserDefaults.standard
        defaults.set(webDAVLastSyncAt, forKey: WebDAVPersistKey.lastSyncAt)
        defaults.set(summary, forKey: WebDAVPersistKey.lastSyncSummary)
    }

    var webDAVActionsDisabled: Bool {
        testingWebDAV || uploadingWebDAV || downloadingWebDAV || loadingWebDAVEntries || deletingWebDAVEntry
    }

    private func shouldFallbackWebDAVPasswordStorage(for error: Error) -> Bool {
        guard case let SecureStoreError.saveFailed(status) = error else {
            return false
        }
        return status == errSecMissingEntitlement
    }
}
