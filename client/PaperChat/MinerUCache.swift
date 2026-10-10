import CryptoKit
import Foundation
import PDFKit
import zlib
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

actor MinerUCache {
    static let shared = MinerUCache()

    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "PaperChat/papers", directoryHint: .isDirectory)

    func cachedETag(paperID: String, root directory: URL? = nil) -> String? {
        let directory = (directory ?? root).appending(path: paperID, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.appending(path: "mineru.zip").path) else {
            return nil
        }
        return try? String(contentsOf: directory.appending(path: "mineru-etag.txt"), encoding: .utf8)
    }

    func store(_ data: Data, paperID: String, etag: String?, root directory: URL? = nil) throws {
        let directory = (directory ?? root).appending(path: paperID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "mineru.zip"), options: .atomic)
        let thumbnails = directory.appending(path: "mineru-thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: thumbnails)
        if let etag {
            try etag.write(to: directory.appending(path: "mineru-etag.txt"), atomically: true, encoding: .utf8)
        }
    }

    func load(paperID: String, attachmentKey: String, pdfURL: URL, root directory: URL? = nil) throws -> MinerUDocument? {
        let directory = (directory ?? root).appending(path: paperID, directoryHint: .isDirectory)
        let archive = directory.appending(path: "mineru.zip")
        guard FileManager.default.fileExists(atPath: archive.path) else { return nil }
        let zip = try MinerUZip(data: Data(contentsOf: archive, options: .mappedIfSafe))
        let manifest = try JSONDecoder().decode(Manifest.self, from: try zip.member("manifest.json"))
        guard ["zotero-mineru-worker/1", "zotero-mineru-worker/2"].contains(manifest.schema),
              manifest.source.pdfAttachmentKey == attachmentKey else { return nil }
        let digest = SHA256.hash(data: try Data(contentsOf: pdfURL, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.source.sha256 else { return nil }
        let content = try JSONDecoder().decode(
            StructuredContent.self, from: try zip.member("structured_content.json")
        )
        let allHeadings = content.pages.flatMap { page in
            page.blocks.filter(\.isHeading)
                .map { (page.pageIdx, $0) }
        }
        let occurrences = Dictionary(grouping: allHeadings, by: { $0.1.content })
        var outline: [DocumentOutlineNode] = []
        var figures: [MinerUFigure] = []
        var headingStack: [(level: Int, id: String)] = []
        let pdf = PDFDocument(url: pdfURL)
        let thumbnails = directory.appending(path: "mineru-thumbnails", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)

        for page in content.pages {
            for block in page.blocks {
                if block.isHeading {
                    let title = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty else { continue }
                    if block.type == "doc_title" && page.pageIdx == 0 { continue }
                    if block.type == "paragraph_title", let box = block.bbox,
                       box.count == 4, box[1] < 0.13,
                       (occurrences[title]?.count ?? 0) > 1 { continue }
                    if title.range(
                        of: #"(?i)^(?:\d+(?:\.\d+)*\s+)?(?:proposition|theorem|lemma|corollary|definition|remarks?)\b"#,
                        options: .regularExpression
                    ) != nil { continue }
                    let level = block.textLevel.flatMap { $0 > 0 ? $0 : nil }
                        ?? headingLevel(title, type: block.type)
                    let id = "mineru-heading-\(page.pageIdx)-\(outline.count)"
                    while let last = headingStack.last, last.level >= level {
                        headingStack.removeLast()
                    }
                    let parentID = headingStack.last?.id
                    outline.append(DocumentOutlineNode(
                        id: id, parentID: parentID,
                        title: title, level: level,
                        anchor: anchor(page: page.pageIdx, bbox: block.bbox)
                    ))
                    headingStack.append((level: level, id: id))
                } else if ["image", "chart", "table"].contains(block.type),
                          let position = anchor(page: page.pageIdx, bbox: block.bbox) {
                    let id = "mineru-figure-\(page.pageIdx)-\(figures.count)"
                    let caption = (block.captions ?? []).map(\.content)
                        .filter { !$0.isEmpty }.joined(separator: " ")
                    let title = caption.isEmpty
                        ? "\(block.type == "table" ? "Table" : "Figure") on page \(page.pageIdx + 1)"
                        : caption
                    let hasArchiveImage = block.imageSource.map {
                        $0.hasPrefix("images/") && !$0.split(separator: "/").contains("..")
                            && manifest.files.contains($0)
                    } ?? false
                    let imageExtension = hasArchiveImage
                        ? block.imageSource.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? "png"
                        : "png"
                    let target = thumbnails.appending(path: "\(id).\(imageExtension)")
                    let thumbnailURL: URL?
                    if FileManager.default.fileExists(atPath: target.path) {
                        thumbnailURL = target
                    } else {
                        var imageData: Data?
                        if hasArchiveImage, let source = block.imageSource {
                            imageData = try? zip.member(source)
                        }
                        if let candidate = imageData, !isValidImage(candidate) {
                            imageData = nil
                        }
                        if imageData == nil, let box = block.bbox, let pdf {
                            imageData = crop(page: page.pageIdx, bbox: box, document: pdf)
                        }
                        if let imageData { try? imageData.write(to: target, options: .atomic) }
                        thumbnailURL = imageData == nil ? nil : target
                    }
                    figures.append(MinerUFigure(
                        id: id, title: title, kind: block.type,
                        anchor: position,
                        thumbnailURL: thumbnailURL
                    ))
                }
            }
        }
        return MinerUDocument(outline: outline, figures: figures)
    }

    private func headingLevel(_ title: String, type: String) -> Int {
        if type == "doc_title" { return 1 }
        let pattern = #"^\s*(\d+(?:\.\d+)*)(?:\.|\s)"#
        if let match = title.range(of: pattern, options: .regularExpression) {
            let token = title[match].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return min(3, token.split(separator: ".").count)
        }
        return 2
    }

    private func anchor(page: Int, bbox: [Double]?) -> DocumentAnchor? {
        guard let bbox, bbox.count == 4, bbox.allSatisfy({ $0.isFinite }),
              bbox[2] > bbox[0], bbox[3] > bbox[1] else { return nil }
        return DocumentAnchor(pageIndex: page, rects: [BookmarkSelectionRect(
            pageIndex: page, x: bbox[0], y: 1 - bbox[3],
            width: bbox[2] - bbox[0], height: bbox[3] - bbox[1]
        )])
    }

    private func crop(page: Int, bbox: [Double], document: PDFDocument) -> Data? {
        guard bbox.count == 4, let pdfPage = document.page(at: page) else { return nil }
        let image = pdfPage.thumbnail(of: CGSize(width: 1200, height: 1600), for: .cropBox)
        #if os(iOS)
        guard let cgImage = image.cgImage else { return nil }
        #else
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        let rect = CGRect(
            x: bbox[0] * Double(cgImage.width), y: bbox[1] * Double(cgImage.height),
            width: (bbox[2] - bbox[0]) * Double(cgImage.width),
            height: (bbox[3] - bbox[1]) * Double(cgImage.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard !rect.isNull, rect.width > 0, rect.height > 0,
              let cropped = cgImage.cropping(to: rect) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cropped).pngData()
        #else
        return NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])
        #endif
    }

    private func isValidImage(_ data: Data) -> Bool {
        #if os(iOS)
        return UIImage(data: data) != nil
        #else
        return NSImage(data: data) != nil
        #endif
    }
}

