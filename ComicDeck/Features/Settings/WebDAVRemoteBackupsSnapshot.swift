import Foundation

struct WebDAVRemoteBackupsSnapshot {
    enum EmptyState {
        case notConfigured
        case loading
        case notLoaded
        case noBackups

        var title: String {
            switch self {
            case .notConfigured:
                return AppLocalization.text("webdav.remote.not_configured.title", "WebDAV is not configured")
            case .loading:
                return AppLocalization.text("webdav.remote.loading.title", "Loading remote backups...")
            case .notLoaded:
                return AppLocalization.text("webdav.remote.not_loaded.title", "Remote backups not loaded")
            case .noBackups:
                return AppLocalization.text("webdav.remote.no_backups.title", "No remote backups found")
            }
        }

        var message: String {
            switch self {
            case .notConfigured:
                return AppLocalization.text("webdav.remote.not_configured.message", "Save a WebDAV directory before loading remote backups.")
            case .loading:
                return AppLocalization.text("webdav.remote.loading.message", "ComicDeck is checking the configured WebDAV directory.")
            case .notLoaded:
                return AppLocalization.text("webdav.remote.not_loaded.message", "Refresh remote backups to list JSON backup files from the configured directory.")
            case .noBackups:
                return AppLocalization.text("webdav.remote.no_backups.message", "The configured WebDAV directory does not contain any JSON backup files.")
            }
        }
    }

    struct Row: Identifiable {
        let entry: WebDAVRemoteBackup
        let subtitle: String

        var id: URL { entry.id }
    }

    let rows: [Row]
    let emptyState: EmptyState?

    init(model: SettingsScreenModel) {
        let isConfigured = !model.webDAVDirectoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        rows = model.webDAVEntries.map { entry in
            Row(entry: entry, subtitle: Self.subtitle(for: entry))
        }

        if !rows.isEmpty {
            emptyState = nil
        } else if !isConfigured {
            emptyState = .notConfigured
        } else if model.loadingWebDAVEntries {
            emptyState = .loading
        } else if !model.webDAVEntriesLoaded {
            emptyState = .notLoaded
        } else {
            emptyState = .noBackups
        }
    }

    private static func subtitle(for entry: WebDAVRemoteBackup) -> String {
        var parts: [String] = []
        if let modifiedAt = entry.modifiedAt {
            parts.append(modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        if let sizeBytes = entry.sizeBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
        }
        return parts.isEmpty
            ? AppLocalization.text("webdav.remote.unknown_metadata", "Unknown metadata")
            : parts.joined(separator: " · ")
    }
}
