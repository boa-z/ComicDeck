import Foundation

public final class CoreBootstrap {
    public let baseDirectory: URL
    public let database: SQLiteStore
    public let downloader: DownloadService

    public init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        let dbURL = baseDirectory
            .appendingPathComponent("database", isDirectory: true)
            .appendingPathComponent("source_runtime.sqlite3")

        self.database = try SQLiteStore(databaseURL: dbURL)
        self.downloader = DownloadService()
    }
}