private struct MinerUZip {
    private struct Entry {
        let method: Int
        let compressedSize: Int
        let uncompressedSize: Int
        let localOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]

    init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw Self.invalid() }
        let start = max(0, data.count - 65_557)
        guard let end = (start...(data.count - 22)).reversed().first(where: {
            Self.number(data, at: $0, bytes: 4) == 0x06054b50
        }),
              let count = Self.number(data, at: end + 10, bytes: 2),
              let directoryOffset = Self.number(data, at: end + 16, bytes: 4) else {
            throw Self.invalid()
        }
        var offset = directoryOffset
        var found: [String: Entry] = [:]
        for _ in 0..<count {
            guard Self.number(data, at: offset, bytes: 4) == 0x02014b50,
                  let method = Self.number(data, at: offset + 10, bytes: 2),
                  let compressed = Self.number(data, at: offset + 20, bytes: 4),
                  let uncompressed = Self.number(data, at: offset + 24, bytes: 4),
                  let nameLength = Self.number(data, at: offset + 28, bytes: 2),
                  let extraLength = Self.number(data, at: offset + 30, bytes: 2),
                  let commentLength = Self.number(data, at: offset + 32, bytes: 2),
                  let localOffset = Self.number(data, at: offset + 42, bytes: 4),
                  nameLength <= data.count - min(data.count, offset + 46),
                  let name = String(data: data.subdata(in: (offset + 46)..<(offset + 46 + nameLength)), encoding: .utf8) else {
                throw Self.invalid()
            }
            found[name] = Entry(method: method, compressedSize: compressed,
                                uncompressedSize: uncompressed, localOffset: localOffset)
            offset += 46 + nameLength + extraLength + commentLength
        }
        entries = found
    }

    func member(_ name: String) throws -> Data {
        guard let entry = entries[name], entry.uncompressedSize <= 64 * 1024 * 1024,
              Self.number(data, at: entry.localOffset, bytes: 4) == 0x04034b50,
              let nameLength = Self.number(data, at: entry.localOffset + 26, bytes: 2),
              let extraLength = Self.number(data, at: entry.localOffset + 28, bytes: 2) else {
            throw Self.invalid()
        }
        let start = entry.localOffset + 30 + nameLength + extraLength
        guard start <= data.count, entry.compressedSize <= data.count - start else { throw Self.invalid() }
        let compressed = data.subdata(in: start..<(start + entry.compressedSize))
        if entry.method == 0 {
            guard compressed.count == entry.uncompressedSize else { throw Self.invalid() }
            return compressed
        }
        guard entry.method == 8 else { throw Self.invalid() }
        var output = Data(count: entry.uncompressedSize)
        var stream = z_stream()
        let status = compressed.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(compressed.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(entry.uncompressedSize)
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                                    Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Int32(Z_STREAM_ERROR) }
                let result = inflate(&stream, Z_FINISH)
                inflateEnd(&stream)
                return result
            }
        }
        guard status == Z_STREAM_END, stream.total_out == entry.uncompressedSize else { throw Self.invalid() }
        return output
    }

    private static func number(_ data: Data, at offset: Int, bytes: Int) -> Int? {
        guard offset >= 0, offset <= data.count, bytes <= data.count - offset else { return nil }
        return (0..<bytes).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
    }

    private static func invalid() -> NSError { NSError(domain: "MinerUArchive", code: 1) }
}

private struct Manifest: Decodable {
    let schema: String
    let source: Source
    let files: [String]

    struct Source: Decodable {
        let pdfAttachmentKey: String
        let sha256: String
        enum CodingKeys: String, CodingKey {
            case sha256
            case pdfAttachmentKey = "pdf_attachment_key"
        }
    }
}

private struct StructuredContent: Decodable {
    let pages: [Page]

    struct Page: Decodable {
        let pageIdx: Int
        let blocks: [Block]
        enum CodingKeys: String, CodingKey {
            case blocks
            case pageIdx = "page_idx"
        }
    }

    struct Block: Decodable {
        let type: String
        let content: String
        let textLevel: Int?
        let bbox: [Double]?
        let imageSource: String?
        let captions: [Caption]?
        enum CodingKeys: String, CodingKey {
            case type, content, bbox, captions
            case textLevel = "text_level"
            case imageSource = "image_source"
        }

        var isHeading: Bool {
            ["doc_title", "paragraph_title"].contains(type)
                || (["text", "title"].contains(type) && (textLevel ?? 0) > 0)
        }
    }

    struct Caption: Decodable {
        let content: String
    }
}
