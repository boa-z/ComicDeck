import Foundation

actor OfflineLibraryIndexer {
    private let database: SQLiteStore
    private let rootDirectory: URL
    private let fileManager = FileManager.default
    private let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif"]

    init(database: SQLiteStore, rootDirectory: URL) {
        self.database = database
        self.rootDirectory = rootDirectory
    }

    func reindex() async throws {
        var indexedItems: [OfflineChapterAsset] = []

        guard let sourceDirs = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            try await database.replaceOfflineChapters(with: [])
            return
        }

        for sourceDir in sourceDirs {
            guard try sourceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            guard let comicDirs = try? fileManager.contentsOfDirectory(
                at: sourceDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for comicDir in comicDirs {
                guard try comicDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                guard let chapterDirs = try? fileManager.contentsOfDirectory(
                    at: comicDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }

                for chapterDir in chapterDirs {
                    guard try chapterDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                    if let asset = try makeOfflineAsset(at: chapterDir) {
                        indexedItems.append(asset)
                    }
                }
            }
        }

        try await database.replaceOfflineChapters(with: indexedItems)
    }

    private func makeOfflineAsset(at directory: URL) throws -> OfflineChapterAsset? {
        guard let metadata = try loadMetadata(at: directory) else { return nil }
        let imageCount = try countImageFiles(in: directory)
        let integrityStatus: OfflineChapterIntegrityStatus = imageCount >= metadata.totalPages && metadata.totalPages > 0
            ? .complete
            : .incomplete
        let verifiedAt = Int64(Date().timeIntervalSince1970)

        return OfflineChapterAsset(
            id: 0,
            sourceKey: metadata.sourceKey,
            comicID: metadata.comicID,
            comicTitle: metadata.comicTitle,
            coverURL: metadata.coverURL,
            comicDescription: metadata.comicDescription,
            chapterID: metadata.chapterID,
            chapterTitle: metadata.chapterTitle,
            pageCount: metadata.totalPages,
            verifiedPageCount: imageCount,
            integrityStatus: integrityStatus,
            directoryPath: directory.path,
            downloadedAt: metadata.downloadedAt,
            lastVerifiedAt: verifiedAt,
            updatedAt: verifiedAt
        )
    }

    private func loadMetadata(at directory: URL) throws -> Metadata? {
        let fileURL = directory.appendingPathComponent("metadata.json")
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Metadata.self, from: data)
    }

    private func countImageFiles(in directory: URL) throws -> Int {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return entries.lazy.filter { url in
            guard url.lastPathComponent != "metadata.json" else { return false }
            return self.supportedImageExtensions.contains(url.pathExtension.lowercased())
        }.count
    }

    private struct Metadata: Decodable {
        let sourceKey: String
        let comicID: String
        let comicTitle: String
        let coverURL: String?
        let comicDescription: String?
        let chapterID: String
        let chapterTitle: String
        let totalPages: Int
        let downloadedAt: Int64
    }
}
