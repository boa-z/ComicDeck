import Foundation
import Observation

@Observable
final class RuntimeDebugConsole {
    static let shared = RuntimeDebugConsole()
    static let enabledKey = "runtime.debug.enabled"

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
    private var logsDirectoryURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("DebugLogs", isDirectory: true)
    }
    @ObservationIgnored
    private var activeLogFileURL: URL {
        logsDirectoryURL.appendingPathComponent("runtime-debug.log", isDirectory: false)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    @inline(__always)
    nonisolated static func appendRuntimeLine(_ line: String) {
        guard isEnabled else { return }
        NSLog("%@", line)
        shared.append(line)
    }

    func append(_ message: String) {
        guard Self.isEnabled else { return }
        writeQueue.async { [weak self] in
            self?.appendSerialized(message)
        }
    }

    func clear() {
        writeQueue.async { [weak self] in
            self?.clearSerialized()
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

    private func appendSerialized(_ message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        bufferedLines.append(line)
        if bufferedLines.count > maxLines {
            bufferedLines.removeFirst(bufferedLines.count - maxLines)
        }
        appendToFile(line)
        let snapshot = bufferedLines
        Task { @MainActor [weak self] in
            self?.lines = snapshot
        }
    }

    private func clearSerialized() {
        bufferedLines.removeAll(keepingCapacity: true)
        truncateLogFile()
        Task { @MainActor [weak self] in
            self?.lines.removeAll(keepingCapacity: true)
            self?.lastWriteError = nil
        }
    }

    private func appendToFile(_ line: String) {
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
            Task { @MainActor [weak self] in
                self?.lastWriteError = nil
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.lastWriteError = error.localizedDescription
            }
        }
    }

    private func truncateLogFile() {
        do {
            try ensureLogsDirectory()
            if FileManager.default.fileExists(atPath: activeLogFileURL.path) {
                try Data().write(to: activeLogFileURL, options: .atomic)
            }
            Task { @MainActor [weak self] in
                self?.lastWriteError = nil
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.lastWriteError = error.localizedDescription
            }
        }
    }

    private func ensureLogsDirectory() throws {
        try FileManager.default.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
