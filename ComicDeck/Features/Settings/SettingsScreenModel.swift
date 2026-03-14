import Foundation
import Observation
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
    var webDAVLastSyncAt: Date?
    var webDAVLastSyncSummary = "Never synced"

    private let webDAVService = WebDAVSyncService()

    init() {
        loadWebDAVConfiguration()
    }

    func loadReaderCacheSize(using library: LibraryViewModel) async {
        readerCacheSize = await library.readerCacheSizeText()
        let metrics = await library.readerCacheMetrics()
        readerCacheMemory = ByteCountFormatter.string(fromByteCount: metrics.memoryBytes, countStyle: .memory)
        readerCacheHitRate = metrics.totalRequests == 0
            ? "No reads yet"
            : "\(Int((metrics.hitRate * 100).rounded()))% hit rate"
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
            sharedLogURL = try console.exportLogSnapshot()
        } catch {
            debugShareError = error.localizedDescription
        }
        sharingLog = false
    }

    func prepareBackupShare(using library: LibraryViewModel) {
        sharingBackup = true
        backupError = nil
        do {
            let payload = library.createBackupPayload()
            sharedBackupURL = try AppBackupService.writePayload(payload)
        } catch {
            backupError = error.localizedDescription
        }
        sharingBackup = false
    }

    func restoreBackup(
        from url: URL,
        using library: LibraryViewModel,
        sourceManager: SourceManagerViewModel
    ) async {
        restoringBackup = true
        backupError = nil
        backupSuccessMessage = nil
        defer { restoringBackup = false }

        do {
            let payload = try AppBackupService.readPayload(from: url)
            try await library.restore(from: payload, sourceManager: sourceManager)
            backupSuccessMessage = "Backup restored. Preferences and library data have been reloaded."
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
        } catch {
            backupError = error.localizedDescription
        }
        if webDAVDirectoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            webDAVEntries = []
            webDAVLastSyncAt = nil
            webDAVLastSyncSummary = "Not configured"
        }
    }

    func testWebDAVConnection() async {
        testingWebDAV = true
        backupError = nil
        defer { testingWebDAV = false }
        do {
            saveWebDAVConfiguration()
            try await webDAVService.testConnection(currentWebDAVConfiguration())
            webDAVStatus = "Connection verified"
            updateWebDAVSyncMetadata(summary: "Connection verified")
        } catch {
            webDAVStatus = "Connection failed"
            backupError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: "Connection failed")
        }
    }

    func uploadBackupToWebDAV(using library: LibraryViewModel) async {
        uploadingWebDAV = true
        backupError = nil
        backupSuccessMessage = nil
        defer { uploadingWebDAV = false }

        do {
            saveWebDAVConfiguration()
            let payload = library.createBackupPayload()
            try await webDAVService.uploadBackup(payload, configuration: currentWebDAVConfiguration())
            if webDAVUploadSnapshots {
                _ = try await webDAVService.uploadSnapshotBackup(payload, configuration: currentWebDAVConfiguration())
            }
            webDAVStatus = "Uploaded backup to WebDAV"
            backupSuccessMessage = webDAVUploadSnapshots
                ? "Latest backup and timestamped snapshot uploaded to WebDAV."
                : "Backup uploaded to WebDAV."
            updateWebDAVSyncMetadata(summary: "Uploaded backup")
            await refreshWebDAVEntries()
        } catch {
            webDAVStatus = "Upload failed"
            backupError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: "Upload failed")
        }
    }

    func restoreBackupFromWebDAV(
        using library: LibraryViewModel,
        sourceManager: SourceManagerViewModel
    ) async {
        downloadingWebDAV = true
        backupError = nil
        backupSuccessMessage = nil
        defer { downloadingWebDAV = false }

        do {
            saveWebDAVConfiguration()
            let payload = try await webDAVService.downloadBackup(configuration: currentWebDAVConfiguration())
            try await library.restore(from: payload, sourceManager: sourceManager)
            webDAVStatus = "Downloaded and restored backup"
            backupSuccessMessage = "Backup downloaded from WebDAV and restored."
            updateWebDAVSyncMetadata(summary: "Restored from WebDAV")
        } catch {
            webDAVStatus = "Download failed"
            backupError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: "Restore failed")
        }
    }

    func restoreLatestBackupFromWebDAV(
        using library: LibraryViewModel,
        sourceManager: SourceManagerViewModel
    ) async {
        downloadingWebDAV = true
        backupError = nil
        backupSuccessMessage = nil
        defer { downloadingWebDAV = false }

        do {
            saveWebDAVConfiguration()
            let payload = try await webDAVService.downloadLatestBackup(configuration: currentWebDAVConfiguration())
            try await library.restore(from: payload, sourceManager: sourceManager)
            webDAVStatus = "Restored latest remote backup"
            backupSuccessMessage = "Latest WebDAV backup restored."
            updateWebDAVSyncMetadata(summary: "Restored latest backup")
        } catch {
            webDAVStatus = "Restore failed"
            backupError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: "Restore failed")
        }
    }

    func refreshWebDAVEntries() async {
        loadingWebDAVEntries = true
        backupError = nil
        defer { loadingWebDAVEntries = false }

        do {
            saveWebDAVConfiguration()
            webDAVEntries = try await webDAVService.listBackups(configuration: currentWebDAVConfiguration())
            webDAVStatus = webDAVEntries.isEmpty ? "No remote backups found" : "Loaded \(webDAVEntries.count) remote backups"
            updateWebDAVSyncMetadata(summary: webDAVStatus)
        } catch {
            webDAVStatus = "Remote listing failed"
            backupError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: "Remote listing failed")
        }
    }

    func restoreBackupFromWebDAVEntry(
        _ entry: WebDAVRemoteBackup,
        using library: LibraryViewModel,
        sourceManager: SourceManagerViewModel
    ) async {
        downloadingWebDAV = true
        backupError = nil
        backupSuccessMessage = nil
        defer { downloadingWebDAV = false }

        do {
            saveWebDAVConfiguration()
            let payload = try await webDAVService.downloadBackup(from: entry.url, configuration: currentWebDAVConfiguration())
            try await library.restore(from: payload, sourceManager: sourceManager)
            webDAVStatus = "Restored \(entry.name)"
            backupSuccessMessage = "Backup restored from \(entry.name)."
            updateWebDAVSyncMetadata(summary: "Restored \(entry.name)")
        } catch {
            webDAVStatus = "Restore failed"
            backupError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: "Restore failed")
        }
    }

    func deleteWebDAVEntry(_ entry: WebDAVRemoteBackup) async {
        deletingWebDAVEntry = true
        backupError = nil
        defer { deletingWebDAVEntry = false }

        do {
            saveWebDAVConfiguration()
            try await webDAVService.deleteBackup(entry, configuration: currentWebDAVConfiguration())
            webDAVEntries.removeAll { $0.id == entry.id }
            webDAVStatus = "Deleted \(entry.name)"
            updateWebDAVSyncMetadata(summary: "Deleted \(entry.name)")
        } catch {
            webDAVStatus = "Delete failed"
            backupError = error.localizedDescription
            updateWebDAVSyncMetadata(summary: "Delete failed")
        }
    }

    private func loadWebDAVConfiguration() {
        let defaults = UserDefaults.standard
        webDAVDirectoryURL = defaults.string(forKey: WebDAVPersistKey.directoryURL) ?? ""
        webDAVUsername = defaults.string(forKey: WebDAVPersistKey.username) ?? ""
        webDAVRemoteFileName = defaults.string(forKey: WebDAVPersistKey.remoteFileName) ?? "comicdeck-backup-latest.json"
        webDAVUploadSnapshots = defaults.object(forKey: WebDAVPersistKey.uploadSnapshots) as? Bool ?? true
        webDAVPassword = (try? SecureStore.read(service: WebDAVPersistKey.passwordService, account: WebDAVPersistKey.passwordAccount)) ?? ""
        webDAVLastSyncAt = defaults.object(forKey: WebDAVPersistKey.lastSyncAt) as? Date
        webDAVLastSyncSummary = defaults.string(forKey: WebDAVPersistKey.lastSyncSummary) ?? "Never synced"
        webDAVStatus = webDAVDirectoryURL.isEmpty ? "Not configured" : "Ready"
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
}
