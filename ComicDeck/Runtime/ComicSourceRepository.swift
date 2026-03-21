import Foundation

struct ComicSourceDefinition: Codable, Sendable, Hashable {
    public let key: String
    public let name: String
    public let script: String
    public let searchFunction: String

    public init(
        key: String,
        name: String,
        script: String,
        searchFunction: String = "search"
    ) {
        self.key = key
        self.name = name
        self.script = script
        self.searchFunction = searchFunction
    }
}

enum ComicSourceRepositoryError: Error, LocalizedError {
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "Invalid source payload."
        }
    }
}

nonisolated final class ComicSourceRepository {
    public init() {}

    public func loadSource(fromFileURL url: URL) throws -> ComicSourceDefinition {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ComicSourceDefinition.self, from: data)
    }

    public func loadSource(fromJSONString string: String) throws -> ComicSourceDefinition {
        guard let data = string.data(using: .utf8) else {
            throw ComicSourceRepositoryError.invalidPayload
        }
        return try JSONDecoder().decode(ComicSourceDefinition.self, from: data)
    }

    public func search(source: ComicSourceDefinition, keyword: String) throws -> [ComicSummary] {
        let engine = try ComicSourceScriptEngine(script: source.script)
        return try engine.search(keyword: keyword, functionName: source.searchFunction)
    }

    // MARK: - Script Metadata (delegates to SourceScriptParser — no engine instantiation needed)

    public func parseSourceMetadata(script: String) -> SourceScriptMetadata? {
        SourceScriptParser.extractMetadata(from: script)
    }

    public func parseSourceLoginURL(script: String) -> String? {
        SourceScriptParser.extractLoginWebviewURL(from: script)
    }

    // MARK: - Engine Creation

    public func createSourceEngine(script: String) throws -> ComicSourceScriptEngine {
        try ComicSourceScriptEngine.fromSourceScript(script)
    }

    public func searchFromSourceScript(script: String, keyword: String, sourceKey: String) throws -> [ComicSummary] {
        let engine = try ComicSourceScriptEngine.fromSourceScript(script)
        return try engine.searchSource(keyword: keyword, sourceKey: sourceKey)
    }
}
