import Foundation

enum ReaderLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

@inline(__always)
nonisolated func readerDebugLog(_ message: @autoclosure () -> String, level: ReaderLogLevel = .debug) {
    guard RuntimeDebugConsole.isEnabled else { return }
    let line = "[SourceRuntime][\(level.rawValue)][Reader] \(message())"
    RuntimeDebugConsole.appendRuntimeLine(line)
}
