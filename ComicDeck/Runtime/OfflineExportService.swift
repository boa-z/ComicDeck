import Foundation
import UIKit

enum OfflineExportFormat: String, CaseIterable, Identifiable {
    case zip
    case cbz
    case pdf
    case epub

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .zip: return "zip"
        case .cbz: return "cbz"
        case .pdf: return "pdf"
        case .epub: return "epub"
        }
    }

    var title: String {
        switch self {
        case .zip: return "ZIP"
        case .cbz: return "CBZ"
        case .pdf: return "PDF"
        case .epub: return "EPUB"
        }
    }
}

enum OfflineExportServiceError: LocalizedError {
    case missingSourceDirectory
    case noReadableFiles

    var errorDescription: String? {
        switch self {
        case .missingSourceDirectory:
            return "Offline files are missing."
        case .noReadableFiles:
            return "No readable offline files were found."
        }
    }
}

struct OfflineExportService {
    private let fileManager = FileManager.default

    func exportChapter(_ item: OfflineChapterAsset, format: OfflineExportFormat) throws -> URL {
        let sourceDirectory = URL(fileURLWithPath: item.directoryPath, isDirectory: true)
        guard fileManager.fileExists(atPath: sourceDirectory.path) else {
            throw OfflineExportServiceError.missingSourceDirectory
        }

        let chapterName = sanitizeFileName(item.chapterTitle.isEmpty ? item.chapterID : item.chapterTitle)
        let files = try regularFiles(in: sourceDirectory, includeMetadata: format == .zip)
        guard !files.isEmpty else {
            throw OfflineExportServiceError.noReadableFiles
        }

        let destinationURL = makeArchiveURL(baseName: chapterName, format: format)
        try removeIfExists(destinationURL)
        switch format {
        case .zip, .cbz:
            let entries = files.map { fileURL in
                ZipArchiveEntry(sourceURL: fileURL, entryPath: fileURL.lastPathComponent)
            }
            try ZipArchiveWriter().write(entries: entries, to: destinationURL)
        case .pdf:
            try writePDF(from: imageFiles(in: sourceDirectory), to: destinationURL)
        case .epub:
            try writeEPUB(
                title: item.chapterTitle.isEmpty ? chapterName : item.chapterTitle,
                author: item.comicTitle,
                imageFiles: imageFiles(in: sourceDirectory),
                destinationURL: destinationURL
            )
        }
        return destinationURL
    }

    func exportComic(group: OfflineComicGroup, format: OfflineExportFormat) throws -> URL {
        let completeChapters = group.chapters
            .filter { $0.integrityStatus == .complete }
            .sorted { lhs, rhs in
                if lhs.downloadedAt != rhs.downloadedAt { return lhs.downloadedAt < rhs.downloadedAt }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
            }

        guard let firstChapter = completeChapters.first else {
            throw OfflineExportServiceError.noReadableFiles
        }

        let comicName = sanitizeFileName(group.comicTitle)
        let comicRoot = URL(fileURLWithPath: firstChapter.directoryPath).deletingLastPathComponent()
        let destinationURL = makeArchiveURL(baseName: comicName, format: format)
        try removeIfExists(destinationURL)

        switch format {
        case .zip:
            var entries: [ZipArchiveEntry] = []
            if let coverURL = localCoverFile(in: comicRoot) {
                entries.append(ZipArchiveEntry(sourceURL: coverURL, entryPath: coverURL.lastPathComponent))
            }

            for chapter in completeChapters {
                let sourceDirectory = URL(fileURLWithPath: chapter.directoryPath, isDirectory: true)
                guard fileManager.fileExists(atPath: sourceDirectory.path) else { continue }
                let chapterName = sanitizeFileName(chapter.chapterTitle.isEmpty ? chapter.chapterID : chapter.chapterTitle)
                let files = try regularFiles(in: sourceDirectory, includeMetadata: true)
                for fileURL in files {
                    entries.append(
                        ZipArchiveEntry(
                            sourceURL: fileURL,
                            entryPath: "\(chapterName)/\(fileURL.lastPathComponent)"
                        )
                    )
                }
            }

            guard !entries.isEmpty else {
                throw OfflineExportServiceError.noReadableFiles
            }

            try ZipArchiveWriter().write(entries: entries, to: destinationURL)
        case .cbz:
            throw OfflineExportServiceError.noReadableFiles
        case .pdf:
            let images = completeChapters.flatMap { imageFiles(in: URL(fileURLWithPath: $0.directoryPath, isDirectory: true)) }
            try writePDF(from: images, to: destinationURL)
        case .epub:
            try writeComicEPUB(group: group, chapters: completeChapters, destinationURL: destinationURL)
        }
        return destinationURL
    }

