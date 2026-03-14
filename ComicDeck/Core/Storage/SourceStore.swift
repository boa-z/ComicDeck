import Foundation

actor SourceStore {
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let scriptsDirectory: URL
    private let installedListFile: URL

    /// In-memory cache — avoids reading installed_sources.json on every operation.
    private var cachedSources: [InstalledSource]?

    init(baseDirectory: URL) throws {
        self.baseDirectory = baseDirectory
        self.scriptsDirectory = baseDirectory.appendingPathComponent("sources", isDirectory: true)
        self.installedListFile = baseDirectory.appendingPathComponent("installed_sources.json")

        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
    }

    func listInstalled() throws -> [InstalledSource] {
        if let cached = cachedSources {
            return cached
        }
        let fresh = try loadFromDisk()
        cachedSources = fresh
        return fresh
    }

    func readScript(fileName: String) throws -> String {
        let fileURL = scriptsDirectory.appendingPathComponent(fileName)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func install(
        script: String,
        metadata: SourceScriptMetadata,
        sourceURL: String
    ) throws -> InstalledSource {
        var installed = try listInstalled()
        let safeName = sanitizeFileName("\(metadata.key).js")
        let scriptFileURL = scriptsDirectory.appendingPathComponent(safeName)

        try script.write(to: scriptFileURL, atomically: true, encoding: .utf8)

        let source = InstalledSource(
            id: metadata.key,
            name: metadata.name,
            key: metadata.key,
            version: metadata.version,
            scriptFileName: safeName,
            originalURL: sourceURL,
            installedAt: Int64(Date().timeIntervalSince1970)
        )

        installed.removeAll { $0.key == source.key }
        installed.insert(source, at: 0)

        try persist(installed)
        cachedSources = installed
        return source
    }

    func uninstall(key: String) throws {
        let installed = try listInstalled()
        guard let target = installed.first(where: { $0.key == key }) else {
            return
        }

        let fileURL = scriptsDirectory.appendingPathComponent(target.scriptFileName)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }

        let remaining = installed.filter { $0.key != key }
        try persist(remaining)
        cachedSources = remaining
    }

    // MARK: - Private Helpers

    private func loadFromDisk() throws -> [InstalledSource] {
        guard fileManager.fileExists(atPath: installedListFile.path) else {
            return []
        }
        let data = try Data(contentsOf: installedListFile)
        let decoded = try JSONDecoder().decode([InstalledSource].self, from: data)
        var seenKeys = Set<String>()
        var normalized: [InstalledSource] = []
        var changed = false

        for item in decoded {
            if seenKeys.contains(item.key) {
                changed = true
                continue
            }
            seenKeys.insert(item.key)

            let fileURL = scriptsDirectory.appendingPathComponent(item.scriptFileName)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                changed = true
                continue
            }
            normalized.append(item)
        }

        if changed {
            try persist(normalized)
        }

        return normalized
    }

    private func persist(_ sources: [InstalledSource]) throws {
        let data = try JSONEncoder().encode(sources)
        try data.write(to: installedListFile, options: .atomic)
    }

    private func sanitizeFileName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "<>:\"/\\|?*\n\r\t")
        return value.components(separatedBy: invalid).joined(separator: "_")
    }
}
