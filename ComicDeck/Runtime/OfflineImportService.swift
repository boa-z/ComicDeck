import CryptoKit
import Foundation
import zlib

enum OfflineImportArchiveFormat: String {
    case zip
    case cbz
}

struct OfflineImportSummary: Sendable {
    let importedCount: Int
    let failures: [String]

    var hasFailures: Bool { !failures.isEmpty }
}

enum OfflineImportServiceError: LocalizedError {
    case unsupportedFileType
    case invalidArchive
    case unsupportedCompression(String)
    case encryptedArchive
    case noImageEntries
    case extractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Only ZIP and CBZ files can be imported."
        case .invalidArchive:
            return "The selected archive is not a valid ZIP/CBZ file."
        case let .unsupportedCompression(name):
            return "The archive uses an unsupported compression method in \(name)."
        case .encryptedArchive:
            return "Encrypted ZIP/CBZ archives are not supported."
        case .noImageEntries:
            return "No readable image files were found in the archive."
        case let .extractionFailed(name):
            return "Failed to extract \(name)."
        }
    }
}

struct OfflineImportService {
    static let importedSourceKey = "imported"

    private let rootDirectory: URL
    private let fileManager = FileManager.default
    private let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif"]

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    func importArchives(at urls: [URL]) async -> OfflineImportSummary {
        var importedCount = 0
        var failures: [String] = []

        for url in urls {
            do {
                try importArchive(at: url)
                importedCount += 1
            } catch {
                let name = url.lastPathComponent
                let message = error.localizedDescription.isEmpty ? "Unknown error" : error.localizedDescription
                failures.append("\(name): \(message)")
            }
        }

        return OfflineImportSummary(importedCount: importedCount, failures: failures)
    }