    func exportOfflineSelectionZIP(items: [OfflineChapterAsset], title: String) throws -> URL {
        guard !items.isEmpty else {
            throw OfflineExportServiceError.noReadableFiles
        }

        let sortedItems = items.sorted { lhs, rhs in
            if lhs.comicTitle != rhs.comicTitle {
                return lhs.comicTitle.localizedStandardCompare(rhs.comicTitle) == .orderedAscending
            }
            return lhs.chapterTitle.localizedStandardCompare(rhs.chapterTitle) == .orderedAscending
        }

        var entries: [ZipArchiveEntry] = []
        for item in sortedItems {
            let sourceDirectory = URL(fileURLWithPath: item.directoryPath, isDirectory: true)
            guard fileManager.fileExists(atPath: sourceDirectory.path) else { continue }

            let comicName = sanitizeFileName(item.comicTitle)
            let chapterName = sanitizeFileName(item.chapterTitle.isEmpty ? item.chapterID : item.chapterTitle)
            let files = try regularFiles(in: sourceDirectory, includeMetadata: true)
            for fileURL in files {
                entries.append(
                    ZipArchiveEntry(
                        sourceURL: fileURL,
                        entryPath: "\(comicName)/\(chapterName)/\(fileURL.lastPathComponent)"
                    )
                )
            }
        }

        guard !entries.isEmpty else {
            throw OfflineExportServiceError.noReadableFiles
        }

        let destinationURL = makeArchiveURL(baseName: sanitizeFileName(title), format: .zip)
        try removeIfExists(destinationURL)
        try ZipArchiveWriter().write(entries: entries, to: destinationURL)
        return destinationURL
    }

