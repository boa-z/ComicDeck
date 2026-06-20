import Foundation
import Observation

@Observable
final class RuntimeDebugConsole {
    nonisolated static let enabledKey = "runtime.debug.enabled"
    
    @MainActor
    static let shared = RuntimeDebugConsole()

    private(set) var lines: [String] = []
    private(set) var lastWriteError: String?

    private let maxLines = 300
    @ObservationIgnored
    private let writeQueue = DispatchQueue(label: "boa.ComicDeck.RuntimeDebugConsole.write")
    @ObservationIgnored
    private let formatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
    @ObservationIgnored
    private var bufferedLines: [String] = []
    @ObservationIgnored
    nonisolated private var logsDirectoryURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("DebugLogs", isDirectory: true)
    }
    @ObservationIgnored
    nonisolated private var activeLogFileURL: URL {
        logsDirectoryURL.appendingPathComponent("runtime-debug.log", isDirectory: false)
    }

    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    @inline(__always)
    nonisolated static func appendRuntimeLine(_ line: String) {
        guard isEnabled else { return }
        NSLog("%@", line)
        Task { @MainActor in
            shared.append(line)
        }
    }

    func append(_ message: String) {
        guard Self.isEnabled else { return }
        bufferedLines.append(message)
        if bufferedLines.count > maxLines {
            bufferedLines.removeFirst(bufferedLines.count - maxLines)
        }
        lines = bufferedLines
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        writeQueue.async { [weak self] in
            self?.appendToFileSync(line)
        }
    }

    func clear() {
        bufferedLines.removeAll(keepingCapacity: true)
        lines.removeAll(keepingCapacity: true)
        lastWriteError = nil
        writeQueue.async { [weak self] in
            self?.truncateLogFileSync()
        }
    }

    func activeLogDescription() -> String {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: activeLogFileURL.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size <= 0 { return "Empty" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func activeLogFileExists() -> Bool {
        FileManager.default.fileExists(atPath: activeLogFileURL.path)
    }

    func exportLogSnapshot() throws -> URL {
        try ensureLogsDirectory()
        let exportURL = logsDirectoryURL.appendingPathComponent(
            "runtime-debug-\(Self.exportTimestamp()).log",
            isDirectory: false
        )
        if FileManager.default.fileExists(atPath: exportURL.path) {
            try FileManager.default.removeItem(at: exportURL)
        }

        if FileManager.default.fileExists(atPath: activeLogFileURL.path) {
            try FileManager.default.copyItem(at: activeLogFileURL, to: exportURL)
        } else {
            try Data().write(to: exportURL, options: .atomic)
        }
        return exportURL
    }

    private func appendToFileSync(_ line: String) {
        do {
            try ensureLogsDirectory()
            let data = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: activeLogFileURL.path) {
                let handle = try FileHandle(forWritingTo: activeLogFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: activeLogFileURL, options: .atomic)
            }
        } catch {
            // Silently ignore write errors in release builds
        }
    }

    private func truncateLogFileSync() {
        do {
            try ensureLogsDirectory()
            if FileManager.default.fileExists(atPath: activeLogFileURL.path) {
                try Data().write(to: activeLogFileURL, options: .atomic)
            }
        } catch {
            // Silently ignore
        }
    }

    private nonisolated func ensureLogsDirectory() throws {
        try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
    }

    private nonisolated static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
