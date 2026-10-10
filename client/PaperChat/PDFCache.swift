import Foundation

actor PDFCache {
    static let shared = PDFCache()

    private let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "PaperChat/papers", directoryHint: .isDirectory)
    }()

    func cachedURL(paperID: String, root directory: URL? = nil) -> URL? {
        let url = documentURL(paperID: paperID, root: directory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func store(_ data: Data, paperID: String, etag: String?, root directory: URL? = nil) throws -> URL {
        let url = documentURL(paperID: paperID, root: directory)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        if let etag {
            try Data(etag.utf8).write(
                to: directory.appending(path: "etag.txt"), options: .atomic
            )
        }
        return url
    }

    func storeLocalFile(at sourceURL: URL, paperID: String, root directory: URL? = nil) throws -> URL {
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        return try store(data, paperID: paperID, etag: nil, root: directory)
    }

    private func documentURL(paperID: String, root directory: URL?) -> URL {
        (directory ?? root).appending(path: paperID, directoryHint: .isDirectory)
            .appending(path: "document.pdf")
    }
}