    private func importArchive(at fileURL: URL) throws {
        guard let format = archiveFormat(for: fileURL) else {
            throw OfflineImportServiceError.unsupportedFileType
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let archive = try ZIPArchiveReader(data: data)
        let imageEntries = archive.entries
            .filter { !$0.path.hasSuffix("/") }
            .filter { supportedImageExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        guard !imageEntries.isEmpty else {
            throw OfflineImportServiceError.noImageEntries
        }

        let baseName = sanitizeFileName(fileURL.deletingPathExtension().lastPathComponent)
        let hash = archiveIdentifier(for: data)
        let comicID = "imported-\(hash)"
        let chapterID = "\(comicID)-chapter-1"
        let sourceRoot = rootDirectory.appendingPathComponent(Self.importedSourceKey, isDirectory: true)
        let comicRoot = sourceRoot.appendingPathComponent(comicID, isDirectory: true)
        let chapterRoot = comicRoot.appendingPathComponent(chapterID, isDirectory: true)

        try fileManager.createDirectory(at: comicRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: chapterRoot.path) {
            try fileManager.removeItem(at: chapterRoot)
        }
        try fileManager.createDirectory(at: chapterRoot, withIntermediateDirectories: true)

        var firstImageURL: URL?
        for (index, entry) in imageEntries.enumerated() {
            if entry.isEncrypted {
                throw OfflineImportServiceError.encryptedArchive
            }
            let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
            let outputURL = chapterRoot.appendingPathComponent(String(format: "%04d.%@", index + 1, ext))
            let extracted = try archive.extract(entry)
            try extracted.write(to: outputURL, options: .atomic)
            if firstImageURL == nil {
                firstImageURL = outputURL
            }
        }

        if let firstImageURL {
            let coverURL = comicRoot.appendingPathComponent("cover.\(firstImageURL.pathExtension.lowercased())")
            if fileManager.fileExists(atPath: coverURL.path) {
                try fileManager.removeItem(at: coverURL)
            }
            try fileManager.copyItem(at: firstImageURL, to: coverURL)
        }

        let now = Int64(Date().timeIntervalSince1970)
        let metadata: [String: Any] = [
            "sourceKey": Self.importedSourceKey,
            "comicID": comicID,
            "comicTitle": baseName,
            "coverURL": "",
            "comicDescription": "Imported from \(format.rawValue.uppercased()) archive.",
            "chapterID": chapterID,
            "chapterTitle": baseName,
            "totalPages": imageEntries.count,
            "downloadedAt": now
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(to: chapterRoot.appendingPathComponent("metadata.json"), options: .atomic)
    }

    private func archiveFormat(for fileURL: URL) -> OfflineImportArchiveFormat? {
        switch fileURL.pathExtension.lowercased() {
        case "zip":
            return .zip
        case "cbz":
            return .cbz
        default:
            return nil
        }
    }

    private func archiveIdentifier(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Imported Comic" : cleaned
    }
}

private struct ZIPArchiveReader {
    struct Entry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let localHeaderOffset: UInt32
        let generalPurposeFlag: UInt16

        var isEncrypted: Bool {
            (generalPurposeFlag & 0x0001) != 0
        }
    }

    let data: Data
    let entries: [Entry]

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.parseCentralDirectory(in: data)
    }

    func extract(_ entry: Entry) throws -> Data {
        let localOffset = Int(entry.localHeaderOffset)
        guard try data.readUInt32(at: localOffset) == 0x04034B50 else {
            throw OfflineImportServiceError.invalidArchive
        }

        let fileNameLength = Int(try data.readUInt16(at: localOffset + 26))
        let extraFieldLength = Int(try data.readUInt16(at: localOffset + 28))
        let payloadOffset = localOffset + 30 + fileNameLength + extraFieldLength
        let compressedSize = Int(entry.compressedSize)
        guard payloadOffset >= 0, payloadOffset + compressedSize <= data.count else {
            throw OfflineImportServiceError.invalidArchive
        }

        let payload = data.subdata(in: payloadOffset..<(payloadOffset + compressedSize))
        switch entry.compressionMethod {
        case 0:
            return payload
        case 8:
            return try inflateRawDeflate(payload, expectedSize: Int(entry.uncompressedSize))
        default:
            throw OfflineImportServiceError.unsupportedCompression(entry.path)
        }
    }

    private static func parseCentralDirectory(in data: Data) throws -> [Entry] {
        let eocdOffset = try findEOCD(in: data)
        let centralDirectoryOffset = Int(try data.readUInt32(at: eocdOffset + 16))
        let totalEntries = Int(try data.readUInt16(at: eocdOffset + 10))

        var entries: [Entry] = []
        var offset = centralDirectoryOffset
        for _ in 0..<totalEntries {
            guard try data.readUInt32(at: offset) == 0x02014B50 else {
                throw OfflineImportServiceError.invalidArchive
            }

            let generalPurposeFlag = try data.readUInt16(at: offset + 8)
            let compressionMethod = try data.readUInt16(at: offset + 10)
            let compressedSize = try data.readUInt32(at: offset + 20)
            let uncompressedSize = try data.readUInt32(at: offset + 24)
            let fileNameLength = Int(try data.readUInt16(at: offset + 28))
            let extraFieldLength = Int(try data.readUInt16(at: offset + 30))
            let commentLength = Int(try data.readUInt16(at: offset + 32))
            let localHeaderOffset = try data.readUInt32(at: offset + 42)

            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            guard nameEnd <= data.count else {
                throw OfflineImportServiceError.invalidArchive
            }

            let pathData = data.subdata(in: nameStart..<nameEnd)
            guard let path = String(data: pathData, encoding: .utf8).flatMap({ $0.isEmpty ? nil : $0 }) else {
                throw OfflineImportServiceError.invalidArchive
            }

            entries.append(
                Entry(
                    path: path,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset,
                    generalPurposeFlag: generalPurposeFlag
                )
            )

            offset = nameEnd + extraFieldLength + commentLength
        }

        return entries
    }

    private static func findEOCD(in data: Data) throws -> Int {
        let signature: UInt32 = 0x06054B50
        let maxCommentLength = min(data.count, 65_557)
        let start = data.count - maxCommentLength
        guard start >= 0 else {
            throw OfflineImportServiceError.invalidArchive
        }

        if data.count < 4 {
            throw OfflineImportServiceError.invalidArchive
        }

        for index in stride(from: data.count - 4, through: start, by: -1) {
            if try data.readUInt32(at: index) == signature {
                return index
            }
        }

        throw OfflineImportServiceError.invalidArchive
    }

    private func inflateRawDeflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw OfflineImportServiceError.extractionFailed("deflate stream")
        }
        defer { inflateEnd(&stream) }

        return try compressed.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                throw OfflineImportServiceError.extractionFailed("input buffer")
            }

            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(compressed.count)

            let outputChunkSize = max(expectedSize, 64 * 1024)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: outputChunkSize)

            repeat {
                status = chunk.withUnsafeMutableBytes { outputBuffer in
                    guard let outputBase = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        return Z_BUF_ERROR
                    }
                    stream.next_out = outputBase
                    stream.avail_out = uInt(outputChunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = outputChunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: chunk.prefix(produced))
                }
            } while status == Z_OK

            guard status == Z_STREAM_END else {
                throw OfflineImportServiceError.extractionFailed("deflate payload")
            }

            return output
        }
    }
}

private extension Data {
    func readUInt16(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw OfflineImportServiceError.invalidArchive
        }
        return subdata(in: offset..<(offset + 2)).withUnsafeBytes {
            UInt16(littleEndian: $0.load(as: UInt16.self))
        }
    }

    func readUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= count else {
            throw OfflineImportServiceError.invalidArchive
        }
        return subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            UInt32(littleEndian: $0.load(as: UInt32.self))
        }
    }
}