    private func regularFiles(in directory: URL, includeMetadata: Bool) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { fileURL in
            guard includeMetadata || fileURL.lastPathComponent != "metadata.json" else { return false }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func imageFiles(in directory: URL) -> [URL] {
        let supported = Set(["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif"])
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files.filter { fileURL in
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { return false }
            return supported.contains(fileURL.pathExtension.lowercased())
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func localCoverFile(in comicRoot: URL) -> URL? {
        let supported = ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif"]
        return supported
            .map { comicRoot.appendingPathComponent("cover.\($0)") }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    private func makeArchiveURL(baseName: String, format: OfflineExportFormat) -> URL {
        fileManager.temporaryDirectory
            .appendingPathComponent("\(baseName)-\(timestamp()).\(format.fileExtension)")
    }

    private func writePDF(from imageFiles: [URL], to destinationURL: URL) throws {
        let images = imageFiles.compactMap { UIImage(contentsOfFile: $0.path) }
        guard !images.isEmpty else {
            throw OfflineExportServiceError.noReadableFiles
        }

        let firstSize = images[0].size
        let defaultBounds = CGRect(origin: .zero, size: CGSize(width: max(firstSize.width, 1), height: max(firstSize.height, 1)))
        let renderer = UIGraphicsPDFRenderer(bounds: defaultBounds)
        try renderer.writePDF(to: destinationURL) { context in
            for image in images {
                let size = CGSize(width: max(image.size.width, 1), height: max(image.size.height, 1))
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }

    private func writeEPUB(title: String, author: String, imageFiles: [URL], destinationURL: URL) throws {
        let validImages = imageFiles.filter { fileManager.fileExists(atPath: $0.path) }
        guard !validImages.isEmpty else {
            throw OfflineExportServiceError.noReadableFiles
        }

        var entries: [ZipArchiveEntry] = [
            .data("application/epub+zip".data(using: .utf8)!, entryPath: "mimetype"),
            .data(Self.containerXML.data(using: .utf8)!, entryPath: "META-INF/container.xml")
        ]

        var manifestItems: [String] = []
        var spineItems: [String] = []
        var navPoints: [String] = []
        let identifier = UUID().uuidString

        for (index, imageURL) in validImages.enumerated() {
            let pageNumber = index + 1
            let imageName = "images/page-\(String(format: "%03d", pageNumber)).jpg"
            let pageName = "pages/page-\(String(format: "%03d", index + 1)).xhtml"
            let imageID = "img\(pageNumber)"
            let pageID = "page\(pageNumber)"

            entries.append(.data(try jpegData(for: imageURL), entryPath: "OEBPS/\(imageName)"))
            let pageMarkup = Self.xhtmlPage(title: title, imagePath: "../\(imageName)")
            entries.append(.data(Data(pageMarkup.utf8), entryPath: "OEBPS/\(pageName)"))

            manifestItems.append(#"<item id="\#(imageID)" href="\#(imageName)" media-type="image/jpeg"/>"#)
            manifestItems.append(#"<item id="\#(pageID)" href="\#(pageName)" media-type="application/xhtml+xml"/>"#)
            spineItems.append(#"<itemref idref="\#(pageID)"/>"#)
            navPoints.append(
                Self.ncxNavPoint(
                    id: pageID,
                    playOrder: pageNumber,
                    label: "Page \(pageNumber)",
                    src: pageName
                )
            )
        }

        let tocNCX = Self.tocNCX(
            identifier: identifier,
            title: title,
            navPoints: navPoints.joined(separator: "\n")
        )
        entries.append(.data(Data(tocNCX.utf8), entryPath: "OEBPS/toc.ncx"))

        let contentOPF = Self.contentOPF(
            identifier: identifier,
            title: title,
            author: author,
            tocID: "ncx",
            manifestItems: manifestItems.joined(separator: "\n"),
            spineItems: spineItems.joined(separator: "\n")
        )
        entries.append(.data(Data(contentOPF.utf8), entryPath: "OEBPS/content.opf"))

        try ZipArchiveWriter().write(entries: entries, to: destinationURL)
    }

    private func writeComicEPUB(group: OfflineComicGroup, chapters: [OfflineChapterAsset], destinationURL: URL) throws {
        var entries: [ZipArchiveEntry] = [
            .data("application/epub+zip".data(using: .utf8)!, entryPath: "mimetype"),
            .data(Self.containerXML.data(using: .utf8)!, entryPath: "META-INF/container.xml")
        ]

        var manifestItems: [String] = []
        var spineItems: [String] = []
        var navPoints: [String] = []
        var pageIndex = 1
        let identifier = UUID().uuidString

        for (chapterOffset, chapter) in chapters.enumerated() {
            let chapterDir = URL(fileURLWithPath: chapter.directoryPath, isDirectory: true)
            let images = imageFiles(in: chapterDir)
            for imageURL in images {
                let imageName = "images/ch\(chapterOffset + 1)-p\(String(format: "%03d", pageIndex)).jpg"
                let pageName = "pages/ch\(chapterOffset + 1)-p\(String(format: "%03d", pageIndex)).xhtml"
                let imageID = "img\(pageIndex)"
                let pageID = "page\(pageIndex)"
                let label = chapter.chapterTitle.isEmpty ? "Chapter \(chapterOffset + 1)" : chapter.chapterTitle

                entries.append(.data(try jpegData(for: imageURL), entryPath: "OEBPS/\(imageName)"))
                let pageMarkup = Self.xhtmlPage(title: label, imagePath: "../\(imageName)")
                entries.append(.data(Data(pageMarkup.utf8), entryPath: "OEBPS/\(pageName)"))

                manifestItems.append(#"<item id="\#(imageID)" href="\#(imageName)" media-type="image/jpeg"/>"#)
                manifestItems.append(#"<item id="\#(pageID)" href="\#(pageName)" media-type="application/xhtml+xml"/>"#)
                spineItems.append(#"<itemref idref="\#(pageID)"/>"#)
                navPoints.append(
                    Self.ncxNavPoint(
                        id: pageID,
                        playOrder: pageIndex,
                        label: "\(label) · Page \(pageIndex)",
                        src: pageName
                    )
                )
                pageIndex += 1
            }
        }

        guard pageIndex > 1 else {
            throw OfflineExportServiceError.noReadableFiles
        }

        let tocNCX = Self.tocNCX(
            identifier: identifier,
            title: group.comicTitle,
            navPoints: navPoints.joined(separator: "\n")
        )
        entries.append(.data(Data(tocNCX.utf8), entryPath: "OEBPS/toc.ncx"))
        let contentOPF = Self.contentOPF(
            identifier: identifier,
            title: group.comicTitle,
            author: group.comicTitle,
            tocID: "ncx",
            manifestItems: manifestItems.joined(separator: "\n"),
            spineItems: spineItems.joined(separator: "\n")
        )
        entries.append(.data(Data(contentOPF.utf8), entryPath: "OEBPS/content.opf"))

        try ZipArchiveWriter().write(entries: entries, to: destinationURL)
    }

    private func jpegData(for imageURL: URL) throws -> Data {
        guard let image = UIImage(contentsOfFile: imageURL.path),
              let data = image.jpegData(compressionQuality: 0.92) else {
            throw OfflineExportServiceError.noReadableFiles
        }
        return data
    }

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static func xhtmlPage(title: String, imagePath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
          <head>
            <title>\(escapeXML(title))</title>
            <style type="text/css">
              html, body { margin: 0; padding: 0; background: #000; }
              div { margin: 0; padding: 0; }
              img { display: block; width: 100%; height: auto; }
            </style>
          </head>
          <body>
            <div>
              <img src="\(imagePath)" alt="\(escapeXML(title))" />
            </div>
          </body>
        </html>
        """
    }

    private static func tocNCX(identifier: String, title: String, navPoints: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN"
          "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(escapeXML(identifier))"/>
            <meta name="dtb:depth" content="1"/>
            <meta name="dtb:totalPageCount" content="0"/>
            <meta name="dtb:maxPageNumber" content="0"/>
          </head>
          <docTitle>
            <text>\(escapeXML(title))</text>
          </docTitle>
          <navMap>
            \(navPoints)
          </navMap>
        </ncx>
        """
    }

    private static func ncxNavPoint(id: String, playOrder: Int, label: String, src: String) -> String {
        """
        <navPoint id="\(escapeXML(id))" playOrder="\(playOrder)">
          <navLabel><text>\(escapeXML(label))</text></navLabel>
          <content src="\(escapeXML(src))"/>
        </navPoint>
        """
    }

    private static func contentOPF(
        identifier: String,
        title: String,
        author: String,
        tocID: String,
        manifestItems: String,
        spineItems: String
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">\(escapeXML(identifier))</dc:identifier>
            <dc:title>\(escapeXML(title))</dc:title>
            <dc:creator>\(escapeXML(author))</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="\(escapeXML(tocID))" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            \(manifestItems)
          </manifest>
          <spine toc="\(escapeXML(tocID))">
            \(spineItems)
          </spine>
        </package>
        """
    }

    private static func escapeXML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func removeIfExists(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func sanitizeFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Export" : cleaned
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private struct ZipArchiveEntry {
    let sourceURL: URL?
    let data: Data?
    let entryPath: String

    static func file(_ url: URL, entryPath: String) -> Self {
        Self(sourceURL: url, data: nil, entryPath: entryPath)
    }

    static func data(_ data: Data, entryPath: String) -> Self {
        Self(sourceURL: nil, data: data, entryPath: entryPath)
    }

    init(sourceURL: URL?, data: Data?, entryPath: String) {
        self.sourceURL = sourceURL
        self.data = data
        self.entryPath = entryPath
    }

    init(sourceURL: URL, entryPath: String) {
        self.sourceURL = sourceURL
        self.data = nil
        self.entryPath = entryPath
    }
}

private final class ZipArchiveWriter {
    private struct CentralDirectoryRecord {
        let entryPathData: Data
        let crc32: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let offset: UInt32
        let modTime: UInt16
        let modDate: UInt16
    }

    func write(entries: [ZipArchiveEntry], to destinationURL: URL) throws {
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        var centralRecords: [CentralDirectoryRecord] = []
        var offset: UInt32 = 0

        for entry in entries {
            let data: Data
            if let inlineData = entry.data {
                data = inlineData
            } else if let sourceURL = entry.sourceURL {
                data = try Data(contentsOf: sourceURL)
            } else {
                continue
            }
            let pathData = Data(entry.entryPath.utf8)
            let crc = data.crc32()
            let sizes = try sizes(for: data.count)
            let timestamp = try entry.sourceURL?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
            let dos = dosDateTime(for: timestamp)

            let localHeader = makeLocalFileHeader(
                crc32: crc,
                compressedSize: sizes,
                uncompressedSize: sizes,
                pathLength: UInt16(pathData.count),
                modTime: dos.time,
                modDate: dos.date
            )
            try handle.write(contentsOf: localHeader)
            try handle.write(contentsOf: pathData)
            try handle.write(contentsOf: data)

            centralRecords.append(
                CentralDirectoryRecord(
                    entryPathData: pathData,
                    crc32: crc,
                    compressedSize: sizes,
                    uncompressedSize: sizes,
                    offset: offset,
                    modTime: dos.time,
                    modDate: dos.date
                )
            )

            offset &+= UInt32(localHeader.count + pathData.count + data.count)
        }

        let centralStart = offset
        for record in centralRecords {
            let header = makeCentralDirectoryHeader(record: record)
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: record.entryPathData)
            offset &+= UInt32(header.count + record.entryPathData.count)
        }

        let endRecord = makeEndOfCentralDirectory(
            entryCount: UInt16(centralRecords.count),
            centralDirectorySize: offset - centralStart,
            centralDirectoryOffset: centralStart
        )
        try handle.write(contentsOf: endRecord)
    }

    private func makeLocalFileHeader(
        crc32: UInt32,
        compressedSize: UInt32,
        uncompressedSize: UInt32,
        pathLength: UInt16,
        modTime: UInt16,
        modDate: UInt16
    ) -> Data {
        var data = Data()
        data.append(littleEndian: UInt32(0x04034B50))
        data.append(littleEndian: UInt16(20))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: modTime)
        data.append(littleEndian: modDate)
        data.append(littleEndian: crc32)
        data.append(littleEndian: compressedSize)
        data.append(littleEndian: uncompressedSize)
        data.append(littleEndian: pathLength)
        data.append(littleEndian: UInt16(0))
        return data
    }

    private func makeCentralDirectoryHeader(record: CentralDirectoryRecord) -> Data {
        var data = Data()
        data.append(littleEndian: UInt32(0x02014B50))
        data.append(littleEndian: UInt16(20))
        data.append(littleEndian: UInt16(20))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: record.modTime)
        data.append(littleEndian: record.modDate)
        data.append(littleEndian: record.crc32)
        data.append(littleEndian: record.compressedSize)
        data.append(littleEndian: record.uncompressedSize)
        data.append(littleEndian: UInt16(record.entryPathData.count))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt32(0))
        data.append(littleEndian: record.offset)
        return data
    }

    private func makeEndOfCentralDirectory(
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) -> Data {
        var data = Data()
        data.append(littleEndian: UInt32(0x06054B50))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: UInt16(0))
        data.append(littleEndian: entryCount)
        data.append(littleEndian: entryCount)
        data.append(littleEndian: centralDirectorySize)
        data.append(littleEndian: centralDirectoryOffset)
        data.append(littleEndian: UInt16(0))
        return data
    }

    private func sizes(for count: Int) throws -> UInt32 {
        guard count <= Int(UInt32.max) else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        return UInt32(count)
    }

    private func dosDateTime(for date: Date) -> (date: UInt16, time: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone.current, from: date)
        let year = max((components.year ?? 1980) - 1980, 0)
        let month = max(components.month ?? 1, 1)
        let day = max(components.day ?? 1, 1)
        let hour = max(components.hour ?? 0, 0)
        let minute = max(components.minute ?? 0, 0)
        let second = max((components.second ?? 0) / 2, 0)

        let dosDate = UInt16((year << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        return (dosDate, dosTime)
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }

    func crc32() -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in self {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ Self.crc32Table[index]
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { value in
            var crc = UInt32(value)
            for _ in 0..<8 {
                if (crc & 1) == 1 {
                    crc = 0xEDB8_8320 ^ (crc >> 1)
                } else {
                    crc >>= 1
                }
            }
            return crc
        }
    }()
}
