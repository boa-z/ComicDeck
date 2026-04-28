import Foundation

enum ReaderLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
nonisolated func readerDebugLog(_ message: String, level: ReaderLogLevel = .debug) {
    let line = "[SourceRuntime][\(level.rawValue)][Reader] \(message)"
    RuntimeDebugConsole.appendRuntimeLine(line)
}
