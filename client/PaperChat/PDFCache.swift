import Foundation

actor PDFCache {
    static let shared = PDFCache()

    private let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "PaperChat/papers", directoryHint: .isDirectory)
    }()

    func cachedURL(paperID: String) -> URL? {
        let url = documentURL(paperID: paperID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func store(_ data: Data, paperID: String, etag: String?) throws -> URL {
        let directory = documentURL(paperID: paperID).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = documentURL(paperID: paperID)
        try data.write(to: url, options: .atomic)
        if let etag {
            try Data(etag.utf8).write(
                to: directory.appending(path: "etag.txt"), options: .atomic
            )
        }
        return url
    }

    func storeLocalFile(at sourceURL: URL, paperID: String) throws -> URL {
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        return try store(data, paperID: paperID, etag: nil)
    }

    private func documentURL(paperID: String) -> URL {
        root.appending(path: paperID, directoryHint: .isDirectory)
            .appending(path: "document.pdf")
    }
}
